import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:nostr_tools/nostr_tools.dart' hide Message;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bitchat_messenger/core/bounded_set.dart';
import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';

class _RelayConnection {
  final String url;
  WebSocketChannel? channel;
  bool isConnected = false;
  bool isReconnecting = false;

  _RelayConnection(this.url);
}

class NostrService {
  final Map<String, _RelayConnection> _relays = {};
  final _messageController = StreamController<Message>.broadcast();
  final _channelMessageController = StreamController<Map<String, dynamic>>.broadcast();
  final _seenEventIds = BoundedSet<String>(5000);
  final Map<String, StreamController<Map<String, dynamic>>> _pendingLookups = {};
  String? _privateKey;
  String? _publicKey;
  int? _lastEventTimestamp;
  final _eventApi = EventApi();
  final _nip04 = Nip04(); // kept for backward-compatible decryption
  final _nip44 = Nip44(); // new default encryption

  Stream<Message> get messageStream => _messageController.stream;
  Stream<Map<String, dynamic>> get channelMessageStream => _channelMessageController.stream;
  bool get isConnected => _relays.values.any((r) => r.isConnected);
  int get connectedCount => _relays.values.where((r) => r.isConnected).length;
  List<String> get relayUrls => _relays.keys.toList();

  Map<String, bool> get relayStatuses =>
      {for (final r in _relays.values) r.url: r.isConnected};

  void setKeys(String privateKey, String publicKey) {
    _privateKey = privateKey;
    _publicKey = publicKey;
  }

