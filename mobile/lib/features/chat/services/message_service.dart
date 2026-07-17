import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:nostr_tools/nostr_tools.dart' show Nip04;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bitchat_messenger/core/bounded_set.dart';
import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/core/key_manager.dart';
import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/nostr_service.dart';
import 'package:bitchat_messenger/features/mesh/services/bitchat_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/core/signaling_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/features/contacts/services/contacts_backup_service.dart';

class MessageService {
  final NostrService _nostrService;
  final BitChatService _bitchatService;
  final DatabaseService _dbService;
  final KeyManager _keyManager;
  final Connectivity _connectivity = Connectivity();
  final _nip04 = Nip04(); // kept for backward-compatible decryption
  final _nip44 = Nip44(); // new default encryption

  final _messageController = StreamController<Message>.broadcast();
  String _mode = AppConstants.modeAuto;
  int _ttl = AppConstants.defaultTTL;
  bool _hasInternet = false;
  String? _profilePictureUrl;
  // In-memory dedup set — guards against the race condition where server and
  // BLE deliver the same message simultaneously before either DB write commits.
  final _processingIds = BoundedSet<String>(2000);
  SignalingService? _signalingService;
  StreamSubscription? _bitchatSub;
  StreamSubscription? _nearbySub;
  StreamSubscription? _connectivitySub;
  StreamSubscription? _meshRelayServerSub;
  StreamSubscription? _deliveryReceiptSub;
  Timer? _retryTimer;
  Set<String> _prevNearbyPubkeys = {};

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

  /// 'Visible to others' → actually stop/start BLE advertising so the
  /// radar visibility matches the toggle (server flags alone don't).
  Future<void> setDiscoverableNearby(bool on) =>
      _bitchatService.setDiscoverable(on);

  /// Triggers an immediate pending-contact resolution attempt — wired to
  /// ContactResolverService.resolveNow in main.dart. Screens call this right
  /// after saving a pending contact so it resolves without an app restart.
  Future<void> Function()? resolvePendingContacts;

  /// Called when a group invite DM (with the group key) is received —
  /// wired to GroupService.handleInvite in main.dart.
  void Function(Map<String, dynamic> invite)? onGroupInviteData;

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
  String get mode => _mode;
  String? get publicKey => _keyManager.publicKey;
  String? get privateKey => _keyManager.privateKey;
  String? get username => _keyManager.username;
  DatabaseService get dbService => _dbService;
  Set<String> get nearbyUsers => _bitchatService.nearbyPubkeys;
  Stream<Set<String>> get nearbyChangedStream => _bitchatService.nearbyChangedStream;
  bool get hasInternet => _hasInternet;
  bool get isSignalingConnected => _signalingService?.isConnected == true;
  bool get hasNearbyDevices => _bitchatService.nearbyPubkeys.isNotEmpty;
  Map<String, String> get nearbyDeviceNames => _bitchatService.nearbyDeviceNames;
  Map<String, String> get nearbyDeviceProfilePictures => _bitchatService.nearbyDeviceProfilePictures;
  String? get profilePictureUrl => _profilePictureUrl;

