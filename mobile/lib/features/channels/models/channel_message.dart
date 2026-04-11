class ChannelMessage {
  final String id;
  final String channelId;
  final String senderPubkey;
  final String senderName;
  final String content;
  final int timestamp; // unix seconds
  final int ttl;

  ChannelMessage({
    required this.id,
    required this.channelId,
    required this.senderPubkey,
    this.senderName = '',
    required this.content,
    required this.timestamp,
    this.ttl = 3,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'channelId': channelId,
      'senderPubkey': senderPubkey,
      'senderName': senderName,
      'content': content,
      'timestamp': timestamp,
      'ttl': ttl,
    };
  }

  factory ChannelMessage.fromMap(Map<String, dynamic> map) {
    return ChannelMessage(
      id: map['id'] as String? ?? '',
      channelId: map['channelId'] as String? ?? '',
      senderPubkey: map['senderPubkey'] as String? ?? '',
      senderName: map['senderName'] as String? ?? '',
      content: map['content'] as String? ?? '',
      timestamp: (map['timestamp'] as int?) ?? 0,
      ttl: (map['ttl'] as int?) ?? 3,
    );
  }

  ChannelMessage copyWith({int? ttl}) {
    return ChannelMessage(
      id: id,
      channelId: channelId,
      senderPubkey: senderPubkey,
      senderName: senderName,
      content: content,
      timestamp: timestamp,
      ttl: ttl ?? this.ttl,
    );
  }

  /// Convert to wire-format Message map for sending over mesh.
  /// Uses receiverPubkey = 'channel:[channelId]' for routing.
  Map<String, dynamic> toWireMap() {
    return {
      'id': id,
      'senderPubkey': senderPubkey,
      'receiverPubkey': 'channel:$channelId',
      'content': content,
      'type': 'channel_message',
      'timestamp': timestamp,
      'ttl': ttl,
      'status': 'sent',
      'transport': 'bitchat',
      'meshEncrypted': 0,
      'senderName': senderName,
    };
  }

  /// Parse from wire-format Message map received over mesh.
  factory ChannelMessage.fromWireMap(Map<String, dynamic> map) {
    final receiverPubkey = map['receiverPubkey'] as String? ?? '';
    final channelId = receiverPubkey.startsWith('channel:')
        ? receiverPubkey.substring(8)
        : '';
    return ChannelMessage(
      id: map['id'] as String? ?? '',
      channelId: channelId,
      senderPubkey: map['senderPubkey'] as String? ?? '',
      senderName: map['senderName'] as String? ?? '',
      content: map['content'] as String? ?? '',
      timestamp: (map['timestamp'] as int?) ?? 0,
      ttl: (map['ttl'] as int?) ?? 3,
    );
  }
}
