class Channel {
  final String id;
  final String name;
  final String creatorPubkey;
  final String creatorName;
  final int createdAt; // unix seconds
  final int lastActivityAt; // unix seconds — updated on each announcement or message
  final bool isDefault; // true for the "Nearby" channel
  final bool joined; // whether user has joined this channel
  final bool isPrivate; // true = invite-only private group
  final String adminPubkey; // pubkey of the group admin (creator for private groups)

  Channel({
    required this.id,
    required this.name,
    required this.creatorPubkey,
    this.creatorName = '',
    required this.createdAt,
    required this.lastActivityAt,
    this.isDefault = false,
    this.joined = false,
    this.isPrivate = false,
    this.adminPubkey = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'creatorPubkey': creatorPubkey,
      'creatorName': creatorName,
      'createdAt': createdAt,
      'lastActivityAt': lastActivityAt,
      'isDefault': isDefault ? 1 : 0,
      'joined': joined ? 1 : 0,
      'isPrivate': isPrivate ? 1 : 0,
      'adminPubkey': adminPubkey,
    };
  }

  factory Channel.fromMap(Map<String, dynamic> map) {
    return Channel(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      creatorPubkey: map['creatorPubkey'] as String? ?? '',
      creatorName: map['creatorName'] as String? ?? '',
      createdAt: (map['createdAt'] as int?) ?? 0,
      lastActivityAt: (map['lastActivityAt'] as int?) ?? 0,
      isDefault: map['isDefault'] == 1 || map['isDefault'] == true,
      joined: map['joined'] == 1 || map['joined'] == true,
      isPrivate: map['isPrivate'] == 1 || map['isPrivate'] == true,
      adminPubkey: map['adminPubkey'] as String? ?? '',
    );
  }

  Channel copyWith({
    String? name,
    String? creatorName,
    int? lastActivityAt,
    bool? joined,
    bool? isPrivate,
    String? adminPubkey,
  }) {
    return Channel(
      id: id,
      name: name ?? this.name,
      creatorPubkey: creatorPubkey,
      creatorName: creatorName ?? this.creatorName,
      createdAt: createdAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      isDefault: isDefault,
      joined: joined ?? this.joined,
      isPrivate: isPrivate ?? this.isPrivate,
      adminPubkey: adminPubkey ?? this.adminPubkey,
    );
  }

  /// Generate an invite link for this channel.
  String get inviteLink => 'bitchat://channel/$id/${Uri.encodeComponent(name)}';

  /// Parse a channel invite link. Returns {id, name} or null if invalid.
  static Map<String, String>? parseInviteLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'bitchat' || uri.host != 'channel') return null;
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    return {
      'id': segments[0],
      'name': Uri.decodeComponent(segments[1]),
    };
  }
}
