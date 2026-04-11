import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Flutter wrapper for iOS MultipeerConnectivity native service.
/// On Android this class is a no-op — all methods return false/empty.
class MultipeerChannel {
  static const _method = MethodChannel('com.bitchat/multipeer');
  static const _event = EventChannel('com.bitchat/multipeer_events');

  Stream<Map<String, dynamic>>? _eventStream;

  /// Broadcast stream of events from the native multipeer layer.
  /// Event shapes:
  ///   type='received'     → data: List[int], fromPeer: String
  ///   type='connected'    → peerId: String
  ///   type='disconnected' → peerId: String
  Stream<Map<String, dynamic>> get eventStream {
    _eventStream ??= _event
        .receiveBroadcastStream()
        .map((e) => Map<String, dynamic>.from(e as Map));
    return _eventStream!;
  }

  Future<bool> start(String pubkey) async {
    if (!Platform.isIOS) return false;
    try {
      return await _method.invokeMethod<bool>('start', {'pubkey': pubkey}) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isIOS) return;
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Send bytes to ALL connected multipeer nodes. Returns true if at least
  /// one peer received it.
  Future<bool> send(Uint8List bytes) async {
    if (!Platform.isIOS) return false;
    try {
      return await _method.invokeMethod<bool>('send', {'data': bytes.toList()}) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> connectedPeers() async {
    if (!Platform.isIOS) return [];
    try {
      final result = await _method.invokeMethod<List<Object?>>('getConnectedPeers');
      return result?.whereType<String>().toList() ?? [];
    } catch (_) {
      return [];
    }
  }
}
