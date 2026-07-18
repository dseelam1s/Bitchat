import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:bitchat_messenger/core/constants.dart';
import 'package:bitchat_messenger/core/server_service.dart';

/// WebSocket-based call signaling service.
///
/// Connects to the Django Channels signaling server and routes
/// WebRTC signals (offer/answer/ICE) with sub-100ms latency.
///
/// Falls back gracefully — if the WebSocket is not connected,
/// [isConnected] returns false and CallService falls back to Nostr.
class SignalingService {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _isConnected = false;
  bool _disposed = false;
  String? _token;
  Timer? _reconnectTimer;

  // Messages (not call signals) that couldn't be sent because the socket was
  // down. Flushed in order on the next successful connect so group messages
  // and invites survive a dead socket instead of being silently dropped.
  final Queue<Map<String, dynamic>> _outbox = Queue();
  static const _outboxLimit = 200;
  static const _queueableTypes = {'dm', 'group_dm'};

  /// Called when a call signal arrives (offer/answer/ICE/ended/declined/busy).
  /// Callback receives the full decoded payload map.
  void Function(Map<String, dynamic> payload)? onSignalReceived;

  /// Called when a messaging payload arrives (dm, delivery_receipt,
  /// read_receipt, typing, message_ack). Routed separately from call signals.
  void Function(Map<String, dynamic> payload)? onMessageReceived;

  /// Called after every successful (re)connect. Wired to a missed-message
  /// fetch so anything the server stored while the socket was down (silent
  /// half-open drops included) is pulled in without waiting for an app restart.
  void Function()? onConnected;

  bool get isConnected => _isConnected;

  /// Connect to the signaling server. Fetches a fresh JWT from [ServerService] automatically.
  /// Call this once after authentication completes; reconnects self-heal on token expiry.
  Future<void> connect() async {
    if (_disposed) return;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disposed) return;

    // Always fetch a fresh token — handles initial connect and expiry-triggered reconnects
    _token = await ServerService().getAccessToken();
    if (_token == null) {
      // No token yet (server unreachable or not authenticated) — retry later
      _scheduleReconnect();
      return;
    }
    _cleanup();

    try {
      final uri = Uri.parse('${AppConstants.signalingUrl}?token=$_token');
      // pingInterval is the half-open-connection killer: NAT timeouts and
      // proxy idle drops leave a socket that looks alive but delivers
      // nothing (observed on-device: fan-out silently missed after ~20 min).
      // Protocol pings force such sockets to error out → onDone → reconnect.
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 15),
      );

      // Wait for the handshake to complete (throws if server rejects)
      await _channel!.ready;

      _isConnected = true;
      _reconnectTimer?.cancel();

      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );

      _flushOutbox();
      onConnected?.call();
    } catch (_) {
      _isConnected = false;
      _scheduleReconnect();
    }
  }

  // Message types routed to onMessageReceived (not call signals)
  static const _msgTypes = {
    'dm', 'delivery_receipt', 'read_receipt', 'typing', 'message_ack', 'image',
    'group_dm',
  };

  void _onMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';
      if (_msgTypes.contains(type)) {
        onMessageReceived?.call(data);
      } else {
        onSignalReceived?.call(data);
      }
    } catch (_) {}
  }

  /// Send a signal to a recipient.
  /// Returns true if sent via WebSocket (or queued for delivery on reconnect —
  /// dm/group_dm only), false if not connected (caller should fallback).
  /// Call signals are never queued: a stale SDP/ICE payload is useless.
  bool send(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) {
      // Kick the reconnect loop — if connect() was never reached (e.g. the
      // app launched offline), nothing else would ever start it and queued
      // messages would sit forever.
      _scheduleReconnect();
      return _enqueue(payload);
    }
    try {
      _channel!.sink.add(jsonEncode(payload));
      return true;
    } catch (_) {
      _isConnected = false;
      _scheduleReconnect();
      return _enqueue(payload);
    }
  }

  bool _enqueue(Map<String, dynamic> payload) {
    if (!_queueableTypes.contains(payload['type'])) return false;
    if (_outbox.length >= _outboxLimit) _outbox.removeFirst();
    _outbox.add(payload);
    return true;
  }

  void _flushOutbox() {
    while (_outbox.isNotEmpty && _isConnected && _channel != null) {
      final payload = _outbox.removeFirst();
      try {
        _channel!.sink.add(jsonEncode(payload));
      } catch (_) {
        _outbox.addFirst(payload);
        _isConnected = false;
        _scheduleReconnect();
        return;
      }
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _isConnected = false;
    _reconnectTimer?.cancel();
    // Retry with exponential-ish backoff capped at 30 seconds
    _reconnectTimer = Timer(const Duration(seconds: 5), _doConnect);
  }

  void _cleanup() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _cleanup();
  }
}
