import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:nostr_tools/nostr_tools.dart' hide Message;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bitchat_messenger/core/bounded_set.dart';
import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/core/key_manager.dart';
import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/image_sharing_service.dart';
import 'package:bitchat_messenger/core/nostr_service.dart';
import 'package:bitchat_messenger/features/mesh/services/bitchat_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/core/signaling_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/features/contacts/services/contacts_backup_service.dart';
import 'package:bitchat_messenger/core/image_download_service.dart';
import 'package:bitchat_messenger/core/voice_note_service.dart';

class MessageService {
  final NostrService _nostrService;
  final BitChatService _bitchatService;
  final DatabaseService _dbService;
  final KeyManager _keyManager;
  final Connectivity _connectivity = Connectivity();
  final _nip04 = Nip04(); // kept for backward-compatible decryption
  final _nip44 = Nip44(); // new default encryption

  final _messageController = StreamController<Message>.broadcast();
  final _reactionsController = StreamController<String>.broadcast(); // emits messageId
  final voiceNoteService = VoiceNoteService();
  final imageSharingService = ImageSharingService();
  // messageId → emoji → set of senderPubkeys
  final Map<String, Map<String, Set<String>>> _reactions = {};
  String _mode = AppConstants.modeAuto;
  int _ttl = AppConstants.defaultTTL;
  bool _hasInternet = false;
  String? _profilePictureUrl;
  // In-memory dedup set — guards against the race condition where Nostr and
  // BLE deliver the same message simultaneously before either DB write commits.
  final _processingIds = BoundedSet<String>(2000);
  SignalingService? _signalingService;
  StreamSubscription? _nostrSub;
  StreamSubscription? _bitchatSub;
  StreamSubscription? _nearbySub;
  StreamSubscription? _connectivitySub;
  StreamSubscription? _meshRelayNostrSub;
  StreamSubscription? _deliveryReceiptSub;
  Timer? _retryTimer;

  MessageService({
    required NostrService nostrService,
    required BitChatService bitchatService,
    required DatabaseService dbService,
    required KeyManager keyManager,
  })  : _nostrService = nostrService,
        _bitchatService = bitchatService,
        _dbService = dbService,
        _keyManager = keyManager;

  /// Called when the username changes — wired to ChannelService.setUsername in main.dart.
  void Function(String? username)? onUsernameChanged;

  /// Called when a group invite DM is received.
  void Function(String channelId, String channelName, String adminPubkey)? onGroupInvite;

  /// Called when a group removal DM is received.
  void Function(String channelId)? onGroupRemoval;

  /// Call signal callbacks — wired to CallService in main.dart
  void Function(String callId, String callerPubkey, String? callerName, String sdp, String sdpType, bool isVideo)? onCallOffer;
  void Function(String callId, String sdp, String sdpType)? onCallAnswer;
  void Function(String callId, String candidate, String sdpMid, int sdpMLineIndex)? onCallIce;
  void Function(String callId)? onCallEnded;
  void Function(String callId)? onCallDeclined;
  void Function(String callId)? onCallBusy;

  Stream<Message> get messageStream => _messageController.stream;
  /// Emits the senderPubkey whenever a typing indicator arrives for us.
  Stream<Map<String, dynamic>> get typingStream => _bitchatService.typingStream;
  /// Emits the messageId whenever a reaction is added or updated.
  Stream<String> get reactionsStream => _reactionsController.stream;
  String get mode => _mode;
  String? get publicKey => _keyManager.publicKey;
  String? get privateKey => _keyManager.privateKey;
  String? get username => _keyManager.username;
  NostrService get nostrService => _nostrService;
  DatabaseService get dbService => _dbService;
  Set<String> get nearbyUsers => _bitchatService.nearbyPubkeys;
  Stream<Set<String>> get nearbyChangedStream => _bitchatService.nearbyChangedStream;
  bool get hasInternet => _hasInternet;
  bool get hasNearbyDevices => _bitchatService.nearbyPubkeys.isNotEmpty;
  // True only when a Wi-Fi P2P session is active — the only transport that
  // can carry audio payloads (BLE MTU is too small for audio).
  // True when media can be sent — Wi-Fi P2P (fast) or BLE chunked (slower fallback)
  bool get canSendVoiceNote => _bitchatService.canSendMedia;
  bool get canSendImage => _bitchatService.canSendMedia;
  // True when Wi-Fi P2P is active — used by UI to show speed hint
  bool get hasWifiMesh => _bitchatService.hasWifiMesh;
  Map<String, String> get nearbyDeviceNames => _bitchatService.nearbyDeviceNames;
  Map<String, String> get nearbyDeviceProfilePictures => _bitchatService.nearbyDeviceProfilePictures;
  String? get profilePictureUrl => _profilePictureUrl;

  /// Returns the current in-memory reactions for [messageId].
  /// Map is emoji → set of senderPubkeys.
  Map<String, Set<String>> reactionsFor(String messageId) =>
      Map.unmodifiable(_reactions[messageId] ?? {});

  /// Send a typing indicator to the current chat contact (throttled by caller).
  Future<void> sendTypingIndicator(String receiverPubkey) async {
    await _bitchatService.sendTypingIndicator(receiverPubkey);
  }

