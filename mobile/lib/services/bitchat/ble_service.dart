import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../core/bounded_set.dart';
import '../../models/message.dart';

class BleService {
  static const _methodChannel = MethodChannel('com.bitchat/ble_gatt');
  static const _eventChannel = EventChannel('com.bitchat/ble_gatt_events');
  static const _serviceUuid    = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const _writeCharUuid  = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const _notifyCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  final _messageController = StreamController<Message>.broadcast();
  final _nearbyChangedController = StreamController<Set<String>>.broadcast();
  final _seenMessageIds = BoundedSet<String>(5000);

  // BLE address -> pubkey mapping
  final Map<String, String> _connectedDevices = {};
  // address -> BluetoothDevice (for sending)
  final Map<String, BluetoothDevice> _pubkeyToDevice = {};
  // address -> cached write characteristic
  final Map<String, BluetoothCharacteristic> _writeCharCache = {};
  // pubkey -> display name (from handshake)
  final Map<String, String> _deviceNames = {};
  // address -> stream subscriptions (so we can cancel on disconnect)
  final Map<String, List<StreamSubscription>> _deviceSubs = {};
  // tracks addresses we already sent OUR handshake to (prevents infinite ping-pong)
  final Set<String> _sentHandshakeTo = {};
  // tracks addresses currently being connected to (prevents concurrent duplicate attempts)
  final Set<String> _connectingDevices = {};

  // Chunk reassembly buffer: originalMessageId → chunkIndex → base64 chunk data
  final Map<String, Map<int, String>> _chunkBuffer = {};
  // Chunk metadata: originalMessageId → {total, mediaType, senderPubkey, receiverPubkey, timestamp, senderName}
  final Map<String, Map<String, dynamic>> _chunkMeta = {};
  // Track when the first chunk of each transfer arrived (for timeout cleanup)
  final Map<String, DateTime> _chunkStartTimes = {};
  Timer? _chunkCleanupTimer;

  StreamSubscription? _eventSub;
  StreamSubscription? _scanSub;
  Timer? _scanTimer;
  bool _isRunning = false;
  String? _myPubkey;
  String? _myUsername;
  String? _myShortId;
  String? _myProfilePictureUrl;
  // pubkey -> short ID received via handshake
  final Map<String, String> _deviceShortIds = {};
  // pubkey -> profile picture URL received via handshake
  final Map<String, String> _deviceProfilePictures = {};

  Stream<Message> get messageStream => _messageController.stream;
  Stream<Set<String>> get nearbyChangedStream => _nearbyChangedController.stream;
  bool get isActive => _isRunning;
  Set<String> get nearbyPubkeys => _connectedDevices.values.toSet();
  Map<String, String> get deviceNames => Map.unmodifiable(_deviceNames);
  // pubkey -> short ID (8-digit) received via BLE handshake
  Map<String, String> get deviceShortIds => Map.unmodifiable(_deviceShortIds);
  // pubkey -> profile picture URL received via BLE handshake
  Map<String, String> get deviceProfilePictures => Map.unmodifiable(_deviceProfilePictures);
  // True if we have any BLE connection in either direction — used to unblock sending
  // even before the bidirectional handshake completes
  bool get hasAnyConnection => _connectedDevices.isNotEmpty || _writeCharCache.isNotEmpty;

