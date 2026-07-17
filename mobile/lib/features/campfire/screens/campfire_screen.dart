import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/campfire/services/campfire_service.dart';
import 'package:bitchat_messenger/features/chat/services/message_service.dart';
import 'package:bitchat_messenger/features/contacts/screens/clink_screen.dart';

/// The Campfire room — an ephemeral space that exists while people are
/// physically together and burns when they part. Nothing here is ever
/// written to disk; when the fire burns out this screen becomes the
/// ember picker.
class CampfireScreen extends StatefulWidget {
  final CampfireService campfireService;
  final MessageService messageService;
  const CampfireScreen({
    super.key,
    required this.campfireService,
    required this.messageService,
  });

  @override
  State<CampfireScreen> createState() => _CampfireScreenState();
}

class _CampfireScreenState extends State<CampfireScreen> {
  final _textController = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription? _roomSub;
  StreamSubscription? _burnSub;
  bool _burnOnly = false;
  BurnedFire? _burned;
  FireMoment? _pickedEmber;
  bool _emberKept = false;

  CampfireService get fire => widget.campfireService;

  @override
  void initState() {
    super.initState();
    _burned = fire.pendingBurn;
    _roomSub = fire.roomUpdates.listen((_) {
      if (!mounted) return;
      setState(() {});
      _autoscroll();
    });
    _burnSub = fire.burns.listen((b) {
      if (!mounted) return;
      setState(() => _burned = b);
    });
  }

  @override
  void dispose() {
    _roomSub?.cancel();
    _burnSub?.cancel();
    _textController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _autoscroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    fire.sendMoment(text, burnOnly: _burnOnly);
    _textController.clear();
    setState(() => _burnOnly = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_burned != null) return _burnView(context);
    if (!fire.inFire) {
      // Fire gone and nothing pending — burned or went out unjoined.
      return Scaffold(
        appBar: AppBar(title: const Text('Campfire')),
        body: const Center(
            child: Text('The fire went out 🌙',
                style: TextStyle(fontSize: 15))),
      );
    }
    return _roomView(context);
  }

  // ── The room ─────────────────────────────────────────────────────────────

  Widget _roomView(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final moments = fire.moments;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          const Text('🔥', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Campfire',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            Text('${fire.headcount} around the fire · lit by ${fire.litBy}',
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.coral)),
          ]),
        ]),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: AppColors.coral.withAlpha(22),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: const Text(
            '🔥 Burns when everyone leaves — nothing is saved',
            style: TextStyle(fontSize: 11.5, color: AppColors.coral),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            itemCount: moments.length,
            itemBuilder: (_, i) => _momentBubble(moments[i], isDark),
          ),
        ),
        _composer(isDark),
      ]),
    );
  }

  Widget _momentBubble(FireMoment m, bool isDark) {
    if (m.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.surface,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(m.body,
              style: TextStyle(
                  fontSize: 10.5,
                  color: isDark ? AppColors.darkTextMuted : AppColors.textMuted)),
        ),
      );
    }
    final mine = m.senderPubkey == widget.messageService.publicKey;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: mine
              ? AppColors.primary
              : (isDark ? AppColors.darkCard : AppColors.card),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mine)
              Text(m.senderName,
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.coral)),
            Text(m.body,
                style: TextStyle(
                    fontSize: 14,
                    color: mine
                        ? Colors.white
                        : (isDark ? AppColors.darkTextPrimary : AppColors.textPrimary))),
            if (m.burnOnly)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('🔥 burns with the fire',
                    style: TextStyle(
                        fontSize: 9.5,
                        color: mine
                            ? Colors.white70
                            : (isDark
                                ? AppColors.darkTextMuted
                                : AppColors.textMuted))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _composer(bool isDark) {
    return Container(
      color: isDark ? AppColors.darkSurface : Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_burnOnly)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('🔥 This one burns with the fire — nobody can keep it',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.coral)),
            ),
          Row(children: [
            IconButton(
              onPressed: () => setState(() => _burnOnly = !_burnOnly),
              tooltip: 'Burns with the fire (can\'t be kept)',
              icon: Icon(
                _burnOnly
                    ? Icons.local_fire_department
                    : Icons.local_fire_department_outlined,
                color: _burnOnly
                    ? AppColors.coral
                    : (isDark ? AppColors.darkTextMuted : AppColors.textMuted),
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkInputBg : AppColors.inputBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _textController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Say it to the fire…',
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _send,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    color: AppColors.coral, shape: BoxShape.circle),
                child:
                    const Icon(Icons.send_rounded, color: Colors.white, size: 22),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  // ── The burn + ember pick ────────────────────────────────────────────────

  Widget _burnView(BuildContext context) {
    final b = _burned!;
    final keepable = b.keepable;
    final mins = b.duration.inMinutes;
    final gifted = 0; // photos/gifts land in a later version

    return Scaffold(
      backgroundColor: const Color(0xFF14183C),
      body: SafeArea(
        child: Column(children: [
          const Spacer(flex: 2),
          const Text('🔥', style: TextStyle(fontSize: 52)),
          const SizedBox(height: 12),
          const Text('The campfire burned out',
              style: TextStyle(
                  fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 8),
          Text(
            '${mins < 1 ? 'a few moments' : '$mins min'} · ${b.peakCount} ${b.peakCount == 1 ? 'person' : 'people'} · ${b.moments.where((m) => !m.system).length} moments'
            '${gifted > 0 ? '\n$gifted gifted to everyone' : ''}\nAll of it is gone — except one thing you choose.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 12.5, height: 1.6, color: Color(0xFF9AA3C8)),
          ),
          const Spacer(),
          if (!_emberKept && keepable.isNotEmpty) ...[
            const Text('KEEP ONE EMBER',
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF8A6E))),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: keepable.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final m = keepable[i];
                  final picked = _pickedEmber?.id == m.id;
                  return GestureDetector(
                    onTap: () => setState(() => _pickedEmber = m),
                    child: Container(
                      width: 150,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1D2247),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: picked
                              ? AppColors.coral
                              : const Color(0xFF2B3055),
                          width: picked ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.senderName,
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFFF8A6E))),
                          const SizedBox(height: 4),
                          Expanded(
                            child: Text(m.body,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.coral,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: _pickedEmber == null
                      ? null
                      : () async {
                          await fire.keepEmber(b, _pickedEmber!);
                          if (mounted) setState(() => _emberKept = true);
                        },
                  child: const Text('Keep this ember',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                fire.letItAllBurn();
                Navigator.pop(context);
              },
              child: const Text('or let it all burn ›',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9AA3C8))),
            ),
          ] else ...[
            if (_emberKept) ...[
              const Icon(Icons.check_circle, color: Color(0xFFFF8A6E), size: 30),
              const SizedBox(height: 8),
              const Text('Kept. Find it on your Ember shelf.',
                  style: TextStyle(fontSize: 13, color: Colors.white)),
              const SizedBox(height: 18),
            ] else
              const Padding(
                padding: EdgeInsets.only(bottom: 18),
                child: Text('Nothing was keepable — the whole night was ash 🌙',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF9AA3C8))),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF2B3055))),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ClinkScreen(
                              messageService: widget.messageService),
                        ),
                      );
                    },
                    icon: const Text('🥂', style: TextStyle(fontSize: 15)),
                    label: const Text('Clink someone'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      fire.letItAllBurn();
                      Navigator.pop(context);
                    },
                    child: const Text('Done'),
                  ),
                ),
              ]),
            ),
          ],
          const Spacer(flex: 2),
        ]),
      ),
    );
  }
}