  // Load saved relays or use defaults
  Future<List<String>> _loadRelayList() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('relays');
    if (saved != null && saved.isNotEmpty) return saved;
    return AppConstants.defaultRelays;
  }

  Future<void> _saveRelayList() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('relays', _relays.keys.toList());
  }

  // Connect to all relays
  Future<void> connect() async {
    final urls = await _loadRelayList();
    for (final url in urls) {
      _connectToRelay(url);
    }
  }

  Future<void> _connectToRelay(String url) async {
    if (_relays.containsKey(url) && _relays[url]!.isConnected) return;

    // Close old socket before replacing — prevents duplicate event listeners
    final old = _relays[url];
    if (old != null) {
      old.isConnected = false;
      try { old.channel?.sink.close(); } catch (_) {}
    }

    final relay = _RelayConnection(url);
    _relays[url] = relay;

    try {
      relay.channel = WebSocketChannel.connect(Uri.parse(url));
      await relay.channel!.ready;
      relay.isConnected = true;
      _listenForMessages(relay);

      // Subscribe if we have a public key
      if (_publicKey != null) {
        _subscribeOnRelay(relay, _publicKey!);
      }

      // Re-subscribe to all joined channels
      for (final channelId in _subscribedChannels) {
        _subscribeChannelOnRelay(relay, channelId);
      }
    } catch (e) {
      relay.isConnected = false;
      _scheduleReconnect(relay);
    }
  }

  // Add a new relay
  Future<void> addRelay(String url) async {
    await _connectToRelay(url);
    await _saveRelayList();
  }

  // Remove a relay
  Future<void> removeRelay(String url) async {
    final relay = _relays.remove(url);
    if (relay != null) {
      relay.channel?.sink.close();
      relay.isConnected = false;
    }
    await _saveRelayList();
  }

  void _listenForMessages(_RelayConnection relay) {
    relay.channel?.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is List && decoded.isNotEmpty) {
            if (decoded[0] == 'EOSE' && decoded.length >= 2) {
              final subId = decoded[1] as String?;
              if (subId != null && _pendingLookups.containsKey(subId)) {
                _pendingLookups[subId]!.add({'_eose': true});
              }
            } else if (decoded[0] == 'EVENT' && decoded.length >= 3) {
              final subId = decoded.length >= 2 ? decoded[1] as String? : null;
              final event = decoded[2] as Map<String, dynamic>;
              if (subId != null && _pendingLookups.containsKey(subId)) {
                _pendingLookups[subId]!.add(event);
              } else {
                _handleEvent(event);
              }
            }
          }
        } catch (e) {
          // Skip malformed messages
        }
      },
      onDone: () {
        relay.isConnected = false;
        _scheduleReconnect(relay);
      },
      onError: (error) {
        relay.isConnected = false;
        _scheduleReconnect(relay);
      },
    );
  }

  Future<void> _handleEvent(Map<String, dynamic> event) async {
    final eventId = event['id'] as String?;
    if (eventId != null && _seenEventIds.contains(eventId)) return;
    if (eventId != null) _seenEventIds.add(eventId);

    final kind = event['kind'] as int?;

    // Handle channel messages (kind 42 — NIP-28)
    if (kind == 42) {
      _handleChannelEvent(event);
      return;
    }

    // Track latest timestamp for fetching missed messages
    final createdAt = event['created_at'] as int?;
    if (createdAt != null) {
      if (_lastEventTimestamp == null || createdAt > _lastEventTimestamp!) {
        _lastEventTimestamp = createdAt;
      }
    }

    final content = event['content'] as String?;
    final pubkey = event['pubkey'] as String?;
    final tags = event['tags'] as List?;

    if (content == null || pubkey == null) return;

    // Mutable sender — may be overridden for mesh-relayed messages
    String senderPubkey = pubkey;

    String? receiverPubkey;
    if (tags != null) {
      for (final tag in tags) {
        if (tag is List && tag.length >= 2 && tag[0] == 'p') {
          receiverPubkey = tag[1] as String;
          break;
        }
      }
    }

    if (receiverPubkey == null) return;

    // Skip our own echoed messages — we already have them in local DB
    if (pubkey == _publicKey) return;

    String decryptedContent;
    try {
      if (_privateKey != null) {
        // Try NIP-44 first, fall back to NIP-04 for older messages
        if (Nip44.isNip44(content)) {
          decryptedContent = await _nip44.decrypt(_privateKey!, pubkey, content);
        } else {
          decryptedContent = _nip04.decrypt(_privateKey!, pubkey, content);
        }
      } else {
        decryptedContent = content;
      }
    } catch (e) {
      // Decryption failed — skip this message rather than showing ciphertext
      return;
    }

    // Check if the decrypted content is a special message type (JSON with type field)
    String messageType = 'text';
    String messageContent = decryptedContent;
    bool isMeshEncrypted = false;
    try {
      final parsed = jsonDecode(decryptedContent);
      if (parsed is Map && parsed['type'] == 'delivery_receipt') {
        messageType = 'delivery_receipt';
        messageContent = parsed['originalMessageId'] as String;
      } else if (parsed is Map && parsed['type'] == 'mesh_relay') {
        // This was relayed from mesh — content is still mesh-encrypted
        messageContent = parsed['encryptedContent'] as String;
        isMeshEncrypted = true;
        // Use the original sender's pubkey so decryption uses the correct shared secret
        if (parsed['originalSender'] != null) {
          senderPubkey = parsed['originalSender'] as String;
        }
      }
    } catch (_) {
      // Not JSON — it's a regular text message
    }

    final message = Message(
      id: eventId ?? '',
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      content: messageContent,
      type: messageType,
      timestamp: (event['created_at'] as int?) ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      transport: 'nostr',
      status: 'delivered',
      meshEncrypted: isMeshEncrypted,
    );

    _messageController.add(message);
  }

  Future<void> sendMessage(Message message) async {
    if (!isConnected) {
      throw Exception('Not connected to any relay');
    }
    if (_privateKey == null || _publicKey == null) {
      throw Exception('Keys not set');
    }

    // Encrypt with NIP-44 (XChaCha20-Poly1305)
    final encryptedContent = await _nip44.encrypt(
      _privateKey!,
      message.receiverPubkey,
      message.content,
    );

    final event = Event(
      kind: 4,
      tags: [
        ['p', message.receiverPubkey]
      ],
      content: encryptedContent,
      created_at: message.timestamp,
      pubkey: _publicKey!,
    );

    final signedEvent = _eventApi.finishEvent(event, _privateKey!);

    final request = jsonEncode([
      'EVENT',
      {
        'id': signedEvent.id,
        'pubkey': signedEvent.pubkey,
        'created_at': signedEvent.created_at,
        'kind': signedEvent.kind,
        'tags': signedEvent.tags,
        'content': signedEvent.content,
        'sig': signedEvent.sig,
      }
    ]);

    // Send to ALL connected relays
    for (final relay in _relays.values) {
      if (relay.isConnected && relay.channel != null) {
        try {
          relay.channel!.sink.add(request);
        } catch (_) {}
      }
    }
  }

  /// Send a WebRTC call signal as an encrypted DM (kind:4).
  /// Used for call_offer, call_answer, call_ice, call_ended, call_declined, call_busy.
  Future<void> sendCallSignal({
    required String recipientPubkey,
    required Map<String, dynamic> payload,
  }) async {
    if (_privateKey == null || _publicKey == null) return;
    final msg = Message(
      id: '',
      senderPubkey: _publicKey!,
      receiverPubkey: recipientPubkey,
      content: jsonEncode(payload),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await sendMessage(msg);
  }

  /// Send a group removal notification as an encrypted DM (kind:4) to a removed member.
  Future<void> sendGroupRemovalDm({
    required String recipientPubkey,
    required String channelId,
  }) async {
    if (_privateKey == null || _publicKey == null) return;
    final msg = Message(
      id: '',
      senderPubkey: _publicKey!,
      receiverPubkey: recipientPubkey,
      content: jsonEncode({
        '__type': 'group_removal',
        'channelId': channelId,
      }),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await sendMessage(msg);
  }

  /// Send a group invite as an encrypted DM (kind:4) to a specific recipient.
  /// The content is a JSON payload recognized by the receiver's app.
  Future<void> sendGroupInviteDm({
    required String recipientPubkey,
    required String channelId,
    required String channelName,
    required String adminPubkey,
  }) async {
    if (_privateKey == null || _publicKey == null) return;
    final msg = Message(
      id: '',
      senderPubkey: _publicKey!,
      receiverPubkey: recipientPubkey,
      content: jsonEncode({
        '__type': 'group_invite',
        'channelId': channelId,
        'channelName': channelName,
        'adminPubkey': adminPubkey,
      }),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await sendMessage(msg);
  }

  void subscribe(String pubkey) {
    _publicKey = _publicKey ?? pubkey;
    for (final relay in _relays.values) {
      if (relay.isConnected) {
        _subscribeOnRelay(relay, pubkey);
      }
    }
  }

  void setLastEventTimestamp(int timestamp) {
    _lastEventTimestamp = timestamp;
  }

  void _subscribeOnRelay(_RelayConnection relay, String pubkey) {
    if (!relay.isConnected || relay.channel == null) return;

    // Fetch messages sent TO me
    final filterToMe = <String, dynamic>{
      'kinds': [4],
      '#p': [pubkey],
    };

    // If we have a last seen timestamp, only fetch newer messages
    if (_lastEventTimestamp != null) {
      filterToMe['since'] = _lastEventTimestamp!;
    }

    relay.channel!.sink.add(jsonEncode([
      'REQ',
      'inbox_${pubkey.substring(0, 8)}',
      filterToMe,
    ]));
  }

  // ---- Channel support (NIP-28 kind 42) ----

  void _handleChannelEvent(Map<String, dynamic> event) {
    final content = event['content'] as String?;
    final pubkey = event['pubkey'] as String?;
    final tags = event['tags'] as List?;
    final eventId = event['id'] as String?;
    if (content == null || pubkey == null) return;

    // Skip our own messages
    if (pubkey == _publicKey) return;

    // Extract channel ID from 'e' tag
    String? channelId;
    if (tags != null) {
      for (final tag in tags) {
        if (tag is List && tag.length >= 2 && tag[0] == 'e') {
          channelId = tag[1] as String;
          break;
        }
      }
    }
    if (channelId == null) return;

    // Content is JSON with message data
    try {
      final data = jsonDecode(content);
      if (data is! Map) return;
      data['id'] = eventId ?? data['id'] ?? '';
      data['channelId'] = channelId;
      data['senderPubkey'] = pubkey;
      data['timestamp'] = event['created_at'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
      data['transport'] = 'nostr';
      _channelMessageController.add(Map<String, dynamic>.from(data));
    } catch (_) {}
  }

  Future<void> sendChannelMessage({
    required String channelId,
    required String content,
    required String senderName,
    required int timestamp,
  }) async {
    if (!isConnected) return;
    if (_privateKey == null || _publicKey == null) return;

    final payload = jsonEncode({
      'content': content,
      'senderName': senderName,
      'type': 'channel_message',
    });

    final event = Event(
      kind: 42,
      tags: [
        ['e', channelId],
      ],
      content: payload,
      created_at: timestamp,
      pubkey: _publicKey!,
    );

    final signedEvent = _eventApi.finishEvent(event, _privateKey!);

    final request = jsonEncode([
      'EVENT',
      {
        'id': signedEvent.id,
        'pubkey': signedEvent.pubkey,
        'created_at': signedEvent.created_at,
        'kind': signedEvent.kind,
        'tags': signedEvent.tags,
        'content': signedEvent.content,
        'sig': signedEvent.sig,
      }
    ]);

    for (final relay in _relays.values) {
      if (relay.isConnected && relay.channel != null) {
        try {
          relay.channel!.sink.add(request);
        } catch (_) {}
      }
    }
  }

  final Set<String> _subscribedChannels = {};

  void subscribeToChannel(String channelId) {
    _subscribedChannels.add(channelId);
    for (final relay in _relays.values) {
      if (relay.isConnected) {
        _subscribeChannelOnRelay(relay, channelId);
      }
    }
  }

  void unsubscribeFromChannel(String channelId) {
    _subscribedChannels.remove(channelId);
    // Send CLOSE for the subscription
    for (final relay in _relays.values) {
      if (relay.isConnected && relay.channel != null) {
        try {
          relay.channel!.sink.add(jsonEncode([
            'CLOSE',
            'ch_${channelId.length >= 8 ? channelId.substring(0, 8) : channelId}',
          ]));
        } catch (_) {}
      }
    }
  }

  void _subscribeChannelOnRelay(_RelayConnection relay, String channelId) {
    if (!relay.isConnected || relay.channel == null) return;
    relay.channel!.sink.add(jsonEncode([
      'REQ',
      'ch_${channelId.length >= 8 ? channelId.substring(0, 8) : channelId}',
      {
        'kinds': [42],
        '#e': [channelId],
        'limit': 50,
      },
    ]));
  }

  /// Publish kind:0 profile so others can find us by short ID.
  /// Includes a `t` tag `sid:XXXXXX` that relays index for lookup queries.
  Future<void> publishProfile({String? username, required String shortId}) async {
    if (_privateKey == null || _publicKey == null) return;
    if (!isConnected) return;

    final content = jsonEncode({
      if (username != null && username.isNotEmpty) 'name': username,
      'short_id': shortId,
    });

    final event = Event(
      kind: 0,
      tags: [
        ['t', 'sid:$shortId'],
      ],
      content: content,
      created_at: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      pubkey: _publicKey!,
    );

    final signedEvent = _eventApi.finishEvent(event, _privateKey!);
    final request = jsonEncode([
      'EVENT',
      {
        'id': signedEvent.id,
        'pubkey': signedEvent.pubkey,
        'created_at': signedEvent.created_at,
        'kind': signedEvent.kind,
        'tags': signedEvent.tags,
        'content': signedEvent.content,
        'sig': signedEvent.sig,
      }
    ]);

    for (final relay in _relays.values) {
      if (relay.isConnected && relay.channel != null) {
        try {
          relay.channel!.sink.add(request);
        } catch (_) {}
      }
    }
  }

  /// Query relays for users whose short ID matches [shortId].
  /// Returns a list of `{pubkey, name}` maps. Empty if offline or no match.
  Future<List<Map<String, String>>> lookupByShortId(String shortId) async {
    if (!isConnected) throw Exception('Not connected to any relay');

    final subId = 'lookup_sid_$shortId';
    final controller = StreamController<Map<String, dynamic>>();
    _pendingLookups[subId] = controller;

    for (final relay in _relays.values) {
      if (relay.isConnected && relay.channel != null) {
        try {
          relay.channel!.sink.add(jsonEncode([
            'REQ',
            subId,
            {
              'kinds': [0],
              '#t': ['sid:$shortId'],
              'limit': 10,
            }
          ]));
        } catch (_) {}
      }
    }

    final results = <Map<String, String>>[];
    final seen = <String>{};

    try {
      await for (final event
          in controller.stream.timeout(const Duration(seconds: 8))) {
        if (event.containsKey('_eose')) break;
        final pubkey = event['pubkey'] as String?;
        if (pubkey == null || seen.contains(pubkey)) continue;
        seen.add(pubkey);
        String? name;
        try {
          final parsed = jsonDecode(event['content'] as String? ?? '{}');
          name = parsed['name'] as String?;
        } catch (_) {}
        results.add({'pubkey': pubkey, 'name': name ?? ''});
      }
    } on TimeoutException {
      // Return whatever arrived before timeout
    } catch (_) {}

    _pendingLookups.remove(subId);
    await controller.close();
    for (final relay in _relays.values) {
      if (relay.isConnected && relay.channel != null) {
        try {
          relay.channel!.sink.add(jsonEncode(['CLOSE', subId]));
        } catch (_) {}
      }
    }

    return results;
  }

  void _scheduleReconnect(_RelayConnection relay) {
    if (relay.isReconnecting) return;
    relay.isReconnecting = true;
    Future.delayed(const Duration(seconds: 10), () {
      relay.isReconnecting = false;
      if (!relay.isConnected && _relays.containsKey(relay.url)) {
        _connectToRelay(relay.url);
      }
    });
  }

  void disconnect() {
    for (final relay in _relays.values) {
      relay.channel?.sink.close();
      relay.isConnected = false;
    }
  }

  void dispose() {
    disconnect();
    _relays.clear();
    _messageController.close();
    _channelMessageController.close();
  }
}
