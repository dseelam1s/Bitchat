import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../../models/call_log.dart';
import '../nostr/nostr_service.dart';
import '../server/server_service.dart';
import '../server/signaling_service.dart';

enum CallState { idle, calling, ringing, connected, ended }
enum CallDirection { outgoing, incoming }

class CallSession {
  final String callId;
  final String remotePubkey;
  final String? remoteName;
  final CallDirection direction;
  final bool isVideo;
  CallState state;
  final DateTime startedAt;
  DateTime? connectedAt;

  CallSession({
    required this.callId,
    required this.remotePubkey,
    this.remoteName,
    required this.direction,
    required this.state,
    required this.startedAt,
    this.isVideo = false,
  });

  Duration? get duration {
    if (connectedAt == null) return null;
    return DateTime.now().difference(connectedAt!);
  }
}

class CallService {
  final NostrService _nostrService;
  final SignalingService _signalingService;
  final _uuid = const Uuid();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  CallSession? _currentCall;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isCameraOff = false;

  String? _myPubkey;

  final _callStateController = StreamController<CallSession?>.broadcast();
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();

  // Pending ICE candidates collected before remote description is set
  final List<RTCIceCandidate> _pendingCandidates = [];

  // Rate limiting: track last call offer time per remote pubkey
  final Map<String, DateTime> _lastCallOfferTime = {};