  /// Send a typing indicator to the current chat contact (throttled by caller).
  Future<void> sendTypingIndicator(String receiverPubkey) async {
    await _bitchatService.sendTypingIndicator(receiverPubkey);
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

  /// Re-fetch messages from the server after a late authentication.
  ///
  /// Called from main.dart after [ServerService.connectAndRegister] completes
  /// on a cold-start delay — by that point [initialize] has already run with
  /// no auth token so the initial fetches returned empty. This re-runs them.
  Future<void> fetchMissedServerMessages() async {
    if (!_hasInternet) return;
    await _fetchPendingFromServer();
    await _fetchOnlineMessages();
  }

  /// Publicly trigger a contact list backup (e.g. after manually adding a contact).
  void triggerContactsBackup() => _triggerContactsBackup();

  /// Wire up the WebSocket signaling service for real-time message delivery.
  void setSignalingService(SignalingService service) {
    _signalingService = service;
  }

  /// Handle a real-time payload that arrived via WebSocket.
  /// Called from main.dart via signalingService.onMessageReceived.
  /// Wired to GroupService.handleIncomingGroupMessage in main.dart.
  Future<void> Function(Map<String, dynamic> payload)? onGroupMessage;

  Future<void> handleWebSocketPayload(Map<String, dynamic> payload) async {
    final type = payload['type'] as String? ?? '';

    // ── Group message (blind-group-aware fan-out from server) ────────────────
    if (type == 'group_dm') {
      await onGroupMessage?.call(payload);
      return;
    }

    // ── Ack: server confirms message stored + forwarded ──────────────────────
    if (type == 'message_ack') {
      final messageId = payload['messageId'] as String?;
      if (messageId != null && messageId.isNotEmpty) {
        // Use updateMessageStatusIfHigher — if message is already 'delivered'
        // or 'read', the ack must not regress it back to 'sent'.
        await _dbService.updateMessageStatusIfHigher(messageId, 'sent');
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

    // ── Incoming DM ──────────────────────────────────────────────────────────
    if (type == 'dm') {
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
      // senderPubkey may be absent if the server didn't add it to the relayed
      // payload — default to empty string so the DB update still fires.
      final senderPubkey = payload['senderPubkey'] as String? ?? '';
      if (messageId != null) {
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
    // Profile is synced to server via ServerService during connectAndRegister.
    // No relay publishing needed.
  }

  Future<void> initialize() async {
    // Cancel any existing subscriptions before re-subscribing (guards against
    // initialize() being called more than once, which would leak listeners).
    _bitchatSub?.cancel();
    _nearbySub?.cancel();
    _connectivitySub?.cancel();
    _meshRelayServerSub?.cancel();
    _deliveryReceiptSub?.cancel();
    _retryTimer?.cancel();

    _bitchatSub = _bitchatService.messageStream.listen(_onMessageReceived);
    _nearbySub = _bitchatService.nearbyChangedStream.listen(_onNearbyChanged);
    _meshRelayServerSub = _bitchatService.relayToNostrStream.listen(_onMeshRelayToServer);
    // BLE delivery receipts are unreliable — only WebSocket receipts update tick
    // status. Drain the stream to prevent backpressure but discard the events.
    _deliveryReceiptSub = _bitchatService.deliveryReceiptStream.listen((_) {});

    _connectivitySub = _connectivity.onConnectivityChanged.listen(_onConnectivityChanged);
    await _checkConnectivity();

    // Load locally cached profile picture URL for BLE handshakes
    final prefs = await SharedPreferences.getInstance();
    _profilePictureUrl = prefs.getString('my_profile_picture_url');

    // ── From here on everything is fire-and-forget ──────────────────────────
    // BLE/mesh startup — can take 500ms–1s on Android.
    // Not needed before the HomeScreen is shown.

    if (_hasInternet) {
      _fetchPendingFromServer();
      _fetchOnlineMessages();
    }

    if (_keyManager.publicKey != null) {
      _bitchatService.start( // no await — BLE starts in background
        _keyManager.publicKey!,
        username: _keyManager.username,
        shortId: Contact.shortIdFor(_keyManager.publicKey!),
        profilePictureUrl: _profilePictureUrl,
      );
    }

    // Retry pending messages every 30 seconds
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _retryPendingMessages();
    });

    // Initial retry
    _retryPendingMessages();
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

    // Just came online — retry pending messages and fetch from server
    if (!hadInternet && _hasInternet) {
      _retryPendingMessages();
      _fetchPendingFromServer();
      _fetchOnlineMessages();
    }
  }

  /// Fetch messages that were relayed to the server on our behalf while we
  /// were offline (A sent → C had internet → C posted to server → we fetch now).
  Future<void> _fetchPendingFromServer() async {
    try {
      final pending = await ServerService().fetchPendingMessages();
      for (final raw in pending) {
        try {
          if ((raw['message_type'] as String?) == 'group_dm') {
            await _routePendingGroupRow(raw);
            continue;
          }
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

  void _onNearbyChanged(Set<String> nearbyPubkeys) {
    // Persist any newly-seen BLE devices to history so they remain visible
    // in the Discovery tab even after disconnecting.
    final added = nearbyPubkeys.difference(_prevNearbyPubkeys);
    _prevNearbyPubkeys = Set.of(nearbyPubkeys);
    if (added.isNotEmpty) {
      final names = _bitchatService.nearbyDeviceNames;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final pubkey in added) {
        _dbService.upsertBleHistory(pubkey, names[pubkey], now);
      }
    }

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

  /// A BLE mesh message arrived that's not for us — relay it to the server
  /// so the intended receiver can fetch it (with push notification).
  Future<void> _onMeshRelayToServer(Message message) async {
    if (!_hasInternet) return;
    if (!message.meshEncrypted) return;
    if (message.type == 'delivery_receipt' || message.type == 'typing_indicator') return;

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

  /// Send an image message. Routes to the online (Cloudinary) or offline (BLE chunks) path.
  /// Always stores a pending bubble immediately — sends when connectivity is available,
  /// or queues for the retry timer if offline.
  /// Returns the message ID (always, unless key is missing).
  Future<String?> sendImageMessage(File imageFile, String receiverPubkey) async {
    if (_keyManager.publicKey == null) return null;

    final messageId = _keyManager.generateMessageId();
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Copy to stable path immediately — ImagePicker temp cache may be cleared
    // before connectivity returns if the message stays pending offline.
    final dir = await getApplicationDocumentsDirectory();
    final stablePath = '${dir.path}/img_out_$messageId.jpg';
    await imageFile.copy(stablePath);
    final stableFile = File(stablePath);

    final optimistic = Message(
      id: messageId,
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: 'local:$stablePath',
      type: 'image',
      timestamp: timestamp,
      senderName: _keyManager.username,
      status: 'pending',
    );
    await _dbService.insertMessage(optimistic);
    _messageController.add(optimistic);

    final canOnline = _hasInternet &&
        ServerService().isAuthenticated &&
        _keyManager.privateKey != null;
    final canBle = _shouldUseOffline();

    if (!canOnline && !canBle) return messageId; // queued, retry timer will send

    if (canOnline) {
      return await _sendImageOnline(stableFile, receiverPubkey, messageId, timestamp, optimistic);
    }

    // BLE only — skip if too large, keep pending until internet is available
    final sizeBytes = await stableFile.length();
    if (sizeBytes > 150 * 1024) return messageId;

    return await _sendImageViaBle(stableFile, receiverPubkey, messageId, timestamp, optimistic);
  }

  /// Online path: compress → upload to Cloudinary → send NIP-44 encrypted URL.
  Future<String?> _sendImageOnline(
    File imageFile,
    String receiverPubkey,
    String messageId,
    int timestamp,
    Message optimistic,
  ) async {
    try {
      final url = await ServerService().uploadChatImage(imageFile);

      // Store plaintext URL so the bubble renders after reload (both sender and receiver)
      await _dbService.updateMessageContent(messageId, url);
      _messageController.add(optimistic.copyWith(content: url));

      final encryptedUrl = await _nip44.encrypt(
        _keyManager.privateKey!,
        receiverPubkey,
        url,
      );

      bool sent = false;

      if (_signalingService?.isConnected == true) {
        sent = _signalingService!.send({
          'type': 'dm',
          'recipientPubkey': receiverPubkey,
          'messageId': messageId,
          'encryptedContent': encryptedUrl,
          'timestamp': timestamp,
          'senderName': _keyManager.username ?? '',
          'messageType': 'image',
        });
      }

      if (!sent) {
        sent = await ServerService().sendOnlineMessage(
          messageId: messageId,
          receiverPubkey: receiverPubkey,
          encryptedContent: encryptedUrl,
          timestamp: timestamp,
          messageType: 'image',
          senderName: _keyManager.username ?? '',
        );
      }

      final finalStatus = sent ? 'sent' : 'failed';
      await _dbService.updateMessageStatus(messageId, finalStatus);
      _messageController.add(optimistic.copyWith(content: url, status: finalStatus));
      return messageId;
    } catch (_) {
      // Upload/send failed — keep as pending, retry timer will retry
      return null;
    }
  }

  /// BLE offline path: read bytes → validate size → copy to stable path →
  /// base64-encode → send as 180-byte chunks.
  Future<String?> _sendImageViaBle(
    File imageFile,
    String receiverPubkey,
    String messageId,
    int timestamp,
    Message optimistic,
  ) async {
    try {
      final bytes = await imageFile.readAsBytes();

      // Hard reject: >150 KB raw is ~200 KB base64 → ~1100 chunks → unreliable over BLE.
      // Keep as pending instead of failing — will retry via internet when available.
      if (bytes.lengthInBytes > 150 * 1024) return null;

      // Copy image to app documents directory so the bubble keeps showing
      // if ImagePicker's temp cache is cleared before the user reopens the chat.
      final dir = await getApplicationDocumentsDirectory();
      final stablePath = '${dir.path}/img_out_$messageId.jpg';
      await imageFile.copy(stablePath);
      await _dbService.updateMessageContent(messageId, 'local:$stablePath');
      _messageController.add(optimistic.copyWith(content: 'local:$stablePath'));

      final b64 = base64Encode(bytes);

      // Message object carries the sender/receiver/timestamp metadata for chunk headers
      final msg = Message(
        id: messageId,
        senderPubkey: _keyManager.publicKey!,
        receiverPubkey: receiverPubkey,
        content: '',
        type: 'image',
        timestamp: timestamp,
        senderName: _keyManager.username,
        transport: 'bitchat',
      );

      final sent = await _bitchatService.sendMediaChunked(
        message: msg,
        mediaType: 'image',
        base64Data: b64,
      );

      final status = sent ? 'sent' : 'failed';
      await _dbService.updateMessageStatus(messageId, status);
      _messageController.add(optimistic.copyWith(content: 'local:$stablePath', status: status));
      return sent ? messageId : null;
    } catch (_) {
      await _dbService.updateMessageStatus(messageId, 'failed');
      _messageController.add(optimistic.copyWith(status: 'failed'));
      return null;
    }
  }

  Future<String?> sendMessage(String receiverPubkey, String content,
      {String? replyToId, String? replySnippet}) async {
    if (_keyManager.publicKey == null) return null;
    final message = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: _ttl,
      senderName: _keyManager.username,
      replyToId: replyToId,
      replySnippet: replySnippet,
    );

    // Save to local DB first (plain body; reply metadata in columns)
    await _dbService.insertMessage(message);
    _messageController.add(message);

    // On the wire, reply metadata travels INSIDE the encrypted payload.
    final wire = replyToId == null
        ? message
        : message.copyWith(
            content: jsonEncode({
              '__type': 'text_v2',
              'body': content,
              'replyToId': replyToId,
              if (replySnippet != null) 'replySnippet': replySnippet,
            }),
          );

    // Try both transports independently — if sender has internet AND receiver is
    // nearby without internet, BLE must still fire even though server succeeded.
    // The receiver's dedup set (BoundedSet) prevents showing the message twice
    // if both paths happen to reach them.
    bool sent = false;

    if (_shouldUseOnline()) {
      if (await _trySendServer(wire)) sent = true;
    }
    if (_shouldUseOffline()) {
      if (await _trySendBitChat(wire)) sent = true;
    }

    if (sent) {
      await _dbService.updateMessageStatus(message.id, 'sent');
      // Emit the status change — without this the open chat keeps showing
      // 'Sending…' until the next reload (the DB alone doesn't update UI).
      _messageController.add(Message(
        id: message.id,
        senderPubkey: '',
        receiverPubkey: '',
        content: '',
        type: 'status_update',
        timestamp: message.timestamp,
        status: 'sent',
      ));
    }
    // On first failure keep status as 'pending' — retry timer will escalate
    // to 'failed' after 2 minutes if connectivity is available but send keeps failing.

    return message.id;
  }

  /// Record-and-send voice note. Online-only for v1 (BLE voice would be
  /// minutes per clip at 180-byte chunks). Offline: stays pending.
  Future<String?> sendVoiceMessage(
      File audioFile, int seconds, String receiverPubkey) async {
    if (_keyManager.publicKey == null) return null;
    final messageId = _keyManager.generateMessageId();
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final dir = await getApplicationDocumentsDirectory();
    final stablePath = '${dir.path}/voice_out_$messageId.m4a';
    await audioFile.copy(stablePath);

    final optimistic = Message(
      id: messageId,
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: 'local:$stablePath',
      type: 'voice_note',
      timestamp: timestamp,
      senderName: _keyManager.username,
      status: 'pending',
      replySnippet: seconds.toString(), // duration rides here (see voice_v2)
    );
    await _dbService.insertMessage(optimistic);
    _messageController.add(optimistic);

    if (!_hasInternet || !ServerService().isAuthenticated) return messageId;

    try {
      final url = await ServerService().uploadChatAudio(File(stablePath));
      await _dbService.updateMessageContent(messageId, url);
      _messageController.add(optimistic.copyWith(content: url));

      final encrypted = await _nip44.encrypt(
        _keyManager.privateKey!,
        receiverPubkey,
        jsonEncode({'__type': 'voice_v2', 'url': url, 'secs': seconds}),
      );

      bool sent = false;
      if (_signalingService?.isConnected == true) {
        sent = _signalingService!.send({
          'type': 'dm',
          'recipientPubkey': receiverPubkey,
          'messageId': messageId,
          'encryptedContent': encrypted,
          'timestamp': timestamp,
          'senderName': _keyManager.username ?? '',
          'messageType': 'voice_note',
        });
      }
      if (!sent) {
        sent = await ServerService().sendOnlineMessage(
          messageId: messageId,
          receiverPubkey: receiverPubkey,
          encryptedContent: encrypted,
          timestamp: timestamp,
          messageType: 'voice_note',
          senderName: _keyManager.username ?? '',
        );
      }
      final finalStatus = sent ? 'sent' : 'failed';
      await _dbService.updateMessageStatus(messageId, finalStatus);
      _messageController.add(
          optimistic.copyWith(content: url, status: finalStatus));
      return messageId;
    } catch (_) {
      return messageId; // stays pending; retry timer will pick it up
    }
  }

  /// React to a message with an emoji. Stored locally as a 'reaction' row
  /// pointing at the target via replyToId; sent as a wrapped payload.
  Future<void> sendReaction(
      String receiverPubkey, String targetId, String emoji) async {
    if (_keyManager.publicKey == null) return;
    final row = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: emoji,
      type: 'reaction',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'read',
      replyToId: targetId,
    );
    await _dbService.insertMessage(row);
    _messageController.add(row);

    final wire = row.copyWith(
      content: jsonEncode(
          {'__type': 'reaction', 'targetId': targetId, 'emoji': emoji}),
    );
    if (_shouldUseOnline()) await _trySendServer(wire);
    if (_shouldUseOffline()) await _trySendBitChat(wire);
  }

  /// Delete for everyone: tombstone locally and tell the peer to do the same.
  Future<void> deleteMessageForEveryone(
      String receiverPubkey, String targetId) async {
    if (_keyManager.publicKey == null) return;
    await _dbService.updateMessageContent(targetId, '🚫 Message deleted');
    _messageController.add(Message(
      id: targetId,
      senderPubkey: '',
      receiverPubkey: '',
      content: '',
      type: 'status_update',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      status: 'read',
    ));
    final wire = Message(
      id: _keyManager.generateMessageId(),
      senderPubkey: _keyManager.publicKey!,
      receiverPubkey: receiverPubkey,
      content: jsonEncode({'__type': 'delete', 'targetId': targetId}),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    if (_shouldUseOnline()) await _trySendServer(wire);
    if (_shouldUseOffline()) await _trySendBitChat(wire);
  }

  /// Delete just from this device.
  Future<void> deleteMessageForMe(String messageId) async {
    await _dbService.deleteMessage(messageId);
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
      );
    } catch (_) {
      return false;
    }
  }

  /// A stored group message row: encrypted_content is a plaintext JSON
  /// wrapper (label metadata only) whose 'ct' field is the group-key
  /// encrypted body. Forward it to GroupService instead of the DM path.
  Future<void> _routePendingGroupRow(Map<String, dynamic> raw) async {
    final wrapper =
        jsonDecode(raw['encrypted_content'] as String) as Map<String, dynamic>;
    wrapper['timestamp'] ??= raw['timestamp'];
    await onGroupMessage?.call(wrapper);
  }

  /// Fetch messages delivered via server while we were offline or in background.
  Future<void> _fetchOnlineMessages() async {
    try {
      final messages = await ServerService().fetchOnlineMessages();
      for (final raw in messages) {
        try {
          if ((raw['message_type'] as String?) == 'group_dm') {
            await _routePendingGroupRow(raw);
            ServerService().sendReceipt(raw['message_id'] as String, 'delivered');
            continue;
          }
          final msg = Message(
            id:             raw['message_id'] as String,
            senderPubkey:   raw['sender_pubkey'] as String,
            receiverPubkey: raw['receiver_pubkey'] as String,
            content:        raw['encrypted_content'] as String,
            timestamp:      raw['timestamp'] as int,
            type:           raw['message_type'] as String? ?? 'dm',
            senderName:     raw['sender_name'] as String? ?? '',
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
  /// Uses updateMessageStatusIfHigher so a server 'sent' can never downgrade
  /// a message that's already at 'delivered' or 'read' locally.
  Future<void> _syncMessageStatuses() async {
    try {
      final statuses = await ServerService().fetchMessageStatuses();
      for (final s in statuses) {
        final id     = s['message_id'] as String?;
        final status = s['status'] as String?;
        if (id != null && status != null) {
          await _dbService.updateMessageStatusIfHigher(id, status);
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
    // Don't encrypt receipts, status updates, or ephemeral types.
    if (message.type == 'delivery_receipt' ||
        message.type == 'read_receipt' ||
        message.type == 'status_update' ||
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
    // BLE delivery receipts are unreliable (sender may no longer be in range),
    // so only WebSocket receipts update tick status. The WS handler intercepts
    // delivery_receipt before calling _onMessageReceived, so anything reaching
    // here with that type came via BLE — drop it.
    if (message.type == 'delivery_receipt') return;

    // ── Step 3: Decrypt before ALL other type-specific handling ───────────────
    // Read receipts, group invites, and call signals all need plaintext content.
    final decrypted = message.meshEncrypted ? await _decryptFromMesh(message) : message;

    // ── Step 4: BLE image — decode base64, save to disk, store local path ───────
    // Must happen before the JSON parse because base64img: content is not JSON.
    // receiverPubkey guard is critical: BLE is broadcast, every device nearby
    // receives all chunks — only the intended recipient should save the file.
    if (decrypted.type == 'image' && decrypted.content.startsWith('base64img:')) {
      if (decrypted.receiverPubkey == _keyManager.publicKey) {
        await _handleBleReceivedImage(decrypted);
      }
      return;
    }

    // ── Step 5: JSON-wrapped sub-types (read receipts, invites, call signals) ─
    try {
      final parsed = jsonDecode(decrypted.content);
      if (parsed is Map) {
        if (parsed['type'] == 'read_receipt') {
          // Only server-delivered read receipts update tick status.
          // BLE-originated messages always have transport == 'bitchat'; drop those
          // so blue ticks only appear when the server confirms the read.
          if (message.transport != 'bitchat') {
            final originalMessageId = parsed['originalMessageId'] as String?;
            if (originalMessageId != null && originalMessageId.isNotEmpty) {
              await _onReadReceipt(originalMessageId, decrypted.senderPubkey);
            }
          }
          return;
        }
        if (parsed['__type'] == 'group_invite') {
          // New groups system: full invite payload with the group key.
          onGroupInviteData?.call(Map<String, dynamic>.from(parsed));
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

    // ── Step 5b: v2 wrapped payloads (reply metadata, reactions, deletes) ────
    var toStore = decrypted;
    try {
      final parsed = jsonDecode(decrypted.content);
      if (parsed is Map) {
        switch (parsed['__type']) {
          case 'text_v2':
            toStore = Message(
              id: decrypted.id,
              senderPubkey: decrypted.senderPubkey,
              receiverPubkey: decrypted.receiverPubkey,
              content: parsed['body'] as String? ?? '',
              type: 'text',
              timestamp: decrypted.timestamp,
              status: decrypted.status,
              transport: decrypted.transport,
              senderName: decrypted.senderName,
              replyToId: parsed['replyToId'] as String?,
              replySnippet: parsed['replySnippet'] as String?,
            );
          case 'voice_v2':
            toStore = Message(
              id: decrypted.id,
              senderPubkey: decrypted.senderPubkey,
              receiverPubkey: decrypted.receiverPubkey,
              content: parsed['url'] as String? ?? '',
              type: 'voice_note',
              timestamp: decrypted.timestamp,
              status: decrypted.status,
              transport: decrypted.transport,
              senderName: decrypted.senderName,
              // duration in seconds rides in replySnippet — not worth a
              // dedicated column/migration for one integer.
              replySnippet: (parsed['secs'] as num?)?.toString(),
            );
          case 'reaction':
            final targetId = parsed['targetId'] as String? ?? '';
            final emoji = parsed['emoji'] as String? ?? '';
            if (targetId.isEmpty || emoji.isEmpty) return;
            if (await _dbService.hasSeenMessage(decrypted.id)) return;
            final reactionRow = Message(
              id: decrypted.id,
              senderPubkey: decrypted.senderPubkey,
              receiverPubkey: decrypted.receiverPubkey,
              content: emoji,
              type: 'reaction',
              timestamp: decrypted.timestamp,
              status: 'read',
              transport: decrypted.transport,
              replyToId: targetId,
            );
            await _dbService.insertMessage(reactionRow);
            _messageController.add(reactionRow);
            return;
          case 'delete':
            final targetId = parsed['targetId'] as String? ?? '';
            if (targetId.isEmpty) return;
            await _dbService.updateMessageContent(targetId, '🚫 Message deleted');
            _messageController.add(Message(
              id: targetId,
              senderPubkey: decrypted.senderPubkey,
              receiverPubkey: '',
              content: '',
              type: 'status_update',
              timestamp: decrypted.timestamp,
              status: 'read',
            ));
            return;
        }
      }
    } catch (_) {}
    final storedMessage = toStore;

    // ── Step 6: Regular text / image (URL) / voice_note messages ────────────
    // In-memory guard prevents duplicate emit when Nostr + BLE deliver
    // the same message concurrently before either DB write commits.
    if (_processingIds.contains(storedMessage.id)) return;
    _processingIds.add(storedMessage.id);

    final seen = await _dbService.hasSeenMessage(storedMessage.id);
    if (seen) return;

    await _dbService.insertMessage(storedMessage);
    _messageController.add(storedMessage);

    // If this message carries the sender's display name and our DB entry for them
    // has no name yet, persist it now so the chats list and chat header show it
    // immediately without waiting for a server profile fetch.
    if (decrypted.senderName?.isNotEmpty == true) {
      await _dbService.updateContactNameIfEmpty(decrypted.senderPubkey, decrypted.senderName!);
    }

    // Do NOT auto-add sender to contacts — user must do this explicitly.
    // If sender has no name/photo yet and we have internet, silently fetch
    // their profile from server so they show with a name instead of a raw pubkey.
    _resolveUnknownSender(decrypted.senderPubkey);

  }

  /// Decode a BLE-received image (base64img: prefix), save bytes to disk, and
  /// store the message with a local file path so the bubble can render it.
  Future<void> _handleBleReceivedImage(Message message) async {
    // In-memory dedup: guards against the race where the same chunks arrive
    // twice (e.g. via two connected peers relaying the same transfer).
    if (_processingIds.contains(message.id)) return;
    _processingIds.add(message.id);

    // DB dedup: handles app-restart scenarios where the message already landed
    final seen = await _dbService.hasSeenMessage(message.id);
    if (seen) return;

    try {
      final b64 = message.content.substring(10); // strip 'base64img:'

      // Validate that the string is non-empty before attempting to decode —
      // a corrupt/truncated chunk assembly would otherwise throw FormatException
      if (b64.isEmpty) {
        _processingIds.remove(message.id); // allow retry if more chunks arrive
        return;
      }

      final bytes = base64Decode(b64); // throws FormatException on bad base64

      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/img_ble_${message.id}.jpg';
      await File(path).writeAsBytes(bytes, flush: true);

      final stored = message.copyWith(content: 'local:$path', meshEncrypted: false);
      await _dbService.insertMessage(stored);
      _messageController.add(stored);
      if (stored.senderName?.isNotEmpty == true) {
        await _dbService.updateContactNameIfEmpty(stored.senderPubkey, stored.senderName!);
      }
      _resolveUnknownSender(stored.senderPubkey);
    } catch (_) {
      // Corrupt base64, disk full, or IO error — remove from processing set so
      // a clean re-delivery (if sender retransmits) can be processed correctly.
      _processingIds.remove(message.id);
    }
  }

  Future<void> _onDeliveryReceipt(Map<String, String> receipt) async {
    final messageId = receipt['messageId'];
    if (messageId == null) return;

    // Use updateMessageStatusIfHigher — a late delivery receipt must not
    // downgrade a message that's already at 'read'.
    await _dbService.updateMessageStatusIfHigher(messageId, 'delivered');

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
      // Image messages with a local file path need special retry — re-read bytes
      // and re-upload/re-chunk rather than sending the raw path string.
      // Messages with http:// content (upload succeeded, WebSocket/REST failed)
      // fall through to the normal _trySendServer path below.
      if (message.type == 'image' && message.content.startsWith('local:')) {
        await _retryPendingImage(message);
        continue;
      }

      bool sent = false;

      if (_shouldUseOnline()) {
        if (await _trySendServer(message)) sent = true;
      }

      if (_shouldUseOffline()) {
        if (await _trySendBitChat(message)) sent = true;
      }

      if (sent) {
        await _dbService.updateMessageStatus(message.id, 'sent');
        _messageController.add(Message(
          id: message.id,
          senderPubkey: message.senderPubkey,
          receiverPubkey: message.receiverPubkey,
          content: '',
          type: 'status_update',
          timestamp: message.timestamp,
          status: 'sent',
        ));
      } else if (_shouldUseOnline() || _shouldUseOffline()) {
        // Has connectivity but still failing — escalate to 'failed' after 2 minutes.
        // Images are excluded: a large image pending BLE-only should wait for internet
        // rather than being marked failed after 2 minutes.
        final isImageWithLocalPath = message.type == 'image' && message.content.startsWith('local:');
        if (!isImageWithLocalPath) {
          final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final ageSeconds = nowSeconds - message.timestamp;
          if (ageSeconds >= 120 && message.status == 'pending') {
            await _dbService.updateMessageStatus(message.id, 'failed');
            _messageController.add(Message(
              id: message.id,
              senderPubkey: message.senderPubkey,
              receiverPubkey: message.receiverPubkey,
              content: '',
              type: 'status_update',
              timestamp: message.timestamp,
              status: 'failed',
            ));
          }
        }
      }
    }
  }

  Future<void> _retryPendingImage(Message message) async {
    final localPath = message.content.substring('local:'.length);
    final file = File(localPath);

    if (!await file.exists()) {
      await _dbService.updateMessageStatus(message.id, 'failed');
      _messageController.add(Message(
        id: message.id,
        senderPubkey: message.senderPubkey,
        receiverPubkey: message.receiverPubkey,
        content: '',
        type: 'status_update',
        timestamp: message.timestamp,
        status: 'failed',
      ));
      return;
    }

    final canOnline = _hasInternet &&
        ServerService().isAuthenticated &&
        _keyManager.privateKey != null;
    final canBle = _shouldUseOffline();

    if (!canOnline && !canBle) return; // still no path, keep pending

    if (canOnline) {
      await _sendImageOnline(
          file, message.receiverPubkey, message.id, message.timestamp, message);
    } else {
      // BLE only — skip if too large, keep pending until internet is available
      final sizeBytes = await file.length();
      if (sizeBytes > 150 * 1024) return;
      await _sendImageViaBle(
          file, message.receiverPubkey, message.id, message.timestamp, message);
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
    } else if (!sent && _shouldUseOffline()) {
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
    _bitchatSub?.cancel();
    _nearbySub?.cancel();
    _connectivitySub?.cancel();
    _meshRelayServerSub?.cancel();
    _deliveryReceiptSub?.cancel();
    _retryTimer?.cancel();
    _bitchatService.dispose();
    _messageController.close();
  }
}
