import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:nostr_tools/nostr_tools.dart' show KeyApi;
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/key_manager.dart';
import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';

/// One thing said/shared at a fire. Lives in MEMORY ONLY — campfire content
/// is never written to the database. The only thing that survives a burn is
/// the single ember each person chooses.
class FireMoment {
  final String id;
  final String senderPubkey;
  final String senderName;
  final String body;
  final bool burnOnly; // sharer marked it "burns with the fire" — never keepable
  final bool system; // "X walked in" lines
  final int tsMs;
  FireMoment({
    required this.id,
    required this.senderPubkey,
    required this.senderName,
    required this.body,
    this.burnOnly = false,
    this.system = false,
    required this.tsMs,
  });
}

/// A flame visible on the radar — heard via beacon from someone AT the fire.
/// One hop only: you see it because a participant is in your direct range.
class NearbyFire {
  final String fireId;
  final String litBy;
  final int count;
  final String viaPubkey;
  final DateTime lastSeen;
  NearbyFire({
    required this.fireId,
    required this.litBy,
    required this.count,
    required this.viaPubkey,
    required this.lastSeen,
  });
}

/// What's left when a fire goes out — passed to the ember picker.
class BurnedFire {
  final String fireId;
  final String litBy;
  final int litAtMs;
  final int burnedAtMs;
  final int peakCount;
  final List<FireMoment> moments;
  BurnedFire({
    required this.fireId,
    required this.litBy,
    required this.litAtMs,
    required this.burnedAtMs,
    required this.peakCount,
    required this.moments,
  });
  List<FireMoment> get keepable =>
      moments.where((m) => !m.burnOnly && !m.system).toList();
  Duration get duration => Duration(milliseconds: burnedAtMs - litAtMs);
}

/// The Campfire: an ephemeral room that exists only while people are
/// physically together (BLE range) and burns when they part.
///
/// Everything rides the BLE mesh as `fire_*` packets with ttl 1 (no relay —
/// the fire is a physical huddle, one hop by design). Message bodies are
/// encrypted with a throwaway fire keypair handed to joiners over an
/// E2E-encrypted key packet; the server is never involved at all.
class CampfireService {
  final MessageService messageService;
  final DatabaseService dbService;
  final KeyManager keyManager;

  final _keyApi = KeyApi();
  final _nip44 = Nip44();

  // ── Active fire state (memory only) ──
  String? _fireId;
  String? _firePriv;
  String? _firePub;
  String _litBy = '';
  int _litAtMs = 0;
  final Map<String, _Participant> _participants = {}; // others, not me
  final List<FireMoment> _moments = [];
  final Set<String> _seenMomentIds = {};
  int _peakCount = 1;

  // ── Flames heard on the radar ──
  final Map<String, NearbyFire> _nearbyFires = {};

  Timer? _beaconTimer;
  Timer? _housekeepTimer;
  Completer<bool>? _joinWaiter;
  String? _joiningFireId;
  BurnedFire? _pendingBurn;

  static const _beaconEvery = Duration(seconds: 10);
  static const _flameExpiry = Duration(seconds: 35);

  /// How long an ACTIVE fire keeps burning with nobody else heard from —
  /// covers BLE blips, bathroom breaks and the chai run.
  static const grace = Duration(minutes: 3);

  /// A fire NOBODY has joined yet waits this long for someone to walk in,
  /// then goes out silently — no burn ceremony for a fire no one came to.
  static const kindling = Duration(minutes: 10);

  final _roomController = StreamController<void>.broadcast();
  final _radarController = StreamController<void>.broadcast();
  final _burnController = StreamController<BurnedFire>.broadcast();

  /// Fires whenever the active room changes (new moment, join, presence).
  Stream<void> get roomUpdates => _roomController.stream;

  /// Fires when flames appear/expire on the radar.
  Stream<void> get radarUpdates => _radarController.stream;

  /// Fires exactly once when the active fire burns out.
  Stream<BurnedFire> get burns => _burnController.stream;

