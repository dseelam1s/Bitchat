import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';

/// A successful clink — the peer we just swapped cards with.
class ClinkMatch {
  final String pubkey;
  final String name;
  final bool wasAlreadyContact;
  ClinkMatch(this.pubkey, this.name, this.wasAlreadyContact);
}

/// Tap-two-phones contact swap ("Clink").
///
/// Both phones must have the Clink screen open (armed). The physical tap is
/// detected as an accelerometer jolt; each side then sends a small plaintext
/// `clink` packet to every BLE peer in range (ttl 1 — never relayed, never
/// stored). A peer's `hello` that arrives within [_window] of our own jolt is
/// the match: both sides save each other through the same flow as the
/// radar's Save contact. The gesture is the consent — no confirm dialog,
/// a 5-second undo instead. Works with zero internet.
class ClinkService {
  final MessageService messageService;
  final DatabaseService dbService;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime? _lastJoltAt;
  DateTime? _lastMatchAt;
  bool _armed = false;

  /// m/s² of gravity-removed acceleration that counts as a tap.
  /// Tuned on real hardware — a firm phone-to-phone tap spikes well past
  /// this; walking/handling stays below it.
  static const joltThreshold = 3.2;
  static const _window = Duration(milliseconds: 900);
  static const _matchCooldown = Duration(seconds: 4);
  static const _joltDebounce = Duration(milliseconds: 700);

  final _matchController = StreamController<ClinkMatch>.broadcast();
  Stream<ClinkMatch> get matches => _matchController.stream;

  ClinkService({required this.messageService, required this.dbService});

  /// Start listening for taps + peer packets. Call when the screen opens.
  void arm() {
    if (_armed) return;
    _armed = true;
    debugPrint('[clink] armed');
    messageService.onClinkSignal = _onSignal;
    // RAW accelerometer, not the user (gravity-removed) one: that virtual
    // sensor needs a gyroscope and simply doesn't exist on budget phones
    // (Realme: PlatformException NO_SENSOR). The tap shows up as a sharp
    // deviation of |acceleration| from gravity. 50Hz (gameInterval) —
    // fastestInterval registered no OS-level sensor listener at all on
    // the test devices.
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onAccel,
        onError: (e) => debugPrint('[clink] accel error: $e'));
  }

  /// Stop everything. Call when the screen closes.
  void disarm() {
    _armed = false;
    if (messageService.onClinkSignal == _onSignal) {
      messageService.onClinkSignal = null;
    }
    _accelSub?.cancel();
    _accelSub = null;
  }

  /// Testing/accessibility hook — behaves exactly like a physical tap.
  void simulateJolt() => _jolt();

  int _evtCount = 0;
  double _maxDev = 0;
  DateTime _lastHeartbeat = DateTime.now();

  void _onAccel(AccelerometerEvent e) {
    // Deviation from resting gravity (9.81) — a tap is a sharp spike.
    final dev =
        (sqrt(e.x * e.x + e.y * e.y + e.z * e.z) - 9.81).abs();
    _evtCount++;
    if (dev > _maxDev) _maxDev = dev;
    final now = DateTime.now();
    if (now.difference(_lastHeartbeat).inSeconds >= 3) {
      debugPrint(
          '[clink] hb events=$_evtCount maxDev=${_maxDev.toStringAsFixed(2)}');
      _evtCount = 0;
      _maxDev = 0;
      _lastHeartbeat = now;
    }
    if (dev >= joltThreshold) {
      debugPrint('[clink] JOLT dev=${dev.toStringAsFixed(2)}');
      _jolt();
    }
  }

  void _jolt() {
    if (!_armed) return;
    final now = DateTime.now();
    if (_lastJoltAt != null && now.difference(_lastJoltAt!) < _joltDebounce) {
      return;
    }
    _lastJoltAt = now;
    messageService.sendBleSignal(
        'clink', jsonEncode({'phase': 'hello', 'name': messageService.username ?? ''}));
  }

  Future<void> _onSignal(Message msg) async {
    if (!_armed) return;
    final now = DateTime.now();
    if (_lastMatchAt != null && now.difference(_lastMatchAt!) < _matchCooldown) {
      return;
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(msg.content) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final phase = payload['phase'] as String? ?? '';
    final name = (payload['name'] as String? ?? '').trim();

    if (phase == 'hello') {
      // Their tap reached us — a match only if WE also felt a jolt just now.
      if (_lastJoltAt == null || now.difference(_lastJoltAt!) > _window) return;
      await _complete(msg.senderPubkey, name);
      messageService.sendBleSignal(
        'clink',
        jsonEncode({'phase': 'match', 'name': messageService.username ?? ''}),
        toPubkeys: [msg.senderPubkey],
      );
    } else if (phase == 'match') {
      // Peer confirmed the hello we sent on our jolt.
      await _complete(msg.senderPubkey, name);
    }
  }

  Future<void> _complete(String pubkey, String name) async {
    _lastMatchAt = DateTime.now();
    final bleName = messageService.nearbyDeviceNames[pubkey]
        ?.replaceAll(RegExp(r'\s*#\d+$'), '')
        .trim();
    final display = name.isNotEmpty
        ? name
        : (bleName?.isNotEmpty == true ? bleName! : '#${Contact.shortIdFor(pubkey)}');

    final existing = await dbService.getAllContacts();
    final already = existing.any((c) => c.pubkey == pubkey);
    if (!already) {
      await dbService.insertContact(
          Contact(pubkey: pubkey, name: display.startsWith('#') ? null : display));
      messageService.triggerContactsBackup();
    }
    _matchController.add(ClinkMatch(pubkey, display, already));
  }

  /// Undo a clink-save (5-second window in the UI).
  Future<void> undo(String pubkey) async {
    await dbService.deleteContact(pubkey);
    messageService.triggerContactsBackup();
  }

  void dispose() {
    disarm();
    _matchController.close();
  }
}
