import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// Handles voice note recording, storage, and playback.
///
/// Recording uses AAC codec at low bitrate (~16kbps) to keep files small.
/// A 30-second note ≈ 60KB; a 60-second note ≈ 120KB — acceptable for
/// Nearby Connections (Wi-Fi P2P) transfer.
class VoiceNoteService {
  static const int maxDurationSeconds = 60;

  final _recorder = AudioRecorder();
  final _uuid = const Uuid();

  String? _currentRecordingPath;
  DateTime? _recordingStarted;
  Timer? _maxDurationTimer;

  // Called when max duration is reached — UI should stop recording
  VoidCallback? onMaxDurationReached;

  bool get isRecording => _currentRecordingPath != null;

  // ── Recording ──────────────────────────────────────────────────────────────

  /// Start recording. Returns false if microphone permission is denied.
  Future<bool> startRecording() async {
    if (isRecording) return false;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return false;

    final dir = await _voiceNoteDir();
    final id = _uuid.v4();
    final path = '${dir.path}/$id.m4a';

    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 16000, // 16kbps — ~2KB/s
        sampleRate: 16000,
      ),
      path: path,
    );

    _currentRecordingPath = path;
    _recordingStarted = DateTime.now();

    // Auto-stop at max duration
    _maxDurationTimer = Timer(
      const Duration(seconds: maxDurationSeconds),
      () => onMaxDurationReached?.call(),
    );

    return true;
  }

  /// Stop recording. Returns the file path and duration, or null on failure.
  Future<({String path, int duration})?> stopRecording() async {
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;

    final path = _currentRecordingPath;
    final started = _recordingStarted;
    _currentRecordingPath = null;
    _recordingStarted = null;

    if (path == null || started == null) return null;

    await _recorder.stop();

    final file = File(path);
    if (!await file.exists()) return null;

    final duration = DateTime.now().difference(started).inSeconds.clamp(1, maxDurationSeconds);
    return (path: path, duration: duration);
  }

  /// Cancel recording without saving.
  Future<void> cancelRecording() async {
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;
    final path = _currentRecordingPath;
    _currentRecordingPath = null;
    _recordingStarted = null;
    await _recorder.cancel();
    if (path != null) {
      try { await File(path).delete(); } catch (_) {}
    }
  }

  // ── Storage ────────────────────────────────────────────────────────────────

  /// Save raw audio bytes (received over mesh) to the voice notes directory.
  /// Returns the local file path.
  Future<String> saveBytesToFile(String messageId, List<int> bytes) async {
    final dir = await _voiceNoteDir();
    final path = '${dir.path}/$messageId.m4a';
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Returns the local path for a voice note by message ID, or null if not found.
  Future<String?> localPath(String messageId) async {
    final dir = await _voiceNoteDir();
    final file = File('${dir.path}/$messageId.m4a');
    return await file.exists() ? file.path : null;
  }

  /// Delete a voice note file by message ID.
  Future<void> deleteFile(String messageId) async {
    final dir = await _voiceNoteDir();
    try { await File('${dir.path}/$messageId.m4a').delete(); } catch (_) {}
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  /// Encode a voice note file to base64 for mesh transport.
  Future<String?> encodeToBase64(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Download a voice note from [url] and save to the voice notes directory.
  /// Returns the local file path on success, null on failure.
  Future<String?> downloadFromUrl(String messageId, String url) async {
    try {
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) return null;
      return await saveBytesToFile(messageId, response.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  /// Decode base64 voice data and save to file. Returns the local path.
  Future<String?> decodeFromBase64(String messageId, String base64Data) async {
    try {
      final bytes = base64Decode(base64Data);
      return await saveBytesToFile(messageId, bytes);
    } catch (_) {
      return null;
    }
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  /// Create a new AudioPlayer for the given file path.
  /// Caller is responsible for disposing the player.
  Future<AudioPlayer?> createPlayer(String filePath) async {
    try {
      final player = AudioPlayer();
      await player.setFilePath(filePath);
      return player;
    } catch (_) {
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Directory> _voiceNoteDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/voice_notes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  void dispose() {
    _maxDurationTimer?.cancel();
    _recorder.dispose();
  }
}