  bool get inFire => _fireId != null;
  String? get fireId => _fireId;
  String get litBy => _litBy;
  int get litAtMs => _litAtMs;

  /// Everyone at the fire including me.
  int get headcount => _participants.length + 1;
  List<FireMoment> get moments => List.unmodifiable(_moments);
  List<NearbyFire> get nearbyFires => _nearbyFires.values.toList();
  BurnedFire? get pendingBurn => _pendingBurn;

  CampfireService({
    required this.messageService,
    required this.dbService,
    required this.keyManager,
  }) {
    _housekeepTimer = Timer.periodic(const Duration(seconds: 8), (_) => _housekeep());
  }

  String get _myName {
    final u = keyManager.username;
    if (u != null && u.isNotEmpty) return u;
    final pub = keyManager.publicKey;
    return pub == null ? 'Someone' : '#${pub.substring(0, 8)}';
  }

  // ── Lighting ──────────────────────────────────────────────────────────────

  /// Light a campfire. Returns an error string, or null on success.
  Future<String?> light() async {
    if (inFire) return 'You already have a fire burning.';
    if (messageService.nearbyUsers.isEmpty) {
      return 'No one is in range — a campfire needs people around it.';
    }
    final firePriv = _keyApi.generatePrivateKey();
    _firePriv = firePriv;
    _firePub = _keyApi.getPublicKey(firePriv);
    _fireId = 'f_${_firePub!.substring(0, 24)}';
    _litBy = _myName;
    _litAtMs = DateTime.now().millisecondsSinceEpoch;
    _participants.clear();
    _moments.clear();
    _seenMomentIds.clear();
    _peakCount = 1;
    _pendingBurn = null;

    _moments.add(FireMoment(
      id: 'sys_lit',
      senderPubkey: '',
      senderName: '',
      body: '$_litBy lit the fire 🔥',
      system: true,
      tsMs: _litAtMs,
    ));

    _beaconTimer = Timer.periodic(_beaconEvery, (_) => _sendBeacon());
    _sendBeacon();
    _roomController.add(null);
    return null;
  }

  void _sendBeacon() {
    if (!inFire) return;
    messageService.sendBleSignal(
      'fire_beacon',
      jsonEncode({
        'fireId': _fireId,
        'litBy': _litBy,
        'count': headcount,
        'name': _myName,
      }),
    );
  }

  // ── Joining ───────────────────────────────────────────────────────────────

  /// Walk in to a flame seen on the radar. Resolves true once the fire key
  /// arrives and we're in the room.
  Future<bool> join(String fireId) async {
    if (inFire) return _fireId == fireId;
    final flame = _nearbyFires[fireId];
    if (flame == null) return false;

    _joiningFireId = fireId;
    _joinWaiter = Completer<bool>();
    await messageService.sendBleSignal(
      'fire_join',
      jsonEncode({'fireId': fireId}),
      toPubkeys: [flame.viaPubkey],
    );
    final ok = await _joinWaiter!.future
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    _joinWaiter = null;
    _joiningFireId = null;
    return ok;
  }

  // ── Speaking ──────────────────────────────────────────────────────────────

  Future<void> sendMoment(String body, {bool burnOnly = false}) async {
    if (!inFire || body.trim().isEmpty) return;
    final id = keyManager.generateMessageId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final myPub = keyManager.publicKey ?? '';

    _moments.add(FireMoment(
      id: id,
      senderPubkey: myPub,
      senderName: _myName,
      body: body.trim(),
      burnOnly: burnOnly,
      tsMs: now,
    ));
    _seenMomentIds.add(id);
    _roomController.add(null);

    final ct = await _nip44.encrypt(
      _firePriv!,
      _firePub!,
      jsonEncode({
        'mid': id,
        'name': _myName,
        'body': body.trim(),
        'burnOnly': burnOnly,
      }),
    );
    await messageService.sendBleSignal(
        'fire_msg', jsonEncode({'fireId': _fireId, 'ct': ct}));
  }

  // ── Incoming BLE signals (wired from MessageService.onFireSignal) ────────

