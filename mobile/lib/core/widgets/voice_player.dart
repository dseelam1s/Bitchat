import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/material.dart';
import 'package:bitchat_messenger/core/theme.dart';

/// Inline voice-note player (play/pause + progress). Shared by DM, group
/// and campfire bubbles. [source] is 'local:<path>' or an https URL.
class VoicePlayer extends StatefulWidget {
  final String source;
  final String secsLabel;
  final bool light; // on a filled (outgoing) bubble → white controls
  final String timeLabel;
  const VoicePlayer({
    super.key,
    required this.source,
    required this.secsLabel,
    required this.light,
    required this.timeLabel,
  });

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final _player = ap.AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    final src = widget.source.startsWith('local:')
        ? ap.DeviceFileSource(widget.source.substring(6))
        : ap.UrlSource(widget.source);
    await _player.play(src);
    setState(() => _playing = true);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.light ? Colors.white : AppColors.primary;
    final track = widget.light
        ? Colors.white.withAlpha(90)
        : AppColors.primary.withAlpha(50);
    final totalSecs = _total.inSeconds > 0
        ? _total.inSeconds
        : int.tryParse(widget.secsLabel) ?? 0;
    final progress =
        totalSecs > 0 ? (_pos.inSeconds / totalSecs).clamp(0.0, 1.0) : 0.0;
    final label = _playing || _pos > Duration.zero
        ? '${(_pos.inSeconds ~/ 60)}:${(_pos.inSeconds % 60).toString().padLeft(2, '0')}'
        : '${(totalSecs ~/ 60)}:${(totalSecs % 60).toString().padLeft(2, '0')}';

    return SizedBox(
      width: 210,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Icon(
              _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              size: 38,
              color: fg,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: track,
                    valueColor: AlwaysStoppedAnimation(fg),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '🎤 $label · ${widget.timeLabel}',
                  style: TextStyle(
                    fontSize: 10,
                    color: widget.light
                        ? Colors.white.withAlpha(180)
                        : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
