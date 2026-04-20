import 'dart:async';
import 'dart:convert';

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
  Future<void> handleWebSocketPayload(Map<String, dynamic> payload) async {
    final type = payload['type'] as String? ?? '';

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
    _deliveryReceiptSub = _bitchatService.deliveryReceiptStream.listen(_onDeliveryReceipt);

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

    // Try both transports independently — if sender has internet AND receiver is
    // nearby without internet, BLE must still fire even though server succeeded.
    // The receiver's dedup set (BoundedSet) prevents showing the message twice
    // if both paths happen to reach them.
    bool sent = false;

    if (_shouldUseOnline()) {
      if (await _trySendServer(message)) sent = true;
    }
    if (_shouldUseOffline()) {
      if (await _trySendBitChat(message)) sent = true;
    }

    if (sent) {
      await _dbService.updateMessageStatus(message.id, 'sent');
    } else {
      await _dbService.updateMessageStatus(message.id, 'failed');
      _messageController.add(message.copyWith(status: 'failed'));
    }

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
    // Read receipts, group invites, and call signals all need plaintext content.
    final decrypted = message.meshEncrypted ? await _decryptFromMesh(message) : message;

    // ── Step 4: JSON-wrapped sub-types (read receipts, invites, call signals) ─
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

    // ── Step 6: Regular text messages ────────────────────────────────────────
    // In-memory guard prevents duplicate emit when Nostr + BLE deliver
    // the same message concurrently before either DB write commits.
    if (_processingIds.contains(decrypted.id)) return;
    _processingIds.add(decrypted.id);

    final seen = await _dbService.hasSeenMessage(decrypted.id);
    if (seen) return;

    await _dbService.insertMessage(decrypted);
    _messageController.add(decrypted);

    // Do NOT auto-add sender to contacts — user must do this explicitly.
    // If sender has no name/photo yet and we have internet, silently fetch
    // their profile from server so they show with a name instead of a raw pubkey.
    _resolveUnknownSender(decrypted.senderPubkey);

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
