import 'dart:async';
import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/features/calls/services/call_service.dart';
import 'package:bitchat_messenger/features/calls/screens/in_call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  final CallSession session;
  final CallService callService;

  const IncomingCallScreen({
    super.key,
    required this.session,
    required this.callService,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  StreamSubscription? _callSub;
  Timer? _autoDeclineTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Listen for call state — if caller hangs up while ringing, dismiss
    _callSub = widget.callService.callStateStream.listen((session) {
      if (session == null || session.state == CallState.ended) {
        if (mounted) Navigator.of(context).pop();
      }
    });

    // Handle race: caller may have already hung up before this screen mounted
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = widget.callService.currentCall;
      if (current == null || current.state == CallState.ended) {
        Navigator.of(context).pop();
        return;
      }
      // Auto-decline after 45 seconds if user takes no action
      _autoDeclineTimer = Timer(const Duration(seconds: 45), () {
        if (mounted) _decline();
      });
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _callSub?.cancel();
    _autoDeclineTimer?.cancel();
    super.dispose();
  }

  Future<void> _accept() async {
    await widget.callService.acceptCall();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => InCallScreen(callService: widget.callService),
      ),
    );
  }

  Future<void> _decline() async {
    await widget.callService.declineCall();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.session.remoteName?.isNotEmpty == true
        ? widget.session.remoteName!
        : '#${Contact.shortIdFor(widget.session.remotePubkey)}';
    final name = raw.isNotEmpty ? raw : '?';
    final initial = name[0].toUpperCase();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),

            // Caller avatar with pulse
            ScaleTransition(
              scale: _pulseAnimation,
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.mint.withAlpha(20),
                  border: Border.all(color: AppColors.mint.withAlpha(80), width: 2),
                ),
                child: Center(
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mint,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            Text(
              name,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '#${Contact.shortIdFor(widget.session.remotePubkey)}',
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.mint,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.session.isVideo ? 'Incoming video call...' : 'Incoming voice call...',
              style: const TextStyle(fontSize: 14),
            ),

            const Spacer(flex: 3),

            // Accept / Decline buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Decline
                  _CallButton(
                    icon: Icons.call_end,
                    color: AppColors.error,
                    label: 'Decline',
                    onTap: _decline,
                  ),
                  // Accept
                  _CallButton(
                    icon: Icons.call,
                    color: AppColors.mint,
                    label: 'Accept',
                    onTap: _accept,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }
}
