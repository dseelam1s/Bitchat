import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/core/widgets/peer_avatar.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/contacts/services/clink_service.dart';

/// The Clink — tap two phones together to swap contacts.
/// Both people open this screen; a physical tap (accelerometer jolt on both
/// sides + BLE packet) saves each other mutually. No QR, no IDs, no internet.
class ClinkScreen extends StatefulWidget {
  final MessageService messageService;
  const ClinkScreen({super.key, required this.messageService});

  @override
  State<ClinkScreen> createState() => _ClinkScreenState();
}

class _ClinkScreenState extends State<ClinkScreen>
    with SingleTickerProviderStateMixin {
  late final ClinkService _clink;
  late final AnimationController _ripple;
  StreamSubscription<ClinkMatch>? _matchSub;

  ClinkMatch? _match;
  bool _flash = false;
  int _undoLeft = 0;
  Timer? _undoTimer;

  @override
  void initState() {
    super.initState();
    _clink = ClinkService(
      messageService: widget.messageService,
      dbService: widget.messageService.dbService,
    );
    _ripple = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat();
    _matchSub = _clink.matches.listen(_onMatch);
    _clink.arm();
  }

  @override
  void dispose() {
    _undoTimer?.cancel();
    _matchSub?.cancel();
    _clink.dispose();
    _ripple.dispose();
    super.dispose();
  }

  void _onMatch(ClinkMatch m) {
    if (!mounted) return;
    setState(() {
      _match = m;
      _flash = true;
      _undoLeft = 5;
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _flash = false);
    });
    _undoTimer?.cancel();
    _undoTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _undoLeft = _undoLeft > 0 ? _undoLeft - 1 : 0);
      if (_undoLeft <= 0) t.cancel();
    });
  }

  Future<void> _undo() async {
    final m = _match;
    if (m == null) return;
    if (!m.wasAlreadyContact) await _clink.undo(m.pubkey);
    _undoTimer?.cancel();
    if (mounted) {
      setState(() => _match = null);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clink undone — contact removed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final myName = widget.messageService.username ?? '•';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clink',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5)),
      ),
      body: Stack(children: [
        if (_match == null) _waiting(isDark, myName) else _saved(isDark),
        // The clink! flash
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _flash ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: Container(
              color: AppColors.coral,
              alignment: Alignment.center,
              child: const Text('clink!',
                  style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -1)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _waiting(bool isDark, String myName) {
    final nearby = widget.messageService.nearbyUsers.length;
    return Column(children: [
      const Spacer(flex: 2),
      SizedBox(
        width: 220,
        height: 220,
        child: AnimatedBuilder(
          animation: _ripple,
          builder: (_, __) => Stack(alignment: Alignment.center, children: [
            for (var i = 0; i < 3; i++)
              _rippleRing((_ripple.value + i / 3) % 1.0),
            // Long-press = simulated tap (accessibility / broken sensor fallback)
            GestureDetector(
              onLongPress: _clink.simulateJolt,
              child: PeerAvatar(
                name: myName,
                picUrl: widget.messageService.profilePictureUrl,
                size: 96,
                bgColor: AppColors.primary,
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 28),
      const Text('Tap phones to swap',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text(
        'Hold them back to back and give a gentle tap —\nlike clinking glasses. Both of you get saved.',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: isDark ? AppColors.darkTextMuted : AppColors.textMuted),
      ),
      const Spacer(flex: 3),
      Padding(
        padding: const EdgeInsets.only(bottom: 28),
        child: Text(
          nearby == 0
              ? 'Waiting for someone in range…'
              : 'Bluetooth only — works with zero internet',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: nearby == 0
                  ? AppColors.coral
                  : (isDark ? AppColors.darkTextMuted : AppColors.textMuted)),
        ),
      ),
    ]);
  }

  Widget _rippleRing(double t) {
    return Container(
      width: 100 + 130 * t,
      height: 100 + 130 * t,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.primary.withAlpha(((1 - t) * 80).round()),
          width: 1.5,
        ),
      ),
    );
  }

  Widget _saved(bool isDark) {
    final m = _match!;
    return Column(children: [
      const Spacer(flex: 2),
      PeerAvatar(name: m.name, size: 92, bgColor: AppColors.amber),
      const SizedBox(height: 14),
      Text(m.name,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text('#${Contact.shortIdFor(m.pubkey)}',
          style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.5,
              color: isDark ? AppColors.darkTextMuted : AppColors.textMuted)),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.check_circle, color: Color(0xFF0FA47A), size: 18),
        const SizedBox(width: 6),
        Text(
            m.wasAlreadyContact
                ? 'Already in your contacts'
                : 'Saved to your contacts',
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0FA47A))),
      ]),
      const SizedBox(height: 10),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.coral.withAlpha(22),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('They got your card too — it\'s mutual, always',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.coral)),
      ),
      const Spacer(flex: 2),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => _match = null),
              child: const Text('Clink someone else'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ),
        ]),
      ),
      if (_undoLeft > 0 && !m.wasAlreadyContact)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: TextButton(
            onPressed: _undo,
            child: Text('Undo · $_undoLeft',
                style: const TextStyle(
                    color: AppColors.coral, fontWeight: FontWeight.w800)),
          ),
        )
      else
        const SizedBox(height: 40),
    ]);
  }
}
