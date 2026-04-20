class Message {
  final String id;
  final String senderPubkey;
  final String receiverPubkey;
  final String content;
  final String type;
  final int timestamp;
  final int ttl;
  final String status; // pending, sent, delivered, read, failed
  final String transport; // server, bitchat
  final bool meshEncrypted; // true if content is NIP-04 encrypted for mesh
  final String? senderName; // display name of the sender

  Message({
    required this.id,
    required this.senderPubkey,
    required this.receiverPubkey,
    required this.content,
    this.type = 'text',
    required this.timestamp,
    this.ttl = 5,
    this.status = 'pending',
    this.transport = 'server',
    this.meshEncrypted = false,
    this.senderName,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderPubkey': senderPubkey,
      'receiverPubkey': receiverPubkey,
      'content': content,
      'type': type,
      'timestamp': timestamp,
      'ttl': ttl,
      'status': status,
      'transport': transport,
      'meshEncrypted': meshEncrypted ? 1 : 0,
      'senderName': senderName,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String? ?? '',
      senderPubkey: map['senderPubkey'] as String? ?? '',
      receiverPubkey: map['receiverPubkey'] as String? ?? '',
      content: map['content'] as String? ?? '',
      type: (map['type'] as String?) ?? 'text',
      timestamp: (map['timestamp'] as int?) ?? 0,
      ttl: (map['ttl'] as int?) ?? 5,
      status: map['status'] ?? 'pending',
      transport: map['transport'] ?? 'server',
      meshEncrypted: map['meshEncrypted'] == 1 || map['meshEncrypted'] == true,
      senderName: map['senderName'],
    );
  }

  Message copyWith({
    String? content,
    String? status,
    String? transport,
    int? ttl,
    bool? meshEncrypted,
    String? senderName,
  }) {
    return Message(
      id: id,
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      content: content ?? this.content,
      type: type,
      timestamp: timestamp,
      ttl: ttl ?? this.ttl,
      status: status ?? this.status,
      transport: transport ?? this.transport,
      meshEncrypted: meshEncrypted ?? this.meshEncrypted,
      senderName: senderName ?? this.senderName,
    );
  }
}
