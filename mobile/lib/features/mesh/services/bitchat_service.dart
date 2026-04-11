import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:nearby_connections/nearby_connections.dart';

import 'package:bitchat_messenger/core/bounded_set.dart';
import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/image_sharing_service.dart';
import 'package:bitchat_messenger/core/voice_note_service.dart';
import 'package:bitchat_messenger/features/mesh/services/ble_service.dart';
import 'package:bitchat_messenger/features/mesh/services/multipeer_channel.dart';

class BitChatService {
  // nearby_connections is Android-only; null on iOS
  final Nearby? _nearby = Platform.isAndroid ? Nearby() : null;
  // MultipeerConnectivity is iOS-only; null on Android
  final MultipeerChannel? _multipeer = Platform.isIOS ? MultipeerChannel() : null;
  final BleService _bleService = BleService();
  final DatabaseService _dbService;
  final _messageController = StreamController<Message>.broadcast();
  final _relayToNostrController = StreamController<Message>.broadcast();
  final _deliveryReceiptController = StreamController<Map<String, String>>.broadcast();
  final _nearbyChangedController = StreamController<Set<String>>.broadcast();
  // Emits {senderPubkey} when a typing indicator arrives addressed to us.
  final _typingController = StreamController<Map<String, dynamic>>.broadcast();
  final _seenMessageIds = BoundedSet<String>(5000);
  final _seenReceiptIds = BoundedSet<String>(2000);
  final Map<String, String> _connectedEndpoints = {}; // endpointId -> pubkey (Android/Nearby)
  final Set<String> _multipeerPubkeys = {};            // connected pubkeys via MultipeerConnectivity (iOS)
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _multipeerActive = false;
  bool _bleActive = false;
  String? _myPubkey;
  String? _myUsername;
  String? _myShortId;
  Timer? _restartTimer;
  Timer? _cleanupTimer;
  StreamSubscription? _bleMessageSub;
  StreamSubscription? _bleNearbySub;
  StreamSubscription? _multipeerSub;

  BitChatService({required DatabaseService dbService}) : _dbService = dbService;

  Stream<Message> get messageStream => _messageController.stream;
  Stream<Message> get relayToNostrStream => _relayToNostrController.stream;
  Stream<Map<String, String>> get deliveryReceiptStream => _deliveryReceiptController.stream;
  Stream<Set<String>> get nearbyChangedStream => _nearbyChangedController.stream;
  Stream<Map<String, dynamic>> get typingStream => _typingController.stream;
  bool get isActive => _isAdvertising || _isDiscovering || _bleActive;

  Set<String> get nearbyPubkeys {
    final all = <String>{..._connectedEndpoints.values};
    if (_multipeerActive) all.addAll(_multipeerPubkeys);
    if (_bleActive) all.addAll(_bleService.nearbyPubkeys);
    return all;
  }

  // True if any BLE connection exists in either direction — broader than nearbyPubkeys
  // which only counts devices whose pubkey we've received via handshake
  bool get hasAnyBleConnection => _bleActive && _bleService.hasAnyConnection;

  // True if a Wi-Fi P2P mesh session has at least one connected peer (fast path).
  bool get hasWifiMesh =>
      _connectedEndpoints.isNotEmpty ||
      (_multipeerActive && _multipeerPubkeys.isNotEmpty);

  // True if media (voice notes / images) can be sent — Wi-Fi P2P or BLE fallback.
  bool get canSendMedia =>
      hasWifiMesh || (_bleActive && _bleService.hasAnyConnection);

  // Get display names discovered via BLE handshake
  Map<String, String> get nearbyDeviceNames => _bleService.deviceNames;
  // Get profile picture URLs discovered via BLE handshake
  Map<String, String> get nearbyDeviceProfilePictures => _bleService.deviceProfilePictures;

  String? _myProfilePictureUrl;

