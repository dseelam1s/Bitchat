import 'dart:async';
import 'dart:convert';

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

  /// Called when a call signal arrives (offer/answer/ICE/ended/declined/busy).
  /// Callback receives the full decoded payload map.
  void Function(Map<String, dynamic> payload)? onSignalReceived;

  /// Called when a messaging payload arrives (dm, delivery_receipt,
  /// read_receipt, typing, message_ack). Routed separately from call signals.
  void Function(Map<String, dynamic> payload)? onMessageReceived;

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
      _channel = WebSocketChannel.connect(uri);

      // Wait for the handshake to complete (throws if server rejects)
      await _channel!.ready;

      _isConnected = true;
      _reconnectTimer?.cancel();

      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
    } catch (_) {
      _isConnected = false;
      _scheduleReconnect();
    }
  }

  // Message types routed to onMessageReceived (not call signals)
  static const _msgTypes = {
    'dm', 'delivery_receipt', 'read_receipt', 'typing', 'message_ack',
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
  /// Returns true if sent via WebSocket, false if not connected (caller should fallback).
  bool send(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return false;
    try {
      _channel!.sink.add(jsonEncode(payload));
      return true;
    } catch (_) {
      _isConnected = false;
      _scheduleReconnect();
      return false;
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