  Future<bool> start(String myPubkey, {String? username, String? shortId, String? profilePictureUrl}) async {
    _myPubkey = myPubkey;
    _myUsername = username;
    _myShortId = shortId;
    _myProfilePictureUrl = profilePictureUrl;

    // Start GATT server (native side)
    try {
      final success = await _methodChannel.invokeMethod<bool>('start') ?? false;
      if (!success) return false;
    } catch (e) {
      return false;
    }

    _isRunning = true;

    // Cancel old listeners/timers if start() called again
    _eventSub?.cancel();
    _scanSub?.cancel();
    _scanTimer?.cancel();
    _chunkCleanupTimer?.cancel();

    // Listen for GATT server events (incoming connections + messages)
    _eventSub = _eventChannel.receiveBroadcastStream().listen(_handleGattEvent);

    // Start BLE scanning for other BitChat devices
    _startScanning();

    // Periodic scan restart
    _scanTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _startScanning();
    });

    // Periodic cleanup of stale incomplete chunk transfers
    _chunkCleanupTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _cleanupStaleChunks();
    });

    return true;
  }

  void _startScanning() {
    if (!_isRunning) return;

    // Stop any in-progress scan before starting a new one — required by
    // FlutterBluePlus; calling startScan() while scanning is a no-op on some
    // platforms and throws on others.
    try { FlutterBluePlus.stopScan(); } catch (_) {}

    _scanSub?.cancel();

    try {
      FlutterBluePlus.startScan(
        withServices: [Guid(_serviceUuid)],
        timeout: const Duration(seconds: 15),
      );

      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          _onDeviceDiscovered(result.device);
        }
      });
    } catch (e) {
      // Scan failed — will retry on next timer tick
    }
  }

  Future<void> _onDeviceDiscovered(BluetoothDevice device) async {
    final address = device.remoteId.str;

    // Atomic check-and-add: skip if already connected or connecting
    if (_connectedDevices.containsKey(address)) return;
    if (!_connectingDevices.add(address)) return; // add() returns false if already present

    // Clean up any stale subscriptions from a previous connection attempt
    final oldSubs = _deviceSubs.remove(address);
    if (oldSubs != null) {
      for (final s in oldSubs) {
        s.cancel();
      }
    }

    try {
      // Connect to the device
      await device.connect(license: License.free, autoConnect: false, timeout: const Duration(seconds: 10));

      // Request larger MTU — Android negotiates up to 512 bytes which eliminates
      // fragmentation for almost all text messages. iOS auto-negotiates; this call
      // is silently ignored on iOS.
      try { await device.requestMtu(512); } catch (_) {}

      // Discover services
      final services = await device.discoverServices();

      for (final service in services) {
        if (service.uuid.str.toLowerCase() == _serviceUuid) {
          for (final char in service.characteristics) {
            // Subscribe to notifications from this device
            if (char.uuid.str.toLowerCase() == _notifyCharUuid) {
              await char.setNotifyValue(true);
              final sub = char.onValueReceived.listen((value) {
                _handleIncomingData(Uint8List.fromList(value), address);
              });
              _deviceSubs.putIfAbsent(address, () => []).add(sub);
            }
          }

          // Send our pubkey + username as handshake and cache write characteristic
          for (final char in service.characteristics) {
            if (char.uuid.str.toLowerCase() == _writeCharUuid) {
              _writeCharCache[address] = char;
              _sentHandshakeTo.add(address); // mark before writing to prevent echo loop
              final handshakeData = <String, dynamic>{
                'type': 'handshake',
                'pubkey': _myPubkey,
              };
              if (_myUsername != null && _myUsername!.isNotEmpty) {
                handshakeData['username'] = _myUsername;
              }
              if (_myShortId != null && _myShortId!.isNotEmpty) {
                handshakeData['shortId'] = _myShortId;
              }
              if (_myProfilePictureUrl != null && _myProfilePictureUrl!.isNotEmpty) {
                handshakeData['profilePictureUrl'] = _myProfilePictureUrl;
              }
              final handshake = jsonEncode(handshakeData);
              await char.write(utf8.encode(handshake), withoutResponse: true);
            }
          }

          _pubkeyToDevice[address] = device;
          break;
        }
      }

      // Listen for disconnection and cancel all subs for this device
      final disconnectSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _cleanupDevice(address);
        }
      });
      _deviceSubs.putIfAbsent(address, () => []).add(disconnectSub);
    } catch (e) {
      // Connection failed — clean up any partial state
      _writeCharCache.remove(address);
      _sentHandshakeTo.remove(address);
      final partialSubs = _deviceSubs.remove(address);
      if (partialSubs != null) {
        for (final s in partialSubs) s.cancel();
      }
      try { await device.disconnect(); } catch (_) {}
    } finally {
      _connectingDevices.remove(address);
    }
  }

  void _cleanupDevice(String address) {
    // Cancel all stream subscriptions for this device
    final subs = _deviceSubs.remove(address);
    if (subs != null) {
      for (final sub in subs) {
        sub.cancel();
      }
    }
    final pubkey = _connectedDevices.remove(address);
    _pubkeyToDevice.remove(address);
    _writeCharCache.remove(address);
    _sentHandshakeTo.remove(address);
    if (pubkey != null) {
      _deviceNames.remove(pubkey);
      _deviceShortIds.remove(pubkey);
      _deviceProfilePictures.remove(pubkey);
    }
    _nearbyChangedController.add(nearbyPubkeys);
  }

  void _handleGattEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;

    switch (type) {
      case 'message':
        final data = event['data'] as List?;
        final address = event['address'] as String?;
        if (data != null && address != null) {
          _handleIncomingData(Uint8List.fromList(data.cast<int>()), address);
        }
        break;
      case 'connected':
        // Device connected to our GATT server — wait for handshake
        break;
      case 'disconnected':
        final address = event['address'] as String?;
        if (address != null) {
          _cleanupDevice(address);
        }
        break;
    }
  }

  Future<void> _handleIncomingData(Uint8List data, String address) async {
    try {
      final decoded = jsonDecode(utf8.decode(data));

      // Handle handshake
      if (decoded is Map && decoded['type'] == 'handshake') {
        final pubkey = decoded['pubkey'] as String?;
        if (pubkey == null || pubkey.isEmpty) return; // malformed handshake
        _connectedDevices[address] = pubkey;
        final username = decoded['username'] as String?;
        final shortId = decoded['shortId'] as String?;
        final profilePictureUrl = decoded['profilePictureUrl'] as String?;

        // Store short ID if received
        if (shortId != null && shortId.isNotEmpty) {
          _deviceShortIds[pubkey] = shortId;
        }

        // Store profile picture URL if received
        if (profilePictureUrl != null && profilePictureUrl.isNotEmpty) {
          _deviceProfilePictures[pubkey] = profilePictureUrl;
        }

        // Build display name: "username #shortId" or just "#shortId" or pubkey prefix
        final hasUsername = username != null && username.isNotEmpty;
        final hasShortId = shortId != null && shortId.isNotEmpty;
        final String displayName;
        if (hasUsername && hasShortId) {
          displayName = '$username #$shortId';
        } else if (hasUsername) {
          displayName = username;
        } else if (hasShortId) {
          displayName = '#$shortId';
        } else {
          displayName = pubkey.length >= 8 ? pubkey.substring(0, 8) : pubkey;
        }
        _deviceNames[pubkey] = displayName;
        _nearbyChangedController.add(nearbyPubkeys);

        // Bidirectional handshake: if we haven't sent our pubkey to this
        // address yet, send it back now so the other side populates its
        // _connectedDevices and nearbyPubkeys.
        if (!_sentHandshakeTo.contains(address)) {
          _sentHandshakeTo.add(address);
          await _sendHandshake(address); // awaited to ensure handshake is sent before returning
        }
        return;
      }

      // Handle media chunks — reassemble before passing up
      if (decoded is Map && decoded['type'] == 'media_chunk') {
        await _handleMediaChunk(decoded as Map<String, dynamic>);
        return;
      }

      // Handle message (including delivery receipts — pass through to BitChatService)
      final message = Message.fromMap(decoded);

      // Drop malformed messages with missing required fields
      if (message.senderPubkey.isEmpty || message.receiverPubkey.isEmpty) return;

      if (_seenMessageIds.contains(message.id)) return;
      _seenMessageIds.add(message.id);

      // Channel messages — always deliver up and relay
      if (message.receiverPubkey.startsWith('channel:')) {
        _messageController.add(message.copyWith(transport: 'bitchat'));
        // ttl > 1: relay with decremented TTL. ttl == 1 means last hop — deliver only.
        if (message.ttl > 1) {
          _relayMessage(message.copyWith(ttl: message.ttl - 1));
        }
        return;
      }

      if (message.receiverPubkey == _myPubkey) {
        // Message or receipt addressed to us — deliver up
        _messageController.add(message.copyWith(
          status: message.type == 'delivery_receipt' ? message.status : 'delivered',
          transport: 'bitchat',
        ));
      } else if (message.type == 'delivery_receipt' && message.receiverPubkey != _myPubkey) {
        // Receipt for someone else — relay it, don't emit locally
        if (message.ttl > 1) {
          _relayMessage(message.copyWith(ttl: message.ttl - 1));
        }
      } else if (message.ttl > 1) {
        // Regular message not for us — relay
        _relayMessage(message.copyWith(ttl: message.ttl - 1));
      }
    } catch (e) {
      // Skip malformed data
    }
  }

  /// Send our pubkey/username to a specific device as a handshake response.
  /// Tries the direct write path first (if we connected to them as central),
  /// then falls back to notifying all subscribed centrals.
  Future<void> _sendHandshake(String address) async {
    if (_myPubkey == null) return;
    final handshakeData = <String, dynamic>{
      'type': 'handshake',
      'pubkey': _myPubkey,
    };
    if (_myUsername != null && _myUsername!.isNotEmpty) {
      handshakeData['username'] = _myUsername;
    }
    if (_myShortId != null && _myShortId!.isNotEmpty) {
      handshakeData['shortId'] = _myShortId;
    }
    if (_myProfilePictureUrl != null && _myProfilePictureUrl!.isNotEmpty) {
      handshakeData['profilePictureUrl'] = _myProfilePictureUrl;
    }
    final bytes = utf8.encode(jsonEncode(handshakeData));

    // Try writing directly if we have a cached write char for this address
    final writeChar = _writeCharCache[address];
    if (writeChar != null) {
      try {
        await writeChar.write(bytes, withoutResponse: true);
        return;
      } catch (_) {}
    }

    // Otherwise broadcast via GATT server notify (reaches all subscribed centrals)
    try {
      await _methodChannel.invokeMethod('sendToAll', {'data': bytes.toList()});
    } catch (_) {}
  }

  /// Update profile picture URL — included in all future handshakes.
  void updateProfilePictureUrl(String? url) {
    _myProfilePictureUrl = url?.isNotEmpty == true ? url : null;
  }

  /// Cleans up chunk buffers for transfers that never completed within 60 seconds.
  void _cleanupStaleChunks() {
    final now = DateTime.now();
    final staleIds = _chunkStartTimes.entries
        .where((e) => now.difference(e.value).inSeconds > 60)
        .map((e) => e.key)
        .toList();
    for (final cid in staleIds) {
      _chunkBuffer.remove(cid);
      _chunkMeta.remove(cid);
      _chunkStartTimes.remove(cid);
    }
  }

  /// Reassemble an incoming media chunk. Emits the full message once all chunks arrive.
  Future<void> _handleMediaChunk(Map<String, dynamic> data) async {
    final cid = data['cid'] as String?;
    final total = data['total'] as int?;
    final idx = data['idx'] as int?;
    final chunkData = data['d'] as String?;
    if (cid == null || total == null || idx == null || chunkData == null) return;
    if (total <= 0 || idx < 0 || idx >= total) return;

    // Record start time for timeout cleanup (only on first chunk)
    _chunkStartTimes.putIfAbsent(cid, () => DateTime.now());

    // Store metadata from first chunk received
    _chunkMeta.putIfAbsent(cid, () => {
      'mediaType': data['mtype'] as String? ?? 'voice_note',
      'senderPubkey': data['sp'] as String? ?? '',
      'receiverPubkey': data['rp'] as String? ?? '',
      'timestamp': data['ts'] as int? ?? 0,
      'senderName': data['sn'] as String?,
      'total': total,
    });

    _chunkBuffer.putIfAbsent(cid, () => {})[idx] = chunkData;

    final received = _chunkBuffer[cid]!;
    if (received.length < total) return; // not yet complete

    // Validate all indices 0..total-1 are present (count match alone isn't enough —
    // duplicate indices could give the right count with gaps in the sequence).
    for (int i = 0; i < total; i++) {
      if (!received.containsKey(i)) return; // gap — wait for missing chunk
    }

    // All chunks received — reassemble in order
    final parts = List.generate(total, (i) => received[i]!);
    final fullBase64 = parts.join();

    // Clean up start time tracking
    _chunkStartTimes.remove(cid);
    final meta = _chunkMeta[cid]!;
    _chunkBuffer.remove(cid);
    _chunkMeta.remove(cid);

    // Emit as a synthetic message carrying the full base64 in the content field.
    // BitChatService will decode the base64 to a local file when it receives this.
    final mediaType = meta['mediaType'] as String;
    final syntheticMap = {
      'id': cid,
      'senderPubkey': meta['senderPubkey'],
      'receiverPubkey': meta['receiverPubkey'],
      'content': '',
      'type': mediaType,
      'timestamp': meta['timestamp'],
      'ttl': 1,
      'status': 'pending',
      'transport': 'bitchat',
      'meshEncrypted': 0,
      'senderName': meta['senderName'],
      'duration': 0,
      // embed the full base64 under the same key BitChatService expects
      if (mediaType == 'voice_note') 'voiceData': fullBase64,
      if (mediaType == 'image') 'imageData': fullBase64,
    };

    if (_seenMessageIds.contains(cid)) return;
    _seenMessageIds.add(cid);
    _messageController.add(Message.fromMap(syntheticMap));
  }

  /// Send a large media payload (voice note or image) over BLE by splitting into
  /// 400-byte base64 chunks. Each chunk is sent as a separate BLE message.
  /// [mediaType] is 'voice_note' or 'image'.
  /// [base64Data] is the full base64-encoded payload.
  Future<bool> sendMediaChunked({
    required Message message,
    required String mediaType,
    required String base64Data,
  }) async {
    if (_writeCharCache.isEmpty) return false;

    const chunkSize = 180; // bytes of base64 per chunk — fits iOS ~185 byte MTU after JSON overhead
    final total = (base64Data.length / chunkSize).ceil();

    for (int i = 0; i < total; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, base64Data.length);
      final piece = base64Data.substring(start, end);

      final chunkMap = {
        'type': 'media_chunk',
        'cid': message.id,
        'total': total,
        'idx': i,
        'mtype': mediaType,
        'sp': message.senderPubkey,
        'rp': message.receiverPubkey,
        'ts': message.timestamp,
        'sn': message.senderName,
        'd': piece,
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(chunkMap)));

      // Send to all GATT clients we're connected to
      for (final entry in _writeCharCache.entries) {
        try {
          await entry.value.write(bytes, withoutResponse: false);
        } catch (_) {}
      }

      // Small delay to avoid flooding the BLE connection
      if (i < total - 1) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }

    return true;
  }

  Future<void> sendMessage(Message message) async {
    _seenMessageIds.add(message.id);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message.toMap())));

    // GATT server path — notifies all centrals subscribed to us.
    // The OS BLE stack fragments notifications to fit the negotiated MTU automatically.
    try {
      await _methodChannel.invokeMethod('sendToAll', {'data': bytes.toList()});
    } catch (_) {}

    // GATT client path — writes to peripherals we connected to.
    // withoutResponse: false uses ATT Write Request which the BLE stack
    // fragments automatically across multiple ATT packets — no custom
    // fragmentation needed regardless of message size.
    for (final entry in _writeCharCache.entries) {
      try {
        await entry.value.write(bytes, withoutResponse: false);
      } catch (_) {}
    }
  }

  Future<void> _relayMessage(Message message) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message.toMap())));
    try {
      await _methodChannel.invokeMethod('sendToAll', {'data': bytes.toList()});
    } catch (_) {}
    for (final entry in _writeCharCache.entries) {
      try {
        await entry.value.write(bytes, withoutResponse: false);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _isRunning = false;
    _scanTimer?.cancel();
    _scanSub?.cancel();
    _eventSub?.cancel();
    _chunkCleanupTimer?.cancel();

    try {
      FlutterBluePlus.stopScan();
    } catch (_) {}

    // Disconnect all connected devices
    for (final device in _pubkeyToDevice.values) {
      try { device.disconnect(); } catch (_) {}
    }

    try {
      await _methodChannel.invokeMethod('stop');
    } catch (_) {}

    // Cancel all device subscriptions
    for (final subs in _deviceSubs.values) {
      for (final sub in subs) {
        sub.cancel();
      }
    }
    _deviceSubs.clear();
    _connectedDevices.clear();
    _pubkeyToDevice.clear();
    _writeCharCache.clear();
    _sentHandshakeTo.clear();
    _connectingDevices.clear();
    _deviceShortIds.clear();
    _deviceProfilePictures.clear();
    _chunkBuffer.clear();
    _chunkMeta.clear();
    _chunkStartTimes.clear();
    _nearbyChangedController.add(nearbyPubkeys);
  }

  Future<void> dispose() async {
    try {
      await stop();
    } catch (_) {}
    _messageController.close();
    _nearbyChangedController.close();
  }
}
