import 'dart:io';
import 'package:flutter/services.dart';

/// Thin wrapper around the Android foreground service method channel.
///
/// On Android: starts/stops [MeshForegroundService], which holds a partial
/// wake lock and shows a persistent notification so Android does not kill
/// the process while the BLE mesh is running.
///
/// On iOS: no-op — iOS uses the MultipeerConnectivity session which is
/// handled by the OS and does not need a separate foreground service.
class ForegroundServiceHelper {
  static const _channel = MethodChannel('com.bitchat/foreground');

  /// Start the foreground service. Safe to call multiple times.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('start');
    } catch (_) {
      // Foreground service is optional — app works without it, BLE just
      // stops when the screen locks or the user switches away.
    }
  }

  /// Stop the foreground service. Call this when the user explicitly
  /// disables mesh (not on normal app backgrounding).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {}
  }
}