  Future<void> start(String myPubkey, {String? username, String? shortId, String? profilePictureUrl}) async {
    _myPubkey = myPubkey;
    _myUsername = username;
    _myShortId = shortId;
    _myProfilePictureUrl = profilePictureUrl;

    // Try nearby_connections first (needs Wi-Fi + BT + Location)
    await _startMesh();

    // Always start BLE as fallback/additional transport
    await _startBle();

    // Periodically check and restart if needed
    _restartTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkAndRestart();
    });

    // Clean up expired relay messages every 10 minutes
    _cleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _dbService.cleanupExpiredRelayMessages();
      // Prune pending connections older than 30 seconds (timed out)
      final now = DateTime.now();
      _pendingConnectionTimes.removeWhere((endpointId, time) {
        if (now.difference(time).inSeconds > 30) {
          _pendingConnections.remove(endpointId);
          return true;
        }
        return false;
      });
    });

    // Initial cleanup
    _dbService.cleanupExpiredRelayMessages();
  }

  Future<void> _startBle() async {
    if (_myPubkey == null) return;

    // Cancel previous subscriptions to avoid listener leaks on restart
    await _bleMessageSub?.cancel();
    await _bleNearbySub?.cancel();

    // Listen for BLE messages
    _bleMessageSub = _bleService.messageStream.listen((message) {
      // Typing indicators are ephemeral — route to typingStream, never to messageStream
      if (message.type == AppConstants.typeTypingIndicator) {
        if (message.receiverPubkey == _myPubkey) {
          _typingController.add({'senderPubkey': message.senderPubkey});
        }
        return;
      }
      if (_seenMessageIds.contains(message.id)) return;
      _seenMessageIds.add(message.id);
      _messageController.add(message);
    });

    // Listen for BLE nearby changes
    _bleNearbySub = _bleService.nearbyChangedStream.listen((_) {
      _notifyNearbyChanged();
      _deliverStoredMessages();
    });

    _bleActive = await _bleService.start(_myPubkey!, username: _myUsername, shortId: _myShortId, profilePictureUrl: _myProfilePictureUrl);
  }

  Future<void> _startMesh() async {
    if (_nearby != null) {
      // Android: Nearby Connections
      if (!_isAdvertising) await _startAdvertising();
      if (!_isDiscovering) await _startDiscovery();
    } else if (_multipeer != null && _myPubkey != null) {
      // iOS: MultipeerConnectivity
      await _startMultipeer();
    }
  }

  Future<void> _startMultipeer() async {
    if (_myPubkey == null || _multipeer == null) return;
    await _multipeerSub?.cancel();

    _multipeerActive = await _multipeer.start(_myPubkey!);
    if (!_multipeerActive) return;

    _multipeerSub = _multipeer.eventStream.listen((event) async {
      final type = event['type'] as String?;
      switch (type) {
        case 'received':
          final dataList = event['data'];
          if (dataList is List) {
            final bytes = Uint8List.fromList(dataList.cast<int>());
            await _handleMultipeerData(bytes);
          }
        case 'connected':
          final peerId = event['peerId'] as String?;
          if (peerId != null) {
            _multipeerPubkeys.add(peerId);
            _notifyNearbyChanged();
            _deliverStoredMessages();
          }
        case 'disconnected':
          final peerId = event['peerId'] as String?;
          if (peerId != null) {
            _multipeerPubkeys.remove(peerId);
            _notifyNearbyChanged();
          }
      }
    });
  }

  Future<void> _checkAndRestart() async {
    if (_myPubkey == null) return;

    if (_nearby != null && (!_isAdvertising || !_isDiscovering)) {
      await _startMesh();
    } else if (_multipeer != null && !_multipeerActive) {
      await _startMultipeer();
    }

    if (!_bleActive) {
      _bleActive = await _bleService.start(_myPubkey!, username: _myUsername, shortId: _myShortId, profilePictureUrl: _myProfilePictureUrl);
    }
  }

  Future<void> _startAdvertising() async {
    if (_myPubkey == null || _nearby == null) return;
    try {
      _isAdvertising = await _nearby.startAdvertising(
        _myPubkey!,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: 'com.bitchat.mesh',
      );
    } catch (e) {
      _isAdvertising = false;
    }
  }

  Future<void> _startDiscovery() async {
    if (_myPubkey == null || _nearby == null) return;
    try {
      _isDiscovering = await _nearby.startDiscovery(
        _myPubkey!,
        Strategy.P2P_CLUSTER,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: 'com.bitchat.mesh',
      );
    } catch (e) {
      _isDiscovering = false;
    }
  }

  void _notifyNearbyChanged() {
    _nearbyChangedController.add(nearbyPubkeys);
  }

  void _onEndpointFound(String endpointId, String endpointName, String serviceId) {
    if (_myPubkey == null) return;
    _nearby?.requestConnection(
      _myPubkey!,
      endpointId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  void _onEndpointLost(String? endpointId) {
    if (endpointId != null) {
      _connectedEndpoints.remove(endpointId);
      _notifyNearbyChanged();
    }
  }

  // Track pending connection names so we can register them on CONNECTED
  final Map<String, String> _pendingConnections = {}; // endpointId -> pubkey
  final Map<String, DateTime> _pendingConnectionTimes = {}; // endpointId -> when added

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    _nearby?.acceptConnection(
      endpointId,
      onPayLoadRecieved: (endpointId, payload) {
        _handlePayload(endpointId, payload);
      },
    );
    // Don't register as connected yet — wait for _onConnectionResult
    _pendingConnections[endpointId] = info.endpointName;
    _pendingConnectionTimes[endpointId] = DateTime.now();
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      final pubkey = _pendingConnections.remove(endpointId);
      _pendingConnectionTimes.remove(endpointId);
      if (pubkey != null) {
        _connectedEndpoints[endpointId] = pubkey;
        _notifyNearbyChanged();
        _deliverStoredMessages();
      }
    } else {
      _pendingConnections.remove(endpointId);
      _pendingConnectionTimes.remove(endpointId);
      _connectedEndpoints.remove(endpointId);
      _notifyNearbyChanged();
    }
  }

  void _onDisconnected(String endpointId) {
    _connectedEndpoints.remove(endpointId);
    _notifyNearbyChanged();
  }

  // Injected by MessageService so BitChatService can save received audio/image files
  VoiceNoteService? voiceNoteService;
  ImageSharingService? imageSharingService;

  Future<void> _handlePayload(String endpointId, Payload payload) async {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;

    try {
      final data = jsonDecode(utf8.decode(payload.bytes!)) as Map<String, dynamic>;
      final message = Message.fromMap(data);

      // Channel messages — pass through to ChannelService, relay via mesh
      if (message.receiverPubkey.startsWith('channel:')) {
        if (_seenMessageIds.contains(message.id)) return;
        _seenMessageIds.add(message.id);
        _messageController.add(message.copyWith(transport: 'bitchat'));
        if (message.ttl > 1) {
          await _relayMessage(message.copyWith(ttl: message.ttl - 1));
        }
        return;
      }

      // Handle delivery receipts
      if (message.type == 'delivery_receipt') {
        await _handleReceipt(message);
        return;
      }

      // Typing indicators: ephemeral, never stored or relayed
      if (message.type == AppConstants.typeTypingIndicator) {
        if (message.receiverPubkey == _myPubkey) {
          _typingController.add({'senderPubkey': message.senderPubkey});
        }
        return;
      }

      if (_seenMessageIds.contains(message.id)) return;
      _seenMessageIds.add(message.id);

      if (message.receiverPubkey == _myPubkey) {
        // Voice note — decode audio bytes and save to local file
        if (message.type == 'voice_note') {
          final base64Data = data['voiceData'] as String?;
          if (base64Data != null && voiceNoteService != null) {
            final localPath = await voiceNoteService!.decodeFromBase64(message.id, base64Data);
            if (localPath != null) {
              final stored = message.copyWith(
                content: localPath,
                status: 'delivered',
                transport: 'bitchat',
              );
              _messageController.add(stored);
              await _sendDeliveryReceipt(stored);
              return;
            }
          }
          return; // drop if no audio data
        }

        // Image — decode base64 bytes and save to local file
        if (message.type == 'image') {
          final base64Data = data['imageData'] as String?;
          if (base64Data != null && imageSharingService != null) {
            final localPath = await imageSharingService!.decodeFromBase64(message.id, base64Data);
            if (localPath != null) {
              final stored = message.copyWith(
                content: localPath,
                status: 'delivered',
                transport: 'bitchat',
              );
              _messageController.add(stored);
              await _sendDeliveryReceipt(stored);
              return;
            }
          }
          return; // drop if no image data
        }

        _messageController.add(message.copyWith(
          status: 'delivered',
          transport: 'bitchat',
        ));
        // Reactions are ephemeral acknowledgements — no delivery receipt needed
        if (message.type != AppConstants.typeReaction) {
          await _sendDeliveryReceipt(message);
        }
      } else {
        // Large payloads: relay in-memory only (never store in DB — too large)
        if (message.type == 'voice_note' || message.type == 'image') {
          if (message.ttl > 1) {
            final relayMap = data..['ttl'] = message.ttl - 1;
            final bytes = Uint8List.fromList(utf8.encode(jsonEncode(relayMap)));
            final endpoints = _connectedEndpoints.keys.toList();
            for (final endpointId in endpoints) {
              try { await _nearby?.sendBytesPayload(endpointId, bytes); } catch (_) {}
            }
            if (_multipeerActive) {
              try { await _multipeer?.send(bytes); } catch (_) {}
            }
          }
        } else {
          await _storeAndForward(message);
        }
      }
    } catch (e) {
      // Skip malformed payloads
    }
  }

  /// iOS MultipeerConnectivity equivalent of _handlePayload.
  /// Same logic, but relays via _multipeer.send() instead of Nearby Connections.
  Future<void> _handleMultipeerData(Uint8List bytes) async {
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final message = Message.fromMap(data);

      if (message.receiverPubkey.startsWith('channel:')) {
        if (_seenMessageIds.contains(message.id)) return;
        _seenMessageIds.add(message.id);
        _messageController.add(message.copyWith(transport: 'bitchat'));
        if (message.ttl > 1) {
          await _relayMessage(message.copyWith(ttl: message.ttl - 1));
        }
        return;
      }

      if (message.type == 'delivery_receipt') {
        await _handleReceipt(message);
        return;
      }

      if (message.type == AppConstants.typeTypingIndicator) {
        if (message.receiverPubkey == _myPubkey) {
          _typingController.add({'senderPubkey': message.senderPubkey});
        }
        return;
      }

      if (_seenMessageIds.contains(message.id)) return;
      _seenMessageIds.add(message.id);

      if (message.receiverPubkey == _myPubkey) {
        if (message.type == 'voice_note') {
          final base64Data = data['voiceData'] as String?;
          if (base64Data != null && voiceNoteService != null) {
            final localPath = await voiceNoteService!.decodeFromBase64(message.id, base64Data);
            if (localPath != null) {
              final stored = message.copyWith(
                content: localPath,
                status: 'delivered',
                transport: 'bitchat',
              );
              _messageController.add(stored);
              await _sendDeliveryReceipt(stored);
              return;
            }
          }
          return;
        }

        if (message.type == 'image') {
          final base64Data = data['imageData'] as String?;
          if (base64Data != null && imageSharingService != null) {
            final localPath = await imageSharingService!.decodeFromBase64(message.id, base64Data);
            if (localPath != null) {
              final stored = message.copyWith(
                content: localPath,
                status: 'delivered',
                transport: 'bitchat',
              );
              _messageController.add(stored);
              await _sendDeliveryReceipt(stored);
              return;
            }
          }
          return;
        }

        _messageController.add(message.copyWith(status: 'delivered', transport: 'bitchat'));
        if (message.type != AppConstants.typeReaction) {
          await _sendDeliveryReceipt(message);
        }
      } else {
        if (message.type == 'voice_note' || message.type == 'image') {
          if (message.ttl > 1) {
            final relayMap = data..['ttl'] = message.ttl - 1;
            final relayBytes = Uint8List.fromList(utf8.encode(jsonEncode(relayMap)));
            final endpoints = _connectedEndpoints.keys.toList();
            for (final endpointId in endpoints) {
              try { await _nearby?.sendBytesPayload(endpointId, relayBytes); } catch (_) {}
            }
            try { await _multipeer?.send(relayBytes); } catch (_) {}
          }
        } else {
          await _storeAndForward(message);
        }
      }
    } catch (_) {}
  }

  // Handle an incoming delivery receipt
  Future<void> _handleReceipt(Message receipt) async {
    final receiptId = receipt.id;
    if (_seenReceiptIds.contains(receiptId)) return;
    _seenReceiptIds.add(receiptId);

    final originalMessageId = receipt.content; // the message ID being acknowledged

    // Clean up relay store — we no longer need to hold this message
    await _dbService.deleteRelayMessage(originalMessageId);

    // Notify MessageService (it updates sender's status to 'delivered')
    _deliveryReceiptController.add({
      'messageId': originalMessageId,
      'receiverPubkey': receipt.senderPubkey, // B sent the receipt
    });

    // Relay the receipt onward through mesh
    await _relayMessage(receipt);

    // Also try forwarding receipt via Nostr
    _relayToNostrController.add(receipt);
  }

  // Create and broadcast a delivery receipt for a received message
  Future<void> _sendDeliveryReceipt(Message originalMessage) async {
    if (_myPubkey == null) return;
    final receipt = Message(
      id: '${originalMessage.id}_receipt',
      senderPubkey: _myPubkey!, // B (receiver) is sending the receipt
      receiverPubkey: originalMessage.senderPubkey, // back to A (sender)
      content: originalMessage.id, // the original message ID
      type: 'delivery_receipt',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      // Fixed TTL of 2 — enough to cross one relay hop back to sender.
      // Must NOT copy originalMessage.ttl which could be 0 (already decremented
      // to last hop) causing the receipt to be dropped before it reaches sender.
      ttl: 2,
      status: 'sent',
      transport: 'bitchat',
    );

    _seenReceiptIds.add(receipt.id);

    // Broadcast receipt via all transports
    await sendMessage(receipt);

    // Also relay via Nostr
    _relayToNostrController.add(receipt);
  }

  // Store-and-forward: save message and try all delivery methods
  Future<void> _storeAndForward(Message message) async {
    // Store in database for later delivery
    final messageData = jsonEncode(message.toMap());
    await _dbService.storeRelayMessage(
      message.id,
      message.receiverPubkey,
      messageData,
    );

    // Forward via mesh if TTL allows (stop at 1 — don't relay with TTL 0)
    if (message.ttl > 1) {
      await _relayMessage(message.copyWith(ttl: message.ttl - 1));
    }

    // Ask MessageService to try Nostr relay (if we have internet)
    _relayToNostrController.add(message);
  }

  // Deliver stored messages to newly appeared nearby devices
  Future<void> _deliverStoredMessages() async {
    final nearby = nearbyPubkeys;
    if (nearby.isEmpty) return;

    for (final pubkey in nearby) {
      final storedMessages = await _dbService.getRelayMessagesFor(pubkey);
      if (storedMessages.isEmpty) continue;

      for (final messageData in storedMessages) {
        try {
          final data = jsonDecode(messageData);
          final message = Message.fromMap(data);

          // Send directly to the target
          final bytes = Uint8List.fromList(utf8.encode(messageData));

          // Via Nearby Connections — only to the endpoint holding this pubkey
          final endpoints = _connectedEndpoints.entries.toList();
          for (final entry in endpoints) {
            if (entry.value == pubkey) {
              try {
                await _nearby?.sendBytesPayload(entry.key, bytes);
              } catch (_) {}
            }
          }

          // Via MultipeerConnectivity (iOS) — broadcast, recipient filters by pubkey
          if (_multipeerActive && _multipeerPubkeys.contains(pubkey)) {
            try { await _multipeer?.send(bytes); } catch (_) {}
          }

          // Via BLE
          if (_bleActive) {
            try {
              await _bleService.sendMessage(message);
            } catch (_) {}
          }
        } catch (_) {}
      }

      // Don't delete here — delivery receipts will clean up confirmed deliveries.
      // Expired messages are cleaned up by the periodic cleanup timer.
    }
  }

  /// Broadcast a typing indicator to [receiverPubkey].
  /// TTL=1 so it only travels one hop — no relay needed.
  /// Not stored in DB or seen-set; each indicator has a unique timestamp ID.
  /// Broadcast a typing indicator to [receiverPubkey].
  /// TTL=1, never stored or relayed. Wi-Fi P2P only — BLE is excluded because
  /// the BLE GATT path delivers to the generic message stream which would show
  /// typing packets as blank messages on devices without Nearby Connections.
  Future<void> sendTypingIndicator(String receiverPubkey) async {
    if (_myPubkey == null) return;
    final msg = Message(
      id: '${_myPubkey!.substring(0, 8)}_ty_${DateTime.now().millisecondsSinceEpoch}',
      senderPubkey: _myPubkey!,
      receiverPubkey: receiverPubkey,
      content: '',
      type: AppConstants.typeTypingIndicator,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ttl: 1,
    );
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(msg.toMap())));

    // Wi-Fi P2P only — fast, direct, and handled correctly on the receiving side
    final endpoints = _connectedEndpoints.keys.toList();
    for (final ep in endpoints) {
      try { await _nearby?.sendBytesPayload(ep, bytes); } catch (_) {}
    }
    if (_multipeerActive) {
      try { await _multipeer?.send(bytes); } catch (_) {}
    }
    // BLE excluded intentionally — see doc comment above
  }

  /// Send a voice note. Tries Wi-Fi P2P (Nearby/MultipeerConnectivity) first for
  /// speed; falls back to BLE chunked transfer if Wi-Fi P2P is unavailable.
  /// Returns true if sent to at least one peer.
  Future<bool> sendVoiceNote({
    required Message message,
    required String filePath,
    required VoiceNoteService voiceNoteService,
  }) async {
    final hasNearby = _connectedEndpoints.isNotEmpty;
    final hasMultipeer = _multipeerActive && _multipeerPubkeys.isNotEmpty;
    final hasBle = _bleActive && _bleService.hasAnyConnection;
    if (!hasNearby && !hasMultipeer && !hasBle) return false;

    final base64Data = await voiceNoteService.encodeToBase64(filePath);
    if (base64Data == null) return false;

    _seenMessageIds.add(message.id);
    bool sent = false;

    // Prefer Wi-Fi P2P — fast, no chunking needed
    if (hasNearby || hasMultipeer) {
      final transitMap = message.toMap()..['voiceData'] = base64Data;
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(transitMap)));

      final endpoints = _connectedEndpoints.keys.toList();
      for (final endpointId in endpoints) {
        try { await _nearby?.sendBytesPayload(endpointId, bytes); sent = true; } catch (_) {}
      }
      if (_multipeerActive) {
        try { if (await _multipeer?.send(bytes) == true) sent = true; } catch (_) {}
      }
    }

    // Fallback: BLE chunked transfer (slower but works without Wi-Fi P2P)
    if (!sent && hasBle) {
      sent = await _bleService.sendMediaChunked(
        message: message,
        mediaType: 'voice_note',
        base64Data: base64Data,
      );
    }

    return sent;
  }

  /// Send an image. Tries Wi-Fi P2P first; falls back to BLE chunked transfer.
  /// Returns true if sent to at least one peer.
  Future<bool> sendImage({
    required Message message,
    required String filePath,
    required ImageSharingService imageSharingService,
  }) async {
    final hasNearby = _connectedEndpoints.isNotEmpty;
    final hasMultipeer = _multipeerActive && _multipeerPubkeys.isNotEmpty;
    final hasBle = _bleActive && _bleService.hasAnyConnection;
    if (!hasNearby && !hasMultipeer && !hasBle) return false;

    // Wi-Fi P2P path — full quality up to 1MB
    final base64Data = await imageSharingService.encodeToBase64(filePath);
    if (base64Data == null) return false;

    _seenMessageIds.add(message.id);
    bool sent = false;

    // Prefer Wi-Fi P2P
    if (hasNearby || hasMultipeer) {
      final transitMap = message.toMap()..['imageData'] = base64Data;
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(transitMap)));

      final endpoints = _connectedEndpoints.keys.toList();
      for (final endpointId in endpoints) {
        try { await _nearby?.sendBytesPayload(endpointId, bytes); sent = true; } catch (_) {}
      }
      if (_multipeerActive) {
        try { if (await _multipeer?.send(bytes) == true) sent = true; } catch (_) {}
      }
    }

    // Fallback: BLE chunked transfer — compress to 50KB max for reliable multi-hop relay
    if (!sent && hasBle) {
      final bleBase64 = await imageSharingService.encodeToBase64(filePath, forBle: true);
      if (bleBase64 == null) return false;
      sent = await _bleService.sendMediaChunked(
        message: message,
        mediaType: 'image',
        base64Data: bleBase64,
      );
    }

    return sent;
  }

  Future<void> sendMessage(Message message) async {
    _seenMessageIds.add(message.id);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message.toMap())));

    // Android: Nearby Connections (snapshot keys to avoid concurrent modification)
    final endpoints = _connectedEndpoints.keys.toList();
    for (final endpointId in endpoints) {
      try {
        await _nearby?.sendBytesPayload(endpointId, bytes);
      } catch (_) {}
    }

    // iOS: MultipeerConnectivity
    if (_multipeerActive) {
      try { await _multipeer?.send(bytes); } catch (_) {}
    }

    // BLE (both platforms)
    if (_bleActive) {
      try {
        await _bleService.sendMessage(message);
      } catch (_) {}
    }
  }

  Future<void> _relayMessage(Message message) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message.toMap())));
    final endpoints = _connectedEndpoints.keys.toList();
    for (final endpointId in endpoints) {
      try {
        await _nearby?.sendBytesPayload(endpointId, bytes);
      } catch (_) {}
    }

    if (_multipeerActive) {
      try { await _multipeer?.send(bytes); } catch (_) {}
    }

    if (_bleActive) {
      try {
        await _bleService.sendMessage(message);
      } catch (_) {}
    }
  }

  /// Called when the app returns to foreground (iOS lifecycle resume).
  /// Restarts BLE scanning without resetting the mesh layer.
  /// Update profile picture URL live — next handshake will include the new URL.
  Future<void> updateProfilePictureUrl(String? url) async {
    _myProfilePictureUrl = url;
    _bleService.updateProfilePictureUrl(url);
  }

  Future<void> restartBle() async {
    if (_myPubkey == null) return;
    _bleActive = false;
    await _bleService.stop();
    await _startBle();
  }

  Future<void> stop() async {
    _restartTimer?.cancel();
    _cleanupTimer?.cancel();
    _isAdvertising = false;
    _isDiscovering = false;
    _bleActive = false;
    _multipeerActive = false;
    _connectedEndpoints.clear();
    _multipeerPubkeys.clear();
    try { await _nearby?.stopAdvertising(); } catch (_) {}
    try { await _nearby?.stopDiscovery(); } catch (_) {}
    try { await _nearby?.stopAllEndpoints(); } catch (_) {}
    try { await _multipeer?.stop(); } catch (_) {}
    await _bleService.stop();
    _notifyNearbyChanged();
  }

  Future<void> dispose() async {
    await stop();
    _bleMessageSub?.cancel();
    _bleNearbySub?.cancel();
    _multipeerSub?.cancel();
    _messageController.close();
    _relayToNostrController.close();
    _deliveryReceiptController.close();
    _nearbyChangedController.close();
    _typingController.close();
    _bleService.dispose();
  }
}