  // STUN servers — all free public servers, no account needed
  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ]
  };

  static Map<String, dynamic> _sdpConstraints({bool video = false}) => {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': video,
    },
    'optional': [],
  };

  CallService({
    required NostrService nostrService,
    required SignalingService signalingService,
  })  : _nostrService = nostrService,
        _signalingService = signalingService;

  Stream<CallSession?> get callStateStream => _callStateController.stream;
  Stream<MediaStream?> get remoteStreamStream => _remoteStreamController.stream;
  CallSession? get currentCall => _currentCall;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isCameraOff => _isCameraOff;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  bool get hasActiveCall => _currentCall != null &&
      (_currentCall!.state == CallState.calling ||
          _currentCall!.state == CallState.ringing ||
          _currentCall!.state == CallState.connected);

  /// Send a call signal. Tries WebSocket first; falls back to Nostr relay.
  Future<void> _sendSignal(String recipientPubkey, Map<String, dynamic> payload) async {
    // Add recipientPubkey so the server knows where to route it
    final withRecipient = {...payload, 'recipientPubkey': recipientPubkey};
    final sentViaWs = _signalingService.send(withRecipient);
    if (!sentViaWs) {
      // WebSocket not connected — fall back to Nostr relay
      await _nostrService.sendCallSignal(
        recipientPubkey: recipientPubkey,
        payload: payload,
      );
    }
  }

  /// Wired in main.dart to persist call logs to the database.
  void Function(CallLog log)? onCallLogged;

  void setMyPubkey(String pubkey) => _myPubkey = pubkey;

  // ── Outgoing call ────────────────────────────────────────────────────────

  Future<void> startCall(String remotePubkey, {String? remoteName, bool isVideo = false}) async {
    if (hasActiveCall) return; // already in a call
    if (_myPubkey != null && remotePubkey == _myPubkey) return; // can't call yourself

    final callId = _uuid.v4();
    _currentCall = CallSession(
      callId: callId,
      remotePubkey: remotePubkey,
      remoteName: remoteName,
      direction: CallDirection.outgoing,
      state: CallState.calling,
      startedAt: DateTime.now(),
      isVideo: isVideo,
    );
    _notifyState();

    await _setupPeerConnection();
    await _startLocalStream(isVideo: isVideo);

    // Create WebRTC offer
    final offer = await _peerConnection!.createOffer(_sdpConstraints(video: isVideo));
    await _peerConnection!.setLocalDescription(offer);

    // Send offer to remote — WebSocket first, Nostr fallback
    await _sendSignal(remotePubkey, {
      '__type': 'call_offer',
      'callId': callId,
      'sdp': offer.sdp,
      'sdpType': offer.type,
      'callerName': remoteName ?? '',
      'isVideo': isVideo,
    });

    // Push notification so receiver wakes up even if app is killed
    ServerService().notifyCall(
      recipientPubkey: remotePubkey,
      callerName: remoteName,
    );

    // Auto-timeout after 60 seconds if no answer
    Timer(const Duration(seconds: 60), () {
      if (_currentCall?.callId == callId &&
          _currentCall?.state == CallState.calling) {
        _endCallLocally(reason: 'no_answer');
      }
    });
  }

  // ── Incoming call ────────────────────────────────────────────────────────

  Future<void> handleIncomingOffer({
    required String callId,
    required String callerPubkey,
    required String? callerName,
    required String sdp,
    required String sdpType,
    bool isVideo = false,
  }) async {
    // Rate limit: ignore repeated offers from the same caller within 5 seconds
    // (prevents duplicate delivery spam, but allows quick re-dial)
    final lastOffer = _lastCallOfferTime[callerPubkey];
    if (lastOffer != null && DateTime.now().difference(lastOffer).inSeconds < 5) return;
    _lastCallOfferTime[callerPubkey] = DateTime.now();

    if (hasActiveCall) {
      // Already in a call — send busy signal
      await _sendSignal(callerPubkey, {'__type': 'call_busy', 'callId': callId});
      return;
    }

    _currentCall = CallSession(
      callId: callId,
      remotePubkey: callerPubkey,
      remoteName: callerName,
      direction: CallDirection.incoming,
      state: CallState.ringing,
      startedAt: DateTime.now(),
      isVideo: isVideo,
    );
    _notifyState();

    await _setupPeerConnection();
    await _startLocalStream(isVideo: isVideo);

    // Set remote description from offer
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, sdpType),
    );

    // Flush any ICE candidates that arrived before the offer
    for (final candidate in _pendingCandidates) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> acceptCall() async {
    final call = _currentCall;
    if (call == null || call.state != CallState.ringing) return;

    // Create answer
    final answer = await _peerConnection!.createAnswer(_sdpConstraints(video: call.isVideo));
    await _peerConnection!.setLocalDescription(answer);

    call.state = CallState.connected;
    call.connectedAt = DateTime.now();
    _notifyState();

    await _sendSignal(call.remotePubkey, {
      '__type': 'call_answer',
      'callId': call.callId,
      'sdp': answer.sdp,
      'sdpType': answer.type,
    });
  }

  Future<void> declineCall() async {
    final call = _currentCall;
    if (call == null) return;

    await _sendSignal(call.remotePubkey, {'__type': 'call_declined', 'callId': call.callId});
    await _endCallLocally(reason: 'declined');
  }

  // ── Handle signals from remote ───────────────────────────────────────────

  Future<void> handleCallAnswer({
    required String callId,
    required String sdp,
    required String sdpType,
  }) async {
    final call = _currentCall;
    if (call == null || call.callId != callId) return;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, sdpType),
    );

    for (final candidate in _pendingCandidates) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingCandidates.clear();

    call.state = CallState.connected;
    call.connectedAt = DateTime.now();
    _notifyState();
  }

  Future<void> handleIceCandidate({
    required String callId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
  }) async {
    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    if (_peerConnection != null &&
        _currentCall?.callId == callId &&
        await _peerConnection!.getRemoteDescription() != null) {
      await _peerConnection!.addCandidate(iceCandidate);
    } else {
      // Queue until remote description is set
      _pendingCandidates.add(iceCandidate);
    }
  }

  Future<void> handleCallEnded(String callId) async {
    if (_currentCall?.callId == callId) {
      await _endCallLocally(reason: 'remote_ended');
    }
  }

  Future<void> handleCallDeclined(String callId) async {
    if (_currentCall?.callId == callId) {
      await _endCallLocally(reason: 'declined');
    }
  }

  Future<void> handleCallBusy(String callId) async {
    if (_currentCall?.callId == callId) {
      await _endCallLocally(reason: 'busy');
    }
  }

  // ── Active call controls ─────────────────────────────────────────────────

  Future<void> endCall() async {
    final call = _currentCall;
    if (call == null) return;

    await _sendSignal(call.remotePubkey, {'__type': 'call_ended', 'callId': call.callId});
    await _endCallLocally(reason: 'local_ended');
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !_isMuted;
    });
    _notifyState();
  }

  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    MediaStreamTrack? audioTrack =
        _remoteStream?.getAudioTracks().isNotEmpty == true
            ? _remoteStream!.getAudioTracks().first
            : null;
    if (audioTrack != null) {
      Helper.setSpeakerphoneOn(_isSpeakerOn);
    }
    _notifyState();
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  Future<void> _setupPeerConnection() async {
    _peerConnection = await createPeerConnection(_iceServers);

    _peerConnection!.onIceCandidate = (candidate) async {
      final call = _currentCall;
      if (call == null) return;
      await _sendSignal(call.remotePubkey, {
        '__type': 'call_ice',
        'callId': call.callId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteStreamController.add(_remoteStream);
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _endCallLocally(reason: 'connection_failed');
      }
    };
  }

  Future<void> _startLocalStream({bool isVideo = false}) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': isVideo
          ? {'facingMode': 'user', 'width': {'ideal': 640}, 'height': {'ideal': 480}}
          : false,
    });

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }
  }

  void toggleCamera() {
    if (_currentCall?.isVideo != true) return;
    _isCameraOff = !_isCameraOff;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !_isCameraOff);
    _notifyState();
  }

  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  Future<void> _endCallLocally({required String reason}) async {
    final call = _currentCall;

    // Log the call before clearing state
    if (call != null && reason != 'disposed') {
      final status = _resolveStatus(call, reason);
      final duration = call.connectedAt != null
          ? DateTime.now().difference(call.connectedAt!).inSeconds
          : 0;
      onCallLogged?.call(CallLog(
        id: call.callId,
        remotePubkey: call.remotePubkey,
        remoteName: call.remoteName,
        direction: call.direction == CallDirection.incoming ? 'incoming' : 'outgoing',
        status: status,
        startedAt: call.startedAt.millisecondsSinceEpoch ~/ 1000,
        duration: duration,
      ));
    }

    _currentCall?.state = CallState.ended;
    _notifyState();

    await _peerConnection?.close();
    _peerConnection = null;

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    _remoteStream?.dispose();
    _remoteStream = null;
    _remoteStreamController.add(null);

    _pendingCandidates.clear();
    _isMuted = false;
    _isSpeakerOn = false;
    // Clear rate limit so a re-dial works immediately after a call ends
    if (call != null) _lastCallOfferTime.remove(call.remotePubkey);

    // Small delay so UI can show ended state, then clear
    await Future.delayed(const Duration(milliseconds: 500));
    _currentCall = null;
    _notifyState();
  }

  String _resolveStatus(CallSession call, String reason) {
    if (call.state == CallState.connected || reason == 'local_ended' || reason == 'remote_ended') {
      return 'answered';
    }
    if (reason == 'declined') return 'declined';
    if (reason == 'no_answer') return 'no_answer';
    if (call.direction == CallDirection.incoming) return 'missed';
    return 'no_answer';
  }

  void _notifyState() => _callStateController.add(_currentCall);

  Future<void> dispose() async {
    await _endCallLocally(reason: 'disposed');
    await _callStateController.close();
    await _remoteStreamController.close();
  }
}
