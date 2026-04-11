import 'dart:convert';

class Contact {
  final String pubkey;
  final String? name;
  final bool isNearby;
  final int? lastSeen;
  // true = user manually set this name → never overwrite automatically
  // false = auto-populated from incoming message → update when sender changes name
  final bool isNameCustomized;
  final String? profilePictureUrl;
  // Local file path downloaded from profilePictureUrl — never purged by OS.
  // Preferred over URL when available so photos show offline.
  final String? profilePictureLocalPath;

  // Pending contact fields — pubkey not yet resolved
  final bool isPending;
  final String? savedShortId; // the Short ID the user saved (source of truth for pending)

  Contact({
    required this.pubkey,
    this.name,
    this.isNearby = false,
    this.lastSeen,
    this.isNameCustomized = false,
    this.profilePictureUrl,
    this.profilePictureLocalPath,
    this.isPending = false,
    this.savedShortId,
  });

  /// Factory for creating a pending contact from a Short ID only.
  /// Uses a placeholder pubkey so it can be stored in the DB.
  factory Contact.pending({
    required String shortId,
    String? name,
  }) {
    return Contact(
      pubkey: 'pending_$shortId',
      name: name,
      isPending: true,
      savedShortId: shortId,
      isNameCustomized: name != null && name.isNotEmpty,
    );
  }

  /// 8-digit short ID.
  /// For pending contacts, returns the savedShortId directly.
  /// For resolved contacts, derives it from the pubkey.
  String get shortId {
    if (isPending && savedShortId != null) return savedShortId!;
    return shortIdFor(pubkey);
  }

  /// Compute shortId for any pubkey string.
  static String shortIdFor(String pubkey) {
    if (pubkey.isEmpty || pubkey.startsWith('pending_')) return '00000000';
    // djb2 hash over UTF-8 bytes
    final bytes = utf8.encode(pubkey);
    int hash = 5381;
    for (final b in bytes) {
      hash = ((hash << 5) + hash + b) & 0xFFFFFFFF;
    }
    return (hash.abs() % 100000000).toString().padLeft(8, '0');
  }

  Map<String, dynamic> toMap() {
    return {
      'pubkey': pubkey,
      'name': name,
      'isNearby': isNearby ? 1 : 0,
      'lastSeen': lastSeen,
      'isNameCustomized': isNameCustomized ? 1 : 0,
      'profilePictureUrl': profilePictureUrl,
      'profilePictureLocalPath': profilePictureLocalPath,
      'isPending': isPending ? 1 : 0,
      'savedShortId': savedShortId,
    };
  }

  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      pubkey: map['pubkey'] as String? ?? '',
      name: map['name'] as String?,
      isNearby: map['isNearby'] == 1,
      lastSeen: map['lastSeen'] as int?,
      isNameCustomized: map['isNameCustomized'] == 1,
      profilePictureUrl: map['profilePictureUrl'] as String?,
      profilePictureLocalPath: map['profilePictureLocalPath'] as String?,
      isPending: map['isPending'] == 1,
      savedShortId: map['savedShortId'] as String?,
    );
  }

  Contact copyWith({
    String? name,
    bool? isNearby,
    int? lastSeen,
    bool? isNameCustomized,
    String? profilePictureUrl,
    String? profilePictureLocalPath,
    bool? isPending,
    String? savedShortId,
  }) {
    return Contact(
      pubkey: pubkey,
      name: name ?? this.name,
      isNearby: isNearby ?? this.isNearby,
      lastSeen: lastSeen ?? this.lastSeen,
      isNameCustomized: isNameCustomized ?? this.isNameCustomized,
      profilePictureUrl: profilePictureUrl ?? this.profilePictureUrl,
      profilePictureLocalPath: profilePictureLocalPath ?? this.profilePictureLocalPath,
      isPending: isPending ?? this.isPending,
      savedShortId: savedShortId ?? this.savedShortId,
    );
  }
}
