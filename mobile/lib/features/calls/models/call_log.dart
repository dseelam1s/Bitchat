class CallLog {
  final String id;
  final String remotePubkey;
  final String? remoteName;
  final String direction; // 'incoming' | 'outgoing'
  final String status;    // 'answered' | 'missed' | 'declined' | 'no_answer'
  final int startedAt;    // unix timestamp (seconds)
  final int duration;     // seconds (0 if not answered)

  const CallLog({
    required this.id,
    required this.remotePubkey,
    this.remoteName,
    required this.direction,
    required this.status,
    required this.startedAt,
    required this.duration,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'remotePubkey': remotePubkey,
        'remoteName': remoteName,
        'direction': direction,
        'status': status,
        'startedAt': startedAt,
        'duration': duration,
      };

  factory CallLog.fromMap(Map<String, dynamic> m) => CallLog(
        id: m['id'] as String,
        remotePubkey: m['remotePubkey'] as String,
        remoteName: m['remoteName'] as String?,
        direction: m['direction'] as String,
        status: m['status'] as String,
        startedAt: m['startedAt'] as int,
        duration: m['duration'] as int,
      );

  bool get isIncoming => direction == 'incoming';
  bool get isAnswered => status == 'answered';
  bool get isMissed => status == 'missed';
}