  Future<void> handleSignal(Message msg) async {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(msg.content) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg.type) {
      case 'fire_beacon':
        await _onBeacon(msg.senderPubkey, payload);
      case 'fire_join':
        await _onJoinRequest(msg.senderPubkey, payload);
      case 'fire_key':
        await _onFireKey(msg.senderPubkey, payload);
      case 'fire_enter':
        _onEnter(msg.senderPubkey, payload);
      case 'fire_msg':
        await _onFireMsg(msg.senderPubkey, payload);
    }
  }

  Future<void> _onBeacon(String from, Map<String, dynamic> p) async {
    final fireId = p['fireId'] as String? ?? '';
    if (fireId.isEmpty) return;

    if (fireId == _fireId) {
      // A fellow participant — presence ping.
      _touch(from, p['name'] as String?);
      return;
    }
    if (inFire) return; // already at a fire — other flames wait

    _nearbyFires[fireId] = NearbyFire(
      fireId: fireId,
      litBy: p['litBy'] as String? ?? 'Someone',
      count: (p['count'] as num?)?.toInt() ?? 1,
      viaPubkey: from,
      lastSeen: DateTime.now(),
    );
    _radarController.add(null);
  }

  Future<void> _onJoinRequest(String from, Map<String, dynamic> p) async {
    if (!inFire || p['fireId'] != _fireId) return;
    final myPriv = keyManager.privateKey;
    if (myPriv == null) return;
    // Hand the fire key over E2E-encrypted to the joiner only.
    final ct = await _nip44.encrypt(
      myPriv,
      from,
      jsonEncode({
        'fireId': _fireId,
        'firePriv': _firePriv,
        'litBy': _litBy,
        'litAtMs': _litAtMs,
      }),
    );
    await messageService
        .sendBleSignal('fire_key', jsonEncode({'ct': ct}), toPubkeys: [from]);
  }

  Future<void> _onFireKey(String from, Map<String, dynamic> p) async {
    if (inFire || _joiningFireId == null) return;
    final myPriv = keyManager.privateKey;
    final ct = p['ct'] as String?;
    if (myPriv == null || ct == null) return;

    Map<String, dynamic> key;
    try {
      key = jsonDecode(await _nip44.decrypt(myPriv, from, ct))
          as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (key['fireId'] != _joiningFireId) return;

    _fireId = key['fireId'] as String;
    _firePriv = key['firePriv'] as String;
    _firePub = _keyApi.getPublicKey(_firePriv!);
    _litBy = key['litBy'] as String? ?? 'Someone';
    _litAtMs = (key['litAtMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    _participants.clear();
    _moments.clear();
    _seenMomentIds.clear();
    _pendingBurn = null;
    _touch(from, null);
    _peakCount = headcount;

    _moments.add(FireMoment(
      id: 'sys_joined',
      senderPubkey: '',
      senderName: '',
      body: 'You walked in — it burns when everyone leaves',
      system: true,
      tsMs: DateTime.now().millisecondsSinceEpoch,
    ));

    _nearbyFires.remove(_fireId);
    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(_beaconEvery, (_) => _sendBeacon());
    _sendBeacon();
    await messageService.sendBleSignal('fire_enter',
        jsonEncode({'fireId': _fireId, 'name': _myName}));

    _joinWaiter?.complete(true);
    _roomController.add(null);
    _radarController.add(null);
  }

  void _onEnter(String from, Map<String, dynamic> p) {
    if (!inFire || p['fireId'] != _fireId) return;
    final name = p['name'] as String? ?? 'Someone';
    final isNew = !_participants.containsKey(from);
    _touch(from, name);
    if (isNew) {
      _moments.add(FireMoment(
        id: 'sys_${from.substring(0, math.min(8, from.length))}_${DateTime.now().millisecondsSinceEpoch}',
        senderPubkey: '',
        senderName: '',
        body: '$name walked in 👋',
        system: true,
        tsMs: DateTime.now().millisecondsSinceEpoch,
      ));
      _roomController.add(null);
    }
  }

  Future<void> _onFireMsg(String from, Map<String, dynamic> p) async {
    if (!inFire || p['fireId'] != _fireId) return;
    final ct = p['ct'] as String?;
    if (ct == null) return;

    Map<String, dynamic> inner;
    try {
      inner = jsonDecode(await _nip44.decrypt(_firePriv!, _firePub!, ct))
          as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final mid = inner['mid'] as String? ?? '';
    if (mid.isEmpty || _seenMomentIds.contains(mid)) return;
    _seenMomentIds.add(mid);

    _touch(from, inner['name'] as String?);
    _moments.add(FireMoment(
      id: mid,
      senderPubkey: from,
      senderName: inner['name'] as String? ?? 'Someone',
      body: inner['body'] as String? ?? '',
      burnOnly: inner['burnOnly'] == true,
      tsMs: DateTime.now().millisecondsSinceEpoch,
    ));
    _roomController.add(null);
  }

  void _touch(String pubkey, String? name) {
    final existing = _participants[pubkey];
    _participants[pubkey] = _Participant(
      name: (name != null && name.isNotEmpty)
          ? name
          : existing?.name ?? 'Someone',
      lastSeen: DateTime.now(),
    );
    _peakCount = math.max(_peakCount, headcount);
  }

  // ── Housekeeping: flame expiry + presence → burn ─────────────────────────

  void _housekeep() {
    final now = DateTime.now();

    // Expire flames we haven't heard for a while.
    final before = _nearbyFires.length;
    _nearbyFires.removeWhere((_, f) => now.difference(f.lastSeen) > _flameExpiry);
    if (_nearbyFires.length != before) _radarController.add(null);

    if (!inFire) return;

    // Never joined: kindling window, then a silent death — being stood up
    // doesn't deserve a ceremony.
    if (_peakCount <= 1) {
      if (now.millisecondsSinceEpoch - _litAtMs >= kindling.inMilliseconds) {
        _dieSilently();
      }
      return;
    }

    // Active fire: everyone I knew has gone silent past the grace → burn.
    final othersAlive = _participants.values
        .any((pt) => now.difference(pt.lastSeen) <= grace);
    if (!othersAlive) _burn();
  }

  /// A fire that never had joiners goes out without a burn screen or
  /// ember picker — there was no night to keep.
  void _dieSilently() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _fireId = null;
    _firePriv = null;
    _firePub = null;
    _participants.clear();
    _moments.clear();
    _seenMomentIds.clear();
    _pendingBurn = null;
    _roomController.add(null);
    _radarController.add(null);
  }

  void _burn() {
    if (!inFire) return;
    final burned = BurnedFire(
      fireId: _fireId!,
      litBy: _litBy,
      litAtMs: _litAtMs,
      burnedAtMs: DateTime.now().millisecondsSinceEpoch,
      peakCount: _peakCount,
      moments: List.of(_moments),
    );
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _fireId = null;
    _firePriv = null;
    _firePub = null;
    _participants.clear();
    _moments.clear();
    _seenMomentIds.clear();
    _pendingBurn = burned;
    _burnController.add(burned);
    _roomController.add(null);
  }

  // ── Embers ────────────────────────────────────────────────────────────────

  /// Keep exactly one moment from a burned fire. Everything else stays ash.
  Future<void> keepEmber(BurnedFire fire, FireMoment m) async {
    await dbService.insertEmber({
      'id': m.id,
      'body': m.body,
      'senderName': m.senderName,
      'litBy': fire.litBy,
      'headcount': fire.peakCount,
      'litAt': fire.litAtMs,
      'burnedAt': fire.burnedAtMs,
    });
    _pendingBurn = null;
  }

  void letItAllBurn() => _pendingBurn = null;

  void dispose() {
    _beaconTimer?.cancel();
    _housekeepTimer?.cancel();
    _roomController.close();
    _radarController.close();
    _burnController.close();
  }
}

class _Participant {
  final String name;
  final DateTime lastSeen;
  _Participant({required this.name, required this.lastSeen});
}
