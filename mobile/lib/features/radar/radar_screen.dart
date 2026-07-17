import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/features/chat/screens/chat_screen.dart';
import 'package:bitchat_messenger/core/widgets/peer_avatar.dart';
import 'package:bitchat_messenger/features/campfire/screens/campfire_screen.dart';
import 'package:bitchat_messenger/features/campfire/services/campfire_service.dart';
import 'package:bitchat_messenger/features/contacts/screens/clink_screen.dart';
import 'package:share_plus/share_plus.dart';

/// The Radar — BitChat's signature screen.
///
/// You are the coral beacon at the center. People currently in Bluetooth
/// range appear as glowing dots in the inner band; people seen earlier
/// (BLE history) fade in the outer band. Rings are signal presence, not
/// meters. Works with zero internet — that's the point.
class RadarScreen extends StatefulWidget {
  final MessageService messageService;
  final CallService? callService;
  final CampfireService? campfireService;

  const RadarScreen({
    super.key,
    required this.messageService,
    this.callService,
    this.campfireService,
  });

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarPeer {
  final String pubkey;
  final String name;
  final bool live;
  final int? lastSeenMs; // only for history peers
  _RadarPeer({required this.pubkey, required this.name, required this.live, this.lastSeenMs});
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  Set<String> _nearby = {};
  List<Map<String, dynamic>> _history = [];
  Map<String, Contact> _contacts = {};
  StreamSubscription? _nearbySub;
  StreamSubscription? _fireRadarSub;
  StreamSubscription? _burnSub;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _nearby = Set.of(widget.messageService.nearbyUsers);
    _nearbySub = widget.messageService.nearbyChangedStream.listen((set) {
      if (!mounted) return;
      setState(() => _nearby = Set.of(set));
      _loadHistory();
    });
    _fireRadarSub = widget.campfireService?.radarUpdates.listen((_) {
      if (mounted) setState(() {});
    });
    _burnSub = widget.campfireService?.burns.listen((_) {
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Your campfire burned out 🔥'),
        action: SnackBarAction(
          label: 'Pick your ember',
          onPressed: _openFireRoom,
        ),
        duration: const Duration(seconds: 8),
      ));
    });
    _loadHistory();
    _loadContacts();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _nearbySub?.cancel();
    _fireRadarSub?.cancel();
    _burnSub?.cancel();
    super.dispose();
  }

  // ── Campfire ─────────────────────────────────────────────────────────────

  void _openFireRoom() {
    final fs = widget.campfireService;
    if (fs == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CampfireScreen(
          campfireService: fs,
          messageService: widget.messageService,
        ),
      ),
    );
  }

  Future<void> _onFirePressed() async {
    final fs = widget.campfireService;
    if (fs == null) return;
    if (fs.inFire || fs.pendingBurn != null) {
      _openFireRoom();
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, 24 + MediaQuery.of(ctx).viewPadding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🔥', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 10),
          const Text('Light a campfire?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'A room that exists while people are together — anyone in range '
            'sees the flame and can walk in. It burns when everyone leaves; '
            'nothing is saved.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: isDark ? AppColors.darkTextMuted : AppColors.textMuted),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Light it 🔥',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ),
    );
    if (confirmed != true || !mounted) return;
    final err = await fs.light();
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    _openFireRoom();
  }

  void _showFlameSheet(NearbyFire flame) {
    final fs = widget.campfireService;
    if (fs == null) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, 24 + MediaQuery.of(ctx).viewPadding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🔥', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 10),
          const Text('Campfire',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('lit by ${flame.litBy} · ${flame.count} around it',
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppColors.darkTextMuted : AppColors.textMuted)),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.coral.withAlpha(22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text('You\'re close enough to join',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.coral)),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Not now'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
                onPressed: () async {
                  Navigator.pop(ctx);
                  final ok = await fs.join(flame.fireId);
                  if (!mounted) return;
                  if (ok) {
                    _openFireRoom();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Couldn\'t reach the fire — walk a little closer and try again')));
                  }
                },
                child: const Text('Walk in',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _loadHistory() async {
    final rows = await widget.messageService.dbService.getBleHistory();
    if (mounted) setState(() => _history = rows);
  }

  Future<void> _loadContacts() async {
    final contacts = await widget.messageService.dbService.getContacts();
    if (mounted) {
      setState(() => _contacts = {for (final c in contacts) c.pubkey: c});
    }
  }

  String _nameFor(String pubkey, {String? fallback}) {
    final contact = _contacts[pubkey];
    if (contact?.name?.isNotEmpty == true) return contact!.name!;
    final ble = widget.messageService.nearbyDeviceNames[pubkey];
    final cleaned = ble?.replaceAll(RegExp(r'\s*#\d+$'), '').trim();
    if (cleaned != null && cleaned.isNotEmpty) return cleaned;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return '#${Contact.shortIdFor(pubkey)}';
  }

  List<_RadarPeer> _buildPeers() {
    final peers = <_RadarPeer>[];
    for (final pubkey in _nearby) {
      peers.add(_RadarPeer(pubkey: pubkey, name: _nameFor(pubkey), live: true));
    }
    // History peers: seen before, not in range now. Cap to keep the field calm.
    var added = 0;
    for (final row in _history) {
      final pubkey = row['pubkey'] as String? ?? '';
      if (pubkey.isEmpty || _nearby.contains(pubkey)) continue;
      peers.add(_RadarPeer(
        pubkey: pubkey,
        name: _nameFor(pubkey, fallback: row['displayName'] as String?),
        live: false,
        lastSeenMs: row['lastSeen'] as int?,
      ));
      if (++added >= 8) break;
    }
    return peers;
  }

  /// Position within a band: peers are spread evenly around the circle
  /// (golden-angle spacing, indexed per band) so dots never stack, with a
  /// small hash-based jitter so it doesn't look mechanical. No RSSI in v1 —
  /// the band conveys "in range vs seen earlier", not distance.
  Offset _positionFor(String pubkey, int indexInBand, int bandCount,
      Offset center, double bandRadius) {
    var h = 0;
    for (final unit in pubkey.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    final base = 2 * math.pi * indexInBand / math.max(bandCount, 1);
    final jitterA = ((h % 100) / 100 - 0.5) * (math.pi / math.max(bandCount, 3));
    // Start offset keeps the first dot away from 12 o'clock, where the
    // band labels (IN RANGE / SEEN EARLIER) live.
    final angle = base + jitterA - math.pi / 2 + 0.6;
    final jitterR = 0.85 + ((h >> 12) % 100) / 100 * 0.2; // 0.85–1.05
    final r = bandRadius * jitterR;
    return Offset(center.dx + r * math.cos(angle), center.dy + r * math.sin(angle));
  }

  String _agoLabel(int? ms) {
    if (ms == null) return 'seen earlier';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _openChat(String pubkey, String name) {
    final contact = _contacts[pubkey];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactPubkey: pubkey,
          contactName: name,
          contactProfilePictureUrl: contact?.profilePictureUrl,
          contactProfilePictureLocalPath: contact?.profilePictureLocalPath,
          messageService: widget.messageService,
          callService: widget.callService,
        ),
      ),
    ).then((_) => _loadContacts());
  }

  Future<void> _saveContact(String pubkey, String name) async {
    await widget.messageService.dbService.insertContact(
      Contact(pubkey: pubkey, name: name.startsWith('#') ? null : name),
    );
    widget.messageService.triggerContactsBackup();
    await _loadContacts();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$name saved to contacts')));
    }
  }

  void _showPeerCard(_RadarPeer peer) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isContact = _contacts.containsKey(peer.pubkey);
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  PeerAvatar(
                    name: peer.name,
                    localPath: _contacts[peer.pubkey]?.profilePictureLocalPath,
                    picUrl: _contacts[peer.pubkey]?.profilePictureUrl,
                    size: 48,
                    bgColor: peer.live ? AppColors.primary : AppColors.textMuted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(peer.name,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(
                          peer.live
                              ? '● in range · bluetooth'
                              : 'last seen ${_agoLabel(peer.lastSeenMs)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: peer.live ? AppColors.coral : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '#${Contact.shortIdFor(peer.pubkey)}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMuted, letterSpacing: 1),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openChat(peer.pubkey, peer.name);
                      },
                      child: const Text('Message'),
                    ),
                  ),
                  if (!isContact) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _saveContact(peer.pubkey, peer.name);
                        },
                        child: const Text('Save contact'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Search (find someone far away by name or short ID) ─────────────────

  void _showSearch() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppColors.darkCard
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _RadarSearchSheet(
        onOpen: (pubkey, name) {
          Navigator.pop(ctx);
          _openChat(pubkey, name);
        },
        onSave: (pubkey, name) => _saveContact(pubkey, name),
        isContact: (pubkey) => _contacts.containsKey(pubkey),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final peers = _buildPeers();
    final liveCount = _nearby.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Radar',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5)),
        actions: [
          if (widget.campfireService != null)
            IconButton(
              icon: Icon(
                (widget.campfireService!.inFire ||
                        widget.campfireService!.pendingBurn != null)
                    ? Icons.local_fire_department
                    : Icons.local_fire_department_outlined,
                size: 24,
                color: (widget.campfireService!.inFire ||
                        widget.campfireService!.pendingBurn != null)
                    ? AppColors.coral
                    : null,
              ),
              tooltip: widget.campfireService!.inFire
                  ? 'Back to your campfire'
                  : 'Light a campfire',
              onPressed: _onFirePressed,
            ),
          IconButton(
            icon: const Icon(Icons.smartphone, size: 22),
            tooltip: 'Clink — tap phones to swap contacts',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ClinkScreen(messageService: widget.messageService),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search, size: 24),
            tooltip: 'Find someone by name or ID',
            onPressed: _showSearch,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    liveCount == 0
                        ? 'No one in range — radar sees people nearby, no internet needed'
                        : '$liveCount ${liveCount == 1 ? 'person' : 'people'} in range · no internet needed',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: isDark ? AppColors.darkTextMuted : AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                final center = Offset(size.width / 2, size.height * 0.46);
                final bandLive = math.min(size.width, size.height) * 0.26;
                final bandHistory = math.min(size.width, size.height) * 0.42;

                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // Rings
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _RingsPainter(
                          center: center,
                          radii: [bandLive, bandHistory],
                          isDark: isDark,
                        ),
                      ),
                    ),
                    // Band labels
                    Positioned(
                      left: 0,
                      right: 0,
                      top: center.dy - bandLive - 18,
                      child: Center(
                        child: Text('IN RANGE',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w700,
                              color: (isDark ? AppColors.darkTextMuted : AppColors.textMuted)
                                  .withAlpha(160),
                            )),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: center.dy - bandHistory - 18,
                      child: Center(
                        child: Text('SEEN EARLIER',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w700,
                              color: (isDark ? AppColors.darkTextMuted : AppColors.textMuted)
                                  .withAlpha(110),
                            )),
                      ),
                    ),

                    // Center beacon (me) with pulse
                    Positioned(
                      left: center.dx - 40,
                      top: center.dy - 40,
                      width: 80,
                      height: 80,
                      child: AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, __) {
                          final t = _pulse.value;
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                width: 24 + 56 * t,
                                height: 24 + 56 * t,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColors.coral.withAlpha(((1 - t) * 130).round()),
                                    width: 2,
                                  ),
                                ),
                              ),
                              Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.coral,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.coral.withAlpha(140),
                                      blurRadius: 14,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    Positioned(
                      left: center.dx - 30,
                      top: center.dy + 24,
                      width: 60,
                      child: Center(
                        child: Text('YOU',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                              color: AppColors.coralSoft,
                            )),
                      ),
                    ),

                    // Peer dots — indexed per band for even spacing
                    ...() {
                      final livePeers = peers.where((p) => p.live).toList();
                      final histPeers = peers.where((p) => !p.live).toList();
                      final dots = <Widget>[];
                      for (var i = 0; i < livePeers.length; i++) {
                        dots.add(_buildPeerDot(
                          livePeers[i],
                          _positionFor(livePeers[i].pubkey, i,
                              livePeers.length, center, bandLive),
                          isDark,
                        ));
                      }
                      for (var i = 0; i < histPeers.length; i++) {
                        dots.add(_buildPeerDot(
                          histPeers[i],
                          _positionFor(histPeers[i].pubkey, i,
                              histPeers.length, center, bandHistory),
                          isDark,
                        ));
                      }
                      return dots;
                    }(),

                    // Campfire flames heard from people in range
                    ...() {
                      final fires =
                          widget.campfireService?.nearbyFires ?? const <NearbyFire>[];
                      final flames = <Widget>[];
                      for (var i = 0; i < fires.length && i < 2; i++) {
                        final f = fires[i];
                        final pos = _positionFor(
                            f.fireId, i, fires.length, center, bandLive * 0.62);
                        flames.add(Positioned(
                          left: pos.dx - 34,
                          top: pos.dy - 34,
                          width: 68,
                          child: GestureDetector(
                            onTap: () => _showFlameSheet(f),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                width: 46,
                                height: 46,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.coral.withAlpha(30),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.coral.withAlpha(70),
                                      blurRadius: 16,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: const Text('🔥',
                                    style: TextStyle(fontSize: 22)),
                              ),
                              const SizedBox(height: 2),
                              Text('Campfire · ${f.count}',
                                  style: const TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.coral)),
                            ]),
                          ),
                        ));
                      }
                      return flames;
                    }(),

                    // Empty state: give the screen a job — invite people.
                    if (peers.isEmpty)
                      Positioned(
                        left: 40,
                        right: 40,
                        bottom: 24,
                        child: Column(
                          children: [
                            Text(
                              'People running Reach appear here when they\'re nearby — same room, same street.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.5,
                                color: isDark
                                    ? AppColors.darkTextMuted
                                    : AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 14),
                            GestureDetector(
                              onTap: () {
                                final pubkey =
                                    widget.messageService.publicKey;
                                if (pubkey == null) return;
                                SharePlus.instance.share(ShareParams(
                                  text:
                                      'Find me on Reach — my ID is #${Contact.shortIdFor(pubkey)}',
                                ));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 11),
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  'Invite a friend',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerDot(_RadarPeer peer, Offset pos, bool isDark) {
    const dotSize = 44.0;
    final color = _dotColor(peer.pubkey);
    final contact = _contacts[peer.pubkey];
    return Positioned(
      left: pos.dx - dotSize / 2,
      top: pos.dy - dotSize / 2,
      child: GestureDetector(
        onTap: () => _showPeerCard(peer),
        child: Opacity(
          opacity: peer.live ? 1.0 : 0.45,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PeerAvatar(
                name: peer.name,
                localPath: contact?.profilePictureLocalPath,
                picUrl: contact?.profilePictureUrl,
                size: dotSize,
                bgColor: color,
                border: peer.live
                    ? Border.all(color: AppColors.coral, width: 2.5)
                    : Border.all(
                        color: (isDark ? AppColors.darkTextMuted : AppColors.textMuted)
                            .withAlpha(120),
                        width: 1.5),
                boxShadow: peer.live
                    ? [
                        BoxShadow(
                          color: AppColors.coral.withAlpha(90),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              const SizedBox(height: 3),
              Text(
                peer.name.length > 12 ? '${peer.name.substring(0, 11)}…' : peer.name,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Same palette + hash as chats/contacts so a person keeps one color everywhere.
  static const _dotPalette = [
    Color(0xFF3D5AFE), Color(0xFF00A8B5), Color(0xFFFF5C39),
    Color(0xFF7C4DFF), Color(0xFF0091EA), Color(0xFFFF8F00),
    Color(0xFF2E9E5B), Color(0xFFD81B60), Color(0xFF5C74FF),
    Color(0xFF00B8D4),
  ];

  Color _dotColor(String pubkey) {
    var h = 0;
    for (final unit in pubkey.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return _dotPalette[h % _dotPalette.length];
  }
}

class _RingsPainter extends CustomPainter {
  final Offset center;
  final List<double> radii;
  final bool isDark;
  _RingsPainter({required this.center, required this.radii, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final base = isDark ? AppColors.primaryDark : AppColors.primary;
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = base.withAlpha(isDark ? 55 : 40);
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = base.withAlpha(isDark ? 32 : 22);

    canvas.drawCircle(center, radii[0], inner);
    canvas.drawCircle(center, radii[1], outer);
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.center != center || old.radii != radii || old.isDark != isDark;
}

// ── Search sheet ────────────────────────────────────────────────────────────

class _RadarSearchSheet extends StatefulWidget {
  final void Function(String pubkey, String name) onOpen;
  final Future<void> Function(String pubkey, String name) onSave;
  final bool Function(String pubkey) isContact;

  const _RadarSearchSheet({
    required this.onOpen,
    required this.onSave,
    required this.isContact,
  });

  @override
  State<_RadarSearchSheet> createState() => _RadarSearchSheetState();
}

class _RadarSearchSheetState extends State<_RadarSearchSheet> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  bool _searched = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(value.trim()));
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      if (mounted) setState(() { _results = []; _searched = false; });
      return;
    }
    setState(() => _searching = true);

    List<Map<String, dynamic>> results = [];
    final digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 8) {
      final hit = await ServerService().lookupByShortId(digits);
      if (hit != null) results = [hit];
    } else {
      results = await ServerService().searchProfiles(query) ?? [];
    }

    if (mounted) {
      setState(() {
        _results = results;
        _searching = false;
        _searched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                decoration: const InputDecoration(
                  hintText: 'Name or 8-digit ID',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 8),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (_searched && _results.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No one found', style: TextStyle(color: AppColors.textMuted)),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final pubkey = r['pubkey'] as String? ?? '';
                      final name = (r['display_name'] as String?)?.trim();
                      final shortId = r['short_id'] as String? ??
                          (pubkey.isNotEmpty ? Contact.shortIdFor(pubkey) : '');
                      final label = (name?.isNotEmpty == true) ? name! : '#$shortId';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: AppColors.primary,
                          child: Text(
                            label.isNotEmpty ? label[0].toUpperCase() : '?',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                        ),
                        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('#$shortId',
                            style: const TextStyle(fontSize: 12, letterSpacing: 1)),
                        trailing: widget.isContact(pubkey)
                            ? null
                            : TextButton(
                                onPressed: pubkey.isEmpty
                                    ? null
                                    : () async {
                                        await widget.onSave(pubkey, label);
                                        if (mounted) setState(() {});
                                      },
                                child: const Text('Save'),
                              ),
                        onTap: pubkey.isEmpty ? null : () => widget.onOpen(pubkey, label),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
