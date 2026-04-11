import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../core/theme.dart';
import '../../models/contact.dart';
import '../../services/call/call_service.dart';

class InCallScreen extends StatefulWidget {
  final CallService callService;

  const InCallScreen({super.key, required this.callService});

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  StreamSubscription? _callSub;
  StreamSubscription? _remoteStreamSub;
  Timer? _durationTimer;
  Duration _elapsed = Duration.zero;

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersInit = false;

  @override
  void initState() {
    super.initState();

    _callSub = widget.callService.callStateStream.listen((session) {
      if (!mounted) return;
      if (session == null || session.state == CallState.ended) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {});
    });

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final call = widget.callService.currentCall;
      if (call?.connectedAt != null) {
        setState(() {
          _elapsed = DateTime.now().difference(call!.connectedAt!);
        });
      }
    });

    final call = widget.callService.currentCall;
    if (call?.isVideo == true) {
      _initRenderers();
    }
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _renderersInit = true;

    _localRenderer.srcObject = widget.callService.localStream;

    // If remote stream is already available
    final remote = widget.callService.remoteStream;
    if (remote != null) {
      _remoteRenderer.srcObject = remote;
    }

    // Listen for remote stream arriving after init
    _remoteStreamSub = widget.callService.remoteStreamStream.listen((stream) {
      if (!mounted) return;
      _remoteRenderer.srcObject = stream;
      setState(() {});
    });

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _remoteStreamSub?.cancel();
    _durationTimer?.cancel();
    if (_renderersInit) {
      _localRenderer.dispose();
      _remoteRenderer.dispose();
    }
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.callService.currentCall;
    if (call == null) return const SizedBox.shrink();

    if (call.isVideo) return _buildVideoCall(call);
    return _buildVoiceCall(call);
  }

  // ── Video call layout ────────────────────────────────────────────────────

  Widget _buildVideoCall(CallSession call) {
    final isConnected = call.state == CallState.connected;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Remote video — full screen
            if (_renderersInit)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              const Positioned.fill(
                child: ColoredBox(color: Colors.black),
              ),

            // Local video — picture-in-picture top-right
            if (_renderersInit && !widget.callService.isCameraOff)
              Positioned(
                top: 16,
                right: 16,
                width: 100,
                height: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),

            // Top bar: name + duration
            Positioned(
              top: 16,
              left: 16,
              right: 130,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    call.remoteName?.isNotEmpty == true
                        ? call.remoteName!
                        : '#${Contact.shortIdFor(call.remotePubkey)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isConnected
                        ? _formatDuration(_elapsed)
                        : call.direction == CallDirection.outgoing
                            ? 'Calling...'
                            : 'Connecting...',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom controls
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Mute
                  _VideoControlButton(
                    icon: widget.callService.isMuted ? Icons.mic_off : Icons.mic,
                    active: widget.callService.isMuted,
                    label: widget.callService.isMuted ? 'Unmute' : 'Mute',
                    onTap: () {
                      widget.callService.toggleMute();
                      setState(() {});
                    },
                  ),
                  // Camera on/off
                  _VideoControlButton(
                    icon: widget.callService.isCameraOff
                        ? Icons.videocam_off
                        : Icons.videocam,
                    active: widget.callService.isCameraOff,
                    label: widget.callService.isCameraOff ? 'Show cam' : 'Hide cam',
                    onTap: () {
                      widget.callService.toggleCamera();
                      setState(() {});
                    },
                  ),
                  // Flip camera
                  _VideoControlButton(
                    icon: Icons.flip_camera_ios,
                    active: false,
                    label: 'Flip',
                    onTap: () => widget.callService.switchCamera(),
                  ),
                  // End call
                  _VideoControlButton(
                    icon: Icons.call_end,
                    active: true,
                    activeColor: AppColors.error,
                    label: 'End',
                    onTap: () => widget.callService.endCall(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Voice call layout ────────────────────────────────────────────────────

  Widget _buildVoiceCall(CallSession call) {
    final raw = call.remoteName?.isNotEmpty == true
        ? call.remoteName!
        : '#${Contact.shortIdFor(call.remotePubkey)}';
    final name = raw.isNotEmpty ? raw : '?';
    final initial = name[0].toUpperCase();
    final isConnected = call.state == CallState.connected;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),

            // Avatar
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.mint.withAlpha(20),
                border: Border.all(color: AppColors.mint.withAlpha(60), width: 2),
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w600,
                    color: AppColors.mint,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            Text(
              name,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '#${Contact.shortIdFor(call.remotePubkey)}',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.mint,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 16),

            Text(
              isConnected
                  ? _formatDuration(_elapsed)
                  : call.direction == CallDirection.outgoing
                      ? 'Calling...'
                      : 'Connecting...',
              style: TextStyle(
                fontSize: 16,
                color: isConnected ? AppColors.mint : null,
                fontWeight: isConnected ? FontWeight.w600 : FontWeight.normal,
                letterSpacing: isConnected ? 1.5 : 0,
              ),
            ),

            const Spacer(),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ControlButton(
                    icon: widget.callService.isMuted ? Icons.mic_off : Icons.mic,
                    label: widget.callService.isMuted ? 'Unmute' : 'Mute',
                    active: widget.callService.isMuted,
                    activeColor: AppColors.amber,
                    onTap: () {
                      widget.callService.toggleMute();
                      setState(() {});
                    },
                  ),
                  _ControlButton(
                    icon: widget.callService.isSpeakerOn
                        ? Icons.volume_up
                        : Icons.volume_down,
                    label: 'Speaker',
                    active: widget.callService.isSpeakerOn,
                    activeColor: AppColors.blue,
                    onTap: () {
                      widget.callService.toggleSpeaker();
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 40),

            GestureDetector(
              onTap: () => widget.callService.endCall(),
              child: Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.error,
                ),
                child: const Icon(Icons.call_end, color: Colors.white, size: 32),
              ),
            ),
            const SizedBox(height: 8),
            const Text('End', style: TextStyle(fontSize: 13)),

            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }
}

// ── Control buttons ──────────────────────────────────────────────────────────

class _VideoControlButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final String label;
  final VoidCallback onTap;

  const _VideoControlButton({
    required this.icon,
    required this.active,
    this.activeColor = AppColors.amber,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active ? activeColor : Colors.white.withAlpha(30);
    final iconColor = active ? Colors.white : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : Theme.of(context).colorScheme.onSurface.withAlpha(150);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? activeColor.withAlpha(20) : AppColors.card,
              border: Border.all(
                color: active ? activeColor.withAlpha(80) : AppColors.divider,
              ),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}