  /// React to a message with an emoji. Sends to [contactPubkey] and records locally.
  Future<void> sendReaction(String messageId, String contactPubkey, String emoji) async {
    if (_keyManager.publicKey == null) return;
    // Register locally immediately so UI is instant
    _addReaction(messageId, emoji, _keyManager.publicKey!);

    final msg = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: contactPubkey,
      content: jsonEncode({'messageId': messageId, 'emoji': emoji}),
      type: AppConstants.typeReaction,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: 3,
      senderName: _keyManager.username,
    );

    if (_shouldUseOnline()) await _trySendServer(msg);
    if (_shouldUseOffline()) await _trySendBitChat(msg);
  }

  void _addReaction(String messageId, String emoji, String senderPubkey) {
    _reactions
        .putIfAbsent(messageId, () => {})
        .putIfAbsent(emoji, () => {})
        .add(senderPubkey);
    _reactionsController.add(messageId);
  }

  Future<void> setProfilePictureUrl(String? url) async {
    _profilePictureUrl = url;
    final prefs = await SharedPreferences.getInstance();
    if (url != null && url.isNotEmpty) {
      await prefs.setString('my_profile_picture_url', url);
    } else {
      await prefs.remove('my_profile_picture_url');
    }
    // Update handshake so newly connected nearby devices get the new picture
    await _bitchatService.updateProfilePictureUrl(url);
  }

  /// Stream that emits true/false whenever internet connectivity changes.
  /// Cached so all callers share the same stream instance.
  late final Stream<bool> internetStream = _connectivity.onConnectivityChanged
      .map((results) => results.any(
            (r) => r != ConnectivityResult.none && r != ConnectivityResult.bluetooth,
          ))
      .asBroadcastStream();

  /// Publicly trigger a retry of pending messages (e.g. after a contact resolves).
  void retryPendingMessages() => _retryPendingMessages();

  /// Publicly trigger a contact list backup (e.g. after manually adding a contact).
  void triggerContactsBackup() => _triggerContactsBackup();

  /// Wire up the WebSocket signaling service for real-time message delivery.
  void setSignalingService(SignalingService service) {
    _signalingService = service;
  }

  /// Handle a real-time payload that arrived via WebSocket.
  /// Called from main.dart via signalingService.onMessageReceived.
  Future<void> handleWebSocketPayload(Map<String, dynamic> payload) async {
    final type = payload['type'] as String? ?? '';

    // ── Ack: server confirms message stored + forwarded ──────────────────────
    if (type == 'message_ack') {
      final messageId = payload['messageId'] as String?;
      if (messageId != null && messageId.isNotEmpty) {
        await _dbService.updateMessageStatus(messageId, 'sent');
        _messageController.add(Message(
          id: messageId,
          senderPubkey: _keyManager.publicKey ?? '',
          receiverPubkey: '',
          content: '',
          type: 'status_update',
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          status: 'sent',
        ));
      }
      return;
    }

    // ── Incoming DM or reaction ───────────────────────────────────────────────
    if (type == 'dm' || type == 'reaction') {
      final messageId      = payload['messageId'] as String?;
      final senderPubkey   = payload['senderPubkey'] as String?;
      final encryptedContent = payload['encryptedContent'] as String?;
      final timestamp      = payload['timestamp'] as int?;
      if (messageId == null || senderPubkey == null ||
          encryptedContent == null || timestamp == null) return;

      final msg = Message(
        id:             messageId,
        senderPubkey:   senderPubkey,
        receiverPubkey: _keyManager.publicKey ?? '',
        content:        encryptedContent,
        timestamp:      timestamp,
        type:           payload['messageType'] as String? ?? type,
        senderName:     payload['senderName'] as String? ?? '',
        duration:       payload['duration'] as int? ?? 0,
        meshEncrypted:  true,
        transport:      'websocket',
      );
      await _onMessageReceived(msg);

      // Instantly send delivery receipt back via WebSocket
      _signalingService?.send({
        'type':           'delivery_receipt',
        'recipientPubkey': senderPubkey,
        'messageId':      messageId,
      });
      return;
    }

    // ── Delivery receipt ──────────────────────────────────────────────────────
    if (type == 'delivery_receipt') {
      final messageId    = payload['messageId'] as String?;
      final senderPubkey = payload['senderPubkey'] as String?;
      if (messageId != null) {
        await _onDeliveryReceipt({
          'messageId':      messageId,
          'receiverPubkey': senderPubkey ?? '',
        });
      }
      return;
    }

    // ── Read receipt ──────────────────────────────────────────────────────────
    if (type == 'read_receipt') {
      final messageId    = payload['messageId'] as String?;
      final senderPubkey = payload['senderPubkey'] as String?;
      if (messageId != null && senderPubkey != null) {
        await _onReadReceipt(messageId, senderPubkey);
      }
      return;
    }
  }

  Future<void> setUsername(String? name) async {
    await _keyManager.setUsername(name);
    _publishProfile();
    onUsernameChanged?.call(name);
  }

  void _publishProfile() {
    if (_keyManager.publicKey == null) return;
    final shortId = Contact.shortIdFor(_keyManager.publicKey!);
    _nostrService.publishProfile(
      username: _keyManager.username,
      shortId: shortId,
    );
  }

  Future<void> initialize() async {
    // Listen for messages from both services
    _nostrSub = _nostrService.messageStream.listen(_onMessageReceived);
    _bitchatSub = _bitchatService.messageStream.listen(_onMessageReceived);

    // Set keys for encryption/signing
    if (_keyManager.hasKeys) {
      _nostrService.setKeys(_keyManager.privateKey!, _keyManager.publicKey!);
    }

    // Load last event timestamp so relays send missed messages
    await _loadLastEventTimestamp();

    // Monitor network connectivity
    _connectivitySub = _connectivity.onConnectivityChanged.listen(_onConnectivityChanged);
    await _checkConnectivity();

    // Connect to Nostr relays if we have internet, and fetch messages from server
    if (_hasInternet) {
      await _connectNostr();
      _fetchPendingFromServer();
      _fetchOnlineMessages();
    }

    // Wire media services so BitChatService can save received audio/image files
    _bitchatService.voiceNoteService = voiceNoteService;
    _bitchatService.imageSharingService = imageSharingService;

    // Load locally cached profile picture URL for BLE handshakes
    final prefs = await SharedPreferences.getInstance();
    _profilePictureUrl = prefs.getString('my_profile_picture_url');

    // Start BitChat for offline capability
    if (_keyManager.publicKey != null) {
      await _bitchatService.start(
        _keyManager.publicKey!,
        username: _keyManager.username,
        shortId: Contact.shortIdFor(_keyManager.publicKey!),
        profilePictureUrl: _profilePictureUrl,
      );
    }

    // When a nearby device appears, try to deliver pending messages to it
    _nearbySub = _bitchatService.nearbyChangedStream.listen(_onNearbyChanged);

    // When mesh receives a message not for us, try forwarding via Nostr
    _meshRelayNostrSub = _bitchatService.relayToNostrStream.listen(_onMeshRelayToNostr);

    // Listen for delivery receipts from mesh
    _deliveryReceiptSub = _bitchatService.deliveryReceiptStream.listen(_onDeliveryReceipt);

    // Load previously received reactions into memory
    await _loadReactions();

    // Retry pending messages every 30 seconds
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _retryPendingMessages();
    });

    // Initial retry
    _retryPendingMessages();
  }

  /// Loads reaction messages from the messages table into the in-memory map.
  Future<void> _loadReactions() async {
    try {
      final db = await _dbService.database;
      final rows = await db.query('messages',
          where: 'type = ?', whereArgs: [AppConstants.typeReaction]);
      for (final row in rows) {
        try {
          final data = jsonDecode(row['content'] as String) as Map;
          final msgId = data['messageId'] as String?;
          final emoji = data['emoji'] as String?;
          final sender = row['senderPubkey'] as String?;
          if (msgId != null && emoji != null && sender != null) {
            _reactions
                .putIfAbsent(msgId, () => {})
                .putIfAbsent(emoji, () => {})
                .add(sender);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _checkConnectivity() async {
    final result = await _connectivity.checkConnectivity();
    _hasInternet = result.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hadInternet = _hasInternet;
    _hasInternet = results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet);

    // Just came online — reconnect to relays, retry pending, fetch server messages
    if (!hadInternet && _hasInternet) {
      _connectNostr();
      _retryPendingMessages();
      _fetchPendingFromServer();
      _fetchOnlineMessages();
    }
  }

  Future<void> _connectNostr() async {
    try {
      await _nostrService.connect();
      if (_keyManager.publicKey != null) {
        _nostrService.subscribe(_keyManager.publicKey!);
        _publishProfile();
      }
    } catch (_) {
      // Relay unavailable, will retry
    }
  }

  /// Fetch messages that were relayed to the server on our behalf while we
  /// were offline (A sent → C had internet → C posted to server → we fetch now).
  Future<void> _fetchPendingFromServer() async {
    try {
      final pending = await ServerService().fetchPendingMessages();
      for (final raw in pending) {
        try {
          final msg = Message(
            id: raw['message_id'] as String,
            senderPubkey: raw['sender_pubkey'] as String,
            receiverPubkey: raw['receiver_pubkey'] as String,
            content: raw['encrypted_content'] as String,
            timestamp: raw['timestamp'] as int,
            type: raw['message_type'] as String? ?? 'dm',
            meshEncrypted: true,
            transport: 'server',
          );
          await _onMessageReceived(msg);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _loadLastEventTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt('lastEventTimestamp');
    if (timestamp != null) {
      _nostrService.setLastEventTimestamp(timestamp);
    }
  }

  Future<void> _saveLastEventTimestamp(int timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lastEventTimestamp', timestamp);
  }

  void _onNearbyChanged(Set<String> nearbyPubkeys) {
    if (nearbyPubkeys.isEmpty) return;
    _deliverPendingToNearby(nearbyPubkeys);
    _syncNearbyProfilePictures(nearbyPubkeys);
  }

  /// Persist profile picture URLs received via BLE handshake into the contacts DB.
  /// This ensures the cached image is available even after the peer goes out of range.
  Future<void> _syncNearbyProfilePictures(Set<String> nearbyPubkeys) async {
    final pictures = _bitchatService.nearbyDeviceProfilePictures;
    for (final pubkey in nearbyPubkeys) {
      final url = pictures[pubkey];
      if (url == null || url.isEmpty) continue;
      // Update the contact's profilePictureUrl if not already set or different
      final existing = await _dbService.getContactByPubkey(pubkey);
      if (existing?.profilePictureUrl != url) {
        await _dbService.updateContactProfilePicture(pubkey, url);
        // Download locally so photo shows when offline
        final localPath = await ProfilePictureCacheService().download(pubkey, url);
        if (localPath != null) {
          await _dbService.updateContactLocalProfilePicture(pubkey, localPath);
        }
      }
    }
  }

  Future<void> _onMeshRelayToNostr(Message message) async {
    // A mesh message arrived that's not for us — if we have internet, forward it
    if (!_hasInternet) return;

    // Relay to server — stores for B to fetch + sends push notification to B.
    // Only relay encrypted DMs (not delivery receipts, typing, reactions).
    if (message.meshEncrypted && message.type != 'delivery_receipt') {
      final senderName =
          (await _dbService.getContactByPubkey(message.senderPubkey))?.name ??
              'Someone';
      ServerService().relayMeshMessage(
        messageId: message.id,
        senderPubkey: message.senderPubkey,
        receiverPubkey: message.receiverPubkey,
        encryptedContent: message.content,
        timestamp: message.timestamp,
        messageType: message.type,
        senderName: senderName,
      );
    }

    if (!_nostrService.isConnected) return;

    try {
      if (message.type == 'delivery_receipt') {
        // Wrap receipt as JSON in the content field so Nostr can carry it
        final receiptPayload = Message(
          id: message.id,
          senderPubkey: message.senderPubkey,
          receiverPubkey: message.receiverPubkey,
          content: jsonEncode({
            'type': 'delivery_receipt',
            'originalMessageId': message.content,
          }),
          timestamp: message.timestamp,
        );
        await _nostrService.sendMessage(receiptPayload);
      } else if (message.meshEncrypted) {
        // Message is already encrypted for the receiver — wrap it so Nostr carries
        // the ciphertext without re-encrypting. Include original sender so receiver
        // can derive the correct decryption key.
        final wrappedPayload = Message(
          id: message.id,
          senderPubkey: message.senderPubkey,
          receiverPubkey: message.receiverPubkey,
          content: jsonEncode({
            'type': 'mesh_relay',
            'encryptedContent': message.content,
            'originalSender': message.senderPubkey,
          }),
          timestamp: message.timestamp,
        );
        await _nostrService.sendMessage(wrappedPayload);
      } else {
        await _nostrService.sendMessage(message);
      }
    } catch (_) {
      // Failed to relay via Nostr, message continues through mesh
    }
  }

  Future<void> _deliverPendingToNearby(Set<String> nearbyPubkeys) async {
    final pending = await _dbService.getPendingMessages();
    for (final message in pending) {
      if (nearbyPubkeys.contains(message.receiverPubkey)) {
        final sent = await _trySendBitChat(message);
        if (sent) {
          await _dbService.updateMessageStatus(message.id, 'sent');
        }
      }
    }
  }

  void setMode(String mode) {
    _mode = mode;
  }

  int get ttl => _ttl;
  void setTTL(int ttl) {
    _ttl = ttl;
  }

  /// Send a voice note over Nearby Connections mesh.
  /// Send a voice note — tries server upload first (when online), falls back to BLE.
  ///
  /// Server path: upload audio → get URL → NIP-44 encrypt URL → send as DM with duration.
  /// BLE path: base64 encode → chunk over BLE mesh.
  ///
  /// [filePath] is the recorded audio file. [duration] is in seconds.
  /// Returns the message ID on success, null on failure.
  Future<String?> sendVoiceNote(
    String receiverPubkey,
    String filePath,
    int duration,
  ) async {
    if (_keyManager.publicKey == null) return null;

    // ── Online path: upload audio to server, send URL in encrypted DM ─────────
    if (_shouldUseOnline()) {
      final audioFile = File(filePath);
      if (await audioFile.exists()) {
        final url = await ServerService().uploadVoiceNote(audioFile);
        if (url != null) {
          final message = Message(
            id: _keyManager.generateMessageId(),
            senderPubkey: _keyManager.publicKey!,
            receiverPubkey: receiverPubkey,
            content: url,
            type: 'voice_note',
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            duration: duration,
            senderName: _keyManager.username,
            transport: 'server',
          );
          await _dbService.insertMessage(message);
          _messageController.add(message);
          await _trySendServer(message);
          await _dbService.updateMessageStatus(message.id, 'sent');
          return message.id;
        }
      }
    }

    // ── BLE fallback ──────────────────────────────────────────────────────────
    final message = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: filePath,
      type: 'voice_note',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: 3,
      duration: duration,
      senderName: _keyManager.username,
    );

    await _dbService.insertMessage(message);
    _messageController.add(message);

    final sent = await _bitchatService.sendVoiceNote(
      message: message,
      filePath: filePath,
      voiceNoteService: voiceNoteService,
    );

    if (!sent) {
      await _dbService.deleteMessage(message.id);
      return null;
    }

    await _dbService.updateMessageStatus(message.id, 'sent');
    return message.id;
  }

  /// Send an image — tries server upload first (when online), falls back to BLE.
  ///
  /// Server path: upload image → get URL → NIP-44 encrypt URL → send as DM.
  /// BLE path: compress to 50KB → chunk over BLE mesh.
  ///
  /// [filePath] is the local file path from [imageSharingService.pickImage].
  /// Returns the message ID on success, null on failure (UI should show error).
  Future<String?> sendImage(String receiverPubkey, String filePath) async {
    if (_keyManager.publicKey == null) return null;

    // ── Online path: upload image to server, send URL in encrypted DM ─────────
    if (_shouldUseOnline()) {
      final imageFile = File(filePath);
      if (await imageFile.exists()) {
        final url = await ServerService().uploadMessageImage(imageFile);
        if (url != null) {
          final message = Message(
            id: _keyManager.generateMessageId(),
            senderPubkey: _keyManager.publicKey!,
            receiverPubkey: receiverPubkey,
            content: url, // sender renders from URL; receiver decrypts URL and renders
            type: 'image',
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ttl: 3,
            senderName: _keyManager.username,
            transport: 'server',
          );
          await _dbService.insertMessage(message);
          _messageController.add(message);
          await _trySendServer(message);
          await _dbService.updateMessageStatus(message.id, 'sent');
          return message.id;
        }
      }
    }

    // ── BLE fallback ──────────────────────────────────────────────────────────
    final message = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: filePath, // sender displays from local path
      type: 'image',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: 3,
      senderName: _keyManager.username,
    );

    await _dbService.insertMessage(message);
    _messageController.add(message);

    final sent = await _bitchatService.sendImage(
      message: message,
      filePath: filePath,
      imageSharingService: imageSharingService,
    );

    if (!sent) {
      await _dbService.deleteMessage(message.id);
      return null;
    }

    await _dbService.updateMessageStatus(message.id, 'sent');
    return message.id;
  }

  Future<String?> sendMessage(String receiverPubkey, String content) async {
    if (_keyManager.publicKey == null) return null;
    final message = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: _ttl,
      senderName: _keyManager.username,
    );

    // Save to local DB first
    await _dbService.insertMessage(message);
    _messageController.add(message);

    // Try to send via all available transports independently.
    // Both are always attempted so a nearby receiver without internet still gets
    // the message via BLE even when server succeeds for the online path.
    bool sent = false;

    if (_shouldUseOnline()) {
      if (await _trySendServer(message)) sent = true;
    }

    if (_shouldUseOffline()) {
      if (await _trySendBitChat(message)) sent = true;
    }

    if (sent) {
      await _dbService.updateMessageStatus(message.id, 'sent');
    }
    // If not sent, stays as 'pending' — periodic retry will handle it

    return message.id;
  }

  bool _shouldUseOnline() {
    return (_mode == AppConstants.modeOnline || _mode == AppConstants.modeAuto) &&
        _hasInternet;
  }

  bool _shouldUseOffline() {
    return (_mode == AppConstants.modeOffline || _mode == AppConstants.modeAuto) &&
        _bitchatService.isActive;
  }

  /// Send via server (WhatsApp-style). Encrypts with NIP-44 before sending.
  /// Tries WebSocket first (real-time), falls back to REST POST.
  Future<bool> _trySendServer(Message message) async {
    if (!_hasInternet || _keyManager.privateKey == null) return false;
    if (!ServerService().isAuthenticated) return false; // tokens not ready yet — retry later
    try {
      // Encrypt content with NIP-44 before sending to server
      final encrypted = await _encryptForMesh(message);
      if (encrypted == null) return false;

      // ── Try WebSocket first (sub-100ms real-time delivery) ────────────────
      if (_signalingService?.isConnected == true) {
        final sent = _signalingService!.send({
          'type':             message.type == 'dm' ? 'dm' : message.type,
          'recipientPubkey':  message.receiverPubkey,
          'messageId':        message.id,
          'encryptedContent': encrypted.content,
          'timestamp':        message.timestamp,
          'senderName':       _keyManager.username ?? '',
          'messageType':      message.type,
          'duration':         message.duration,
        });
        if (sent) return true;
      }

      // ── Fallback to REST POST (store-and-forward) ─────────────────────────
      return await ServerService().sendOnlineMessage(
        messageId:        message.id,
        receiverPubkey:   message.receiverPubkey,
        encryptedContent: encrypted.content,
        timestamp:        message.timestamp,
        messageType:      message.type,
        senderName:       _keyManager.username ?? '',
        duration:         message.duration,
      );
    } catch (_) {
      return false;
    }
  }

  /// Fetch messages delivered via server while we were offline or in background.
  Future<void> _fetchOnlineMessages() async {
    try {
      final messages = await ServerService().fetchOnlineMessages();
      for (final raw in messages) {
        try {
          final msg = Message(
            id:             raw['message_id'] as String,
            senderPubkey:   raw['sender_pubkey'] as String,
            receiverPubkey: raw['receiver_pubkey'] as String,
            content:        raw['encrypted_content'] as String,
            timestamp:      raw['timestamp'] as int,
            type:           raw['message_type'] as String? ?? 'dm',
            senderName:     raw['sender_name'] as String? ?? '',
            duration:       raw['duration'] as int? ?? 0,
            meshEncrypted:  true,
            transport:      'server',
          );
          await _onMessageReceived(msg);

          // Send read receipt when chat is open — for now mark delivered
          ServerService().sendReceipt(msg.id, 'delivered');
        } catch (_) {}
      }

      // Sync tick marks for messages we sent
      _syncMessageStatuses();
    } catch (_) {}
  }

  /// Sync delivery/read status of sent messages from server (tick marks).
  Future<void> _syncMessageStatuses() async {
    try {
      final statuses = await ServerService().fetchMessageStatuses();
      for (final s in statuses) {
        final id     = s['message_id'] as String?;
        final status = s['status'] as String?;
        if (id != null && status != null) {
          await _dbService.updateMessageStatus(id, status);
          _messageController.add(Message(
            id: id, senderPubkey: '', receiverPubkey: '',
            content: '', timestamp: 0, type: 'status_update',
            status: status,
          ));
        }
      }
    } catch (_) {}
  }

  Future<bool> _trySendBitChat(Message message) async {
    if (!_bitchatService.isActive) return false;
    // Keep as pending if we have no connections at all.
    // Use hasAnyBleConnection (not nearbyPubkeys) because the bidirectional
    // handshake may not have completed yet — we still have a write path.
    if (_bitchatService.nearbyPubkeys.isEmpty &&
        !_bitchatService.hasAnyBleConnection) return false;
    try {
      final encrypted = await _encryptForMesh(message);
      if (encrypted == null) return false; // encryption failed — don't send plaintext
      await _bitchatService.sendMessage(encrypted);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Encrypt message content for mesh transport using NIP-44 (XChaCha20-Poly1305)
  // Returns null if encryption fails — caller must not send plaintext over mesh
  Future<Message?> _encryptForMesh(Message message) async {
    if (_keyManager.privateKey == null) return null;
    // Don't encrypt receipts, status updates, or ephemeral/metadata types.
    // Reactions contain only {messageId, emoji} — not sensitive, and must remain
    // parseable as JSON on the receiving side before decryption context is available.
    if (message.type == 'delivery_receipt' ||
        message.type == 'read_receipt' ||
        message.type == 'status_update' ||
        message.type == AppConstants.typeReaction ||
        message.type == AppConstants.typeTypingIndicator) {
      return message;
    }
    try {
      final encrypted = await _nip44.encrypt(
        _keyManager.privateKey!,
        message.receiverPubkey,
        message.content,
      );
      return message.copyWith(content: encrypted, meshEncrypted: true);
    } catch (_) {
      return null; // encryption failed — don't leak plaintext
    }
  }

  // Decrypt mesh message content — NIP-44 first, fallback to NIP-04
  Future<Message> _decryptFromMesh(Message message) async {
    if (_keyManager.privateKey == null) return message;
    if (!message.meshEncrypted) return message;
    if (message.type == 'delivery_receipt' || message.type == 'status_update') {
      return message;
    }
    try {
      if (Nip44.isNip44(message.content)) {
        final decrypted = await _nip44.decrypt(
          _keyManager.privateKey!,
          message.senderPubkey,
          message.content,
        );
        return message.copyWith(content: decrypted, meshEncrypted: false);
      } else {
        // Fallback to NIP-04 for older messages
        final decrypted = _nip04.decrypt(
          _keyManager.privateKey!,
          message.senderPubkey,
          message.content,
        );
        return message.copyWith(content: decrypted, meshEncrypted: false);
      }
    } catch (_) {
      return message;
    }
  }

  Future<void> _onMessageReceived(Message message) async {
    // ── Step 1: Drop ephemeral types that must never be stored ────────────────
    // Typing indicators are handled by BitChatService via typingStream.
    // If one leaks through here (e.g. old BLE path), drop it silently.
    if (message.type == AppConstants.typeTypingIndicator) return;

    // ── Step 2: Delivery receipts — never encrypted, handle immediately ───────
    if (message.type == 'delivery_receipt') {
      if (message.content.isNotEmpty) {
        await _onDeliveryReceipt({
          'messageId': message.content,
          'receiverPubkey': message.senderPubkey,
        });
      }
      return;
    }

    // ── Step 3: Decrypt before ALL other type-specific handling ───────────────
    // Reactions, read receipts, group invites, and call signals all need
    // plaintext content. Decrypting here once is correct and safe.
    final decrypted = message.meshEncrypted ? await _decryptFromMesh(message) : message;

    // ── Step 4: Reactions — not encrypted, but must parse JSON ───────────────
    if (decrypted.type == AppConstants.typeReaction) {
      if (_processingIds.contains(decrypted.id)) return;
      _processingIds.add(decrypted.id);
      try {
        final data = jsonDecode(decrypted.content) as Map;
        final msgId = data['messageId'] as String?;
        final emoji = data['emoji'] as String?;
        if (msgId != null && emoji != null) {
          await _dbService.insertMessage(decrypted);
          _addReaction(msgId, emoji, decrypted.senderPubkey);
        }
      } catch (_) {}
      return;
    }

    // ── Step 5: JSON-wrapped sub-types (read receipts, invites, call signals) ─
    try {
      final parsed = jsonDecode(decrypted.content);
      if (parsed is Map) {
        if (parsed['type'] == 'read_receipt') {
          final originalMessageId = parsed['originalMessageId'] as String?;
          if (originalMessageId != null && originalMessageId.isNotEmpty) {
            await _onReadReceipt(originalMessageId, decrypted.senderPubkey);
          }
          return;
        }
        if (parsed['__type'] == 'group_invite') {
          onGroupInvite?.call(
            parsed['channelId'] as String? ?? '',
            parsed['channelName'] as String? ?? '',
            parsed['adminPubkey'] as String? ?? '',
          );
          return;
        }
        if (parsed['__type'] == 'group_removal') {
          onGroupRemoval?.call(parsed['channelId'] as String? ?? '');
          return;
        }
        // ── WebRTC call signals ──
        final callType = parsed['__type'] as String? ?? '';
        if (callType.startsWith('call_')) {
          final callId = parsed['callId'] as String? ?? '';
          switch (callType) {
            case 'call_offer':
              onCallOffer?.call(
                callId,
                decrypted.senderPubkey,
                parsed['callerName'] as String?,
                parsed['sdp'] as String? ?? '',
                parsed['sdpType'] as String? ?? 'offer',
                parsed['isVideo'] as bool? ?? false,
              );
            case 'call_answer':
              onCallAnswer?.call(
                callId,
                parsed['sdp'] as String? ?? '',
                parsed['sdpType'] as String? ?? 'answer',
              );
            case 'call_ice':
              onCallIce?.call(
                callId,
                parsed['candidate'] as String? ?? '',
                parsed['sdpMid'] as String? ?? '',
                (parsed['sdpMLineIndex'] as int?) ?? 0,
              );
            case 'call_ended':
              onCallEnded?.call(callId);
            case 'call_declined':
              onCallDeclined?.call(callId);
            case 'call_busy':
              onCallBusy?.call(callId);
          }
          return; // never store call signals as chat messages
        }
      }
    } catch (_) {
      // Not JSON — regular text/voice/image message, continue to storage
    }

    // ── Step 6: Regular messages (text, voice_note, image) ───────────────────
    // In-memory guard prevents duplicate emit when Nostr + BLE deliver
    // the same message concurrently before either DB write commits.
    if (_processingIds.contains(decrypted.id)) return;
    _processingIds.add(decrypted.id);

    final seen = await _dbService.hasSeenMessage(decrypted.id);
    if (seen) return;

    // Store and emit immediately — message appears in chat right away.
    // For online images content is a URL; ImageDownloadService downloads it
    // to local storage in the background (updates DB when done).
    await _dbService.insertMessage(decrypted);
    _messageController.add(decrypted);

    // ── Online image: kick off background download via ImageDownloadService ──
    if (decrypted.type == 'image' &&
        (decrypted.content.startsWith('http://') ||
            decrypted.content.startsWith('https://'))) {
      ImageDownloadService().download(
        decrypted.id,
        decrypted.content,
        _dbService,
        imageSharingService,
      );
    }

    // Auto-create contact if sender is unknown
    final wasNew = await _dbService.ensureContact(
      decrypted.senderPubkey,
      name: decrypted.senderName,
    );

    // Auto-update contact name if sender included their display name
    if (decrypted.senderName != null && decrypted.senderName!.isNotEmpty) {
      await _dbService.updateContactName(decrypted.senderPubkey, decrypted.senderName!);
    }

    // Back up contacts whenever a new one is auto-created
    if (wasNew) _triggerContactsBackup();

    // If sender has no name/photo yet and we have internet, silently fetch
    // their profile from server so they don't show as an unknown pubkey.
    _resolveUnknownSender(decrypted.senderPubkey);

    _saveLastEventTimestamp(decrypted.timestamp);
  }

  Future<void> _onDeliveryReceipt(Map<String, String> receipt) async {
    final messageId = receipt['messageId'];
    if (messageId == null) return;

    // Update the message status to 'delivered' in our DB
    await _dbService.updateMessageStatus(messageId, 'delivered');

    // Notify UI by emitting a synthetic status update
    try {
      _messageController.add(Message(
        id: messageId,
        senderPubkey: _keyManager.publicKey ?? '',
        receiverPubkey: receipt['receiverPubkey'] ?? '',
        content: '',
        type: 'status_update',
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        status: 'delivered',
      ));
    } catch (_) {}
  }

  Future<void> _onReadReceipt(String messageId, String readerPubkey) async {
    await _dbService.updateMessageStatus(messageId, 'read');

    // Notify UI so it shows 'read' status (eye icon)
    _messageController.add(Message(
      id: messageId,
      senderPubkey: _keyManager.publicKey ?? '',
      receiverPubkey: readerPubkey,
      content: '',
      type: 'status_update',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'read',
    ));
  }

  /// Trigger a contact list backup — fire-and-forget, never blocks UI.
  void _triggerContactsBackup() {
    if (_keyManager.privateKey == null || _keyManager.publicKey == null) return;
    ContactsBackupService().backup(
      dbService: _dbService,
      privateKey: _keyManager.privateKey!,
      publicKey: _keyManager.publicKey!,
    );
  }

  /// Silently fetch server profile for a sender who has no name/photo yet.
  /// Fire-and-forget — never blocks message delivery.
  void _resolveUnknownSender(String senderPubkey) {
    if (!_hasInternet || senderPubkey.isEmpty) return;
    // Run async without awaiting so it never delays message processing
    () async {
      try {
        final contact = await _dbService.getContactByPubkey(senderPubkey);
        // Skip if we already have both name and photo
        if (contact != null &&
            contact.name != null && contact.name!.isNotEmpty &&
            contact.profilePictureLocalPath != null) return;

        final result = await ServerService().getProfile(senderPubkey);
        if (result == null) return;

        final name = result['display_name'] as String?;
        final picUrl = result['profile_picture_url'] as String?;

        if (name != null && name.isNotEmpty) {
          await _dbService.updateContactName(senderPubkey, name);
        }
        if (picUrl != null && picUrl.isNotEmpty &&
            picUrl != contact?.profilePictureUrl) {
          await _dbService.updateContactProfilePicture(senderPubkey, picUrl);
          final localPath = await ProfilePictureCacheService().download(senderPubkey, picUrl);
          if (localPath != null) {
            await _dbService.updateContactLocalProfilePicture(senderPubkey, localPath);
          }
        }
      } catch (_) {}
    }();
  }

  Future<void> _retryPendingMessages() async {
    final pending = await _dbService.getPendingMessages();
    for (final message in pending) {
      bool sent = false;

      if (_shouldUseOnline()) {
        if (await _trySendServer(message)) sent = true;
      }

      if (_shouldUseOffline()) {
        if (await _trySendBitChat(message)) sent = true;
      }

      if (sent) {
        await _dbService.updateMessageStatus(message.id, 'sent');
        // Notify UI so tick mark updates from pending → sent without manual refresh
        _messageController.add(Message(
          id: message.id,
          senderPubkey: message.senderPubkey,
          receiverPubkey: message.receiverPubkey,
          content: '',
          type: 'status_update',
          timestamp: message.timestamp,
          status: 'sent',
        ));
      }
    }
  }

  Future<List<Message>> getChatMessages(String contactPubkey,
      {int limit = 50, int offset = 0}) async {
    if (_keyManager.publicKey == null) return [];
    return _dbService.getMessages(_keyManager.publicKey!, contactPubkey,
        limit: limit, offset: offset);
  }

  Future<void> updateMessageContent(String id, String content) =>
      _dbService.updateMessageContent(id, content);

  Future<void> deleteConversation(String contactPubkey) async {
    if (_keyManager.publicKey == null) return;
    // Mark as read first so unread badge drops to 0 before delete
    await _dbService.markMessagesAsRead(_keyManager.publicKey!, contactPubkey);
    await _dbService.deleteMessagesForContact(_keyManager.publicKey!, contactPubkey);
    // Emit to stream so badge listeners (HomeScreen) recalculate unread count
    _messageController.add(Message(
      id: '',
      senderPubkey: contactPubkey,
      receiverPubkey: _keyManager.publicKey!,
      content: '',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'deleted',
    ));
  }

  Future<void> markAsRead(String contactPubkey) async {
    if (_keyManager.publicKey == null) return;
    // Get unread messages received FROM this contact before marking them read
    final unread = await _dbService.getUnreadMessagesFrom(contactPubkey, _keyManager.publicKey!);
    await _dbService.markMessagesAsRead(_keyManager.publicKey!, contactPubkey);
    // Send a read receipt for each received message
    for (final msg in unread) {
      await _sendReadReceipt(msg.id, contactPubkey);
    }
  }

  Future<void> _sendReadReceipt(String messageId, String senderPubkey) async {
    if (_keyManager.publicKey == null) return;

    final receipt = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: senderPubkey,
      content: jsonEncode({
        'type': 'read_receipt',
        'originalMessageId': messageId,
      }),
      type: 'read_receipt',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: 3,
    );

    // Always persist first — ensures retry timer can recover from silent WS failures
    await _dbService.insertMessage(receipt);

    bool sent = false;

    // Try WebSocket first (fastest path)
    if (_shouldUseOnline() && _signalingService?.isConnected == true) {
      final wsSent = _signalingService!.send({
        'type':            'read_receipt',
        'recipientPubkey': senderPubkey,
        'messageId':       messageId,
      });
      if (wsSent) sent = true;
    }

    if (!sent && _shouldUseOnline()) {
      if (await _trySendServer(receipt)) sent = true;
    }
    if (!sent && _shouldUseOffline()) {
      if (await _trySendBitChat(receipt)) sent = true;
    }
    if (sent) {
      await _dbService.updateMessageStatus(receipt.id, 'sent');
    }
    // If not sent, stays as 'pending' — _retryPendingMessages picks it up
  }

  Future<Map<String, Message>> getLastMessages() async {
    if (_keyManager.publicKey == null) return {};
    return _dbService.getLastMessages(_keyManager.publicKey!);
  }

  Future<Map<String, int>> getUnreadCounts() async {
    if (_keyManager.publicKey == null) return {};
    return _dbService.getUnreadCounts(_keyManager.publicKey!);
  }

  void dispose() {
    _nostrSub?.cancel();
    _bitchatSub?.cancel();
    _nearbySub?.cancel();
    _connectivitySub?.cancel();
    _meshRelayNostrSub?.cancel();
    _deliveryReceiptSub?.cancel();
    _retryTimer?.cancel();
    _nostrService.dispose();
    _bitchatService.dispose();
    voiceNoteService.dispose();
    _messageController.close();
    _reactionsController.close();
  }
}
