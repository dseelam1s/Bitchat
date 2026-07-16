import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:bitchat_messenger/features/calls/models/call_log.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';

class DatabaseService {
  static Database? _database;
  static Completer<Database>? _initCompleter;

  // Store-and-forward limits
  static const int maxRelayMessages = 100;
  static const int relayExpiryHours = 24;

  Future<Database> get database async {
    if (_database != null) return _database!;
    if (_initCompleter == null) {
      _initCompleter = Completer<Database>();
      _initCompleter!.complete(_initDB());
    }
    _database = await _initCompleter!.future;
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'bitchat.db');

    return await openDatabase(
      path,
      version: 16,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        senderPubkey TEXT NOT NULL,
        receiverPubkey TEXT NOT NULL,
        content TEXT NOT NULL,
        type TEXT DEFAULT 'text',
        timestamp INTEGER NOT NULL,
        ttl INTEGER DEFAULT 5,
        status TEXT DEFAULT 'pending',
        transport TEXT DEFAULT 'nostr',
        meshEncrypted INTEGER DEFAULT 0,
        senderName TEXT,
        duration INTEGER DEFAULT 0,
        replyToId TEXT,
        replySnippet TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_chat ON messages(senderPubkey, receiverPubkey, timestamp)
    ''');
    await db.execute('''
      CREATE INDEX idx_messages_status ON messages(status, type)
    ''');

    await db.execute('''
      CREATE TABLE contacts (
        pubkey TEXT PRIMARY KEY,
        name TEXT,
        isNearby INTEGER DEFAULT 0,
        lastSeen INTEGER,
        isNameCustomized INTEGER DEFAULT 0,
        profilePictureUrl TEXT,
        profilePictureLocalPath TEXT,
        isPending INTEGER DEFAULT 0,
        savedShortId TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE message_queue (
        id TEXT PRIMARY KEY,
        messageId TEXT NOT NULL,
        retryCount INTEGER DEFAULT 0,
        nextRetry INTEGER NOT NULL,
        FOREIGN KEY (messageId) REFERENCES messages(id)
      )
    ''');

    await _createRelayStore(db);
    await _createChannelTables(db);
    await _createCallLogsTable(db);
    await _createBleHistoryTable(db);
  }

  Future<void> _createBleHistoryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ble_history (
        pubkey TEXT PRIMARY KEY,
        displayName TEXT,
        lastSeen INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createCallLogsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS call_logs (
        id TEXT PRIMARY KEY,
        remotePubkey TEXT NOT NULL,
        remoteName TEXT,
        direction TEXT NOT NULL,
        status TEXT NOT NULL,
        startedAt INTEGER NOT NULL,
        duration INTEGER DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_call_logs_time ON call_logs(startedAt DESC)
    ''');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createRelayStore(db);
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE messages ADD COLUMN meshEncrypted INTEGER DEFAULT 0');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE messages ADD COLUMN senderName TEXT');
    }
    if (oldVersion < 5) {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(senderPubkey, receiverPubkey, timestamp)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status, type)');
    }
    if (oldVersion < 6) {
      await _createChannelTables(db);
    }
    if (oldVersion < 7) {
      // Only add 'joined' column if it doesn't already exist
      // (v6 CREATE TABLE already includes it for fresh installs)
      final cols = await db.rawQuery('PRAGMA table_info(channels)');
      final hasJoined = cols.any((c) => c['name'] == 'joined');
      if (!hasJoined) {
        await db.execute('ALTER TABLE channels ADD COLUMN joined INTEGER DEFAULT 0');
      }
    }
    if (oldVersion < 8) {
      await db.execute(
          'ALTER TABLE contacts ADD COLUMN isNameCustomized INTEGER DEFAULT 0');
    }
    if (oldVersion < 9) {
      await db.execute(
          'ALTER TABLE contacts ADD COLUMN profilePictureUrl TEXT');
    }
    if (oldVersion < 10) {
      await db.execute('ALTER TABLE channels ADD COLUMN isPrivate INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE channels ADD COLUMN adminPubkey TEXT DEFAULT \'\'');
      // group_members is created here for users upgrading from v6-v9 who never ran
      // _createChannelTables. Fresh installs get it from _createChannelTables directly.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS group_members (
          channelId TEXT NOT NULL,
          pubkey TEXT NOT NULL,
          displayName TEXT DEFAULT '',
          shortId TEXT DEFAULT '',
          addedAt INTEGER NOT NULL,
          PRIMARY KEY (channelId, pubkey)
        )
      ''');
    }
    if (oldVersion < 11) {
      await _createCallLogsTable(db);
    }
    if (oldVersion < 12) {
      await db.execute('ALTER TABLE contacts ADD COLUMN isPending INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE contacts ADD COLUMN savedShortId TEXT');
    }
    if (oldVersion < 13) {
      await db.execute('ALTER TABLE messages ADD COLUMN duration INTEGER DEFAULT 0');
    }
    if (oldVersion < 14) {
      await db.execute('ALTER TABLE contacts ADD COLUMN profilePictureLocalPath TEXT');
    }
    if (oldVersion < 15) {
      await _createBleHistoryTable(db);
    }
    if (oldVersion < 16) {
      // Reply-quoting + reactions (reaction rows point at the original
      // message via replyToId, with the emoji as content).
      await db.execute('ALTER TABLE messages ADD COLUMN replyToId TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN replySnippet TEXT');
    }
  }

  Future<void> _createRelayStore(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_store (
        id TEXT PRIMARY KEY,
        receiverPubkey TEXT NOT NULL,
        messageData TEXT NOT NULL,
        storedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_relay_receiver ON relay_store(receiverPubkey)
    ''');
  }

  Future<void> _createChannelTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS channels (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        creatorPubkey TEXT NOT NULL,
        creatorName TEXT DEFAULT '',
        createdAt INTEGER NOT NULL,
        lastActivityAt INTEGER NOT NULL,
        isDefault INTEGER DEFAULT 0,
        joined INTEGER DEFAULT 0,
        isPrivate INTEGER DEFAULT 0,
        adminPubkey TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_members (
        channelId TEXT NOT NULL,
        pubkey TEXT NOT NULL,
        displayName TEXT DEFAULT '',
        shortId TEXT DEFAULT '',
        addedAt INTEGER NOT NULL,
        PRIMARY KEY (channelId, pubkey)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS channel_messages (
        id TEXT PRIMARY KEY,
        channelId TEXT NOT NULL,
        senderPubkey TEXT NOT NULL,
        senderName TEXT DEFAULT '',
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        ttl INTEGER DEFAULT 3
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_channel_messages_channel
      ON channel_messages(channelId, timestamp)
    ''');
  }

  // Messages
  Future<void> insertMessage(Message message) async {
    final db = await database;
    await db.insert('messages', message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Message>> getUnreadMessagesFrom(String senderPubkey, String myPubkey) async {
    final db = await database;
    final maps = await db.rawQuery(
      "SELECT * FROM messages WHERE senderPubkey = ? AND receiverPubkey = ? "
      "AND status != 'read' AND type IN ('text', 'image', 'voice_note')",
      [senderPubkey, myPubkey],
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  Future<void> updateMessageStatus(String id, String status) async {
    final db = await database;
    await db.update('messages', {'status': status},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Same as [updateMessageStatus] but only applies the update when [status]
  /// ranks strictly higher than the current stored value.
  /// Ranking: pending(1) < sent(2) < delivered(3) < read(4).
  /// This prevents server status syncs from downgrading a tick that already
  /// advanced locally (e.g. delivered → sent regression).
  Future<void> updateMessageStatusIfHigher(String id, String status) async {
    final db = await database;
    await db.rawUpdate(
      '''UPDATE messages SET status = ? WHERE id = ?
         AND CASE status
               WHEN 'read'      THEN 4
               WHEN 'delivered' THEN 3
               WHEN 'sent'      THEN 2
               WHEN 'pending'   THEN 1
               ELSE 0 END
           < CASE ?
               WHEN 'read'      THEN 4
               WHEN 'delivered' THEN 3
               WHEN 'sent'      THEN 2
               WHEN 'pending'   THEN 1
               ELSE 0 END''',
      [status, id, status],
    );
  }

  Future<List<Message>> getMessages(
      String myPubkey, String contactPubkey,
      {int limit = 50, int offset = 0}) async {
    final db = await database;
    // Fetch newest first for pagination, then reverse so UI is oldest-at-top
    final maps = await db.query(
      'messages',
      where:
          '((senderPubkey = ? AND receiverPubkey = ?) OR (senderPubkey = ? AND receiverPubkey = ?)) AND type != ?',
      whereArgs: [myPubkey, contactPubkey, contactPubkey, myPubkey, 'read_receipt'],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return maps.reversed.map((m) => Message.fromMap(m)).toList();
  }

  Future<List<Message>> getPendingMessages() async {
    final db = await database;
    final cutoff = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - (7 * 24 * 3600);
    // Expire messages older than 7 days
    await db.rawUpdate(
      "UPDATE messages SET status = 'failed' WHERE status = 'pending' AND timestamp < ?",
      [cutoff],
    );
    // Only retry actual chat messages — never retry ephemeral/metadata types
    final maps = await db.rawQuery(
      "SELECT * FROM messages WHERE status IN ('pending', 'failed') "
      "AND type IN ('dm', 'text', 'image', 'voice_note', 'read_receipt')",
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  Future<void> updateMessageContent(String id, String content) async {
    final db = await database;
    await db.update('messages', {'content': content},
        where: 'id = ?', whereArgs: [id]);
  }

  // Delete a single message by ID
  Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  // Contacts
  Future<void> insertContact(Contact contact) async {
    final db = await database;
    // If replacing an existing contact, preserve isNameCustomized if already set
    final existing = await db.query('contacts',
        where: 'pubkey = ?', whereArgs: [contact.pubkey], limit: 1);
    final alreadyCustomized = existing.isNotEmpty &&
        (existing.first['isNameCustomized'] as int? ?? 0) == 1;
    final map = contact.toMap();
    if (alreadyCustomized && !contact.isNameCustomized) {
      map['isNameCustomized'] = 1;
    }
    await db.insert('contacts', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Contact>> getContacts() async {
    final db = await database;
    final maps = await db.query('contacts');
    return maps.map((c) => Contact.fromMap(c)).toList();
  }

  Future<void> updateContactNearby(String pubkey, bool isNearby) async {
    final db = await database;
    await db.update('contacts', {'isNearby': isNearby ? 1 : 0},
        where: 'pubkey = ?', whereArgs: [pubkey]);
  }

  Future<void> upsertBleHistory(String pubkey, String? displayName, int lastSeen) async {
    final db = await database;
    await db.insert(
      'ble_history',
      {'pubkey': pubkey, 'displayName': displayName, 'lastSeen': lastSeen},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getBleHistory() async {
    final db = await database;
    return db.query('ble_history', orderBy: 'lastSeen DESC');
  }

  Future<List<Contact>> getAllContacts() async {
    final db = await database;
    final maps = await db.query('contacts');
    return maps.map((m) => Contact.fromMap(m)).toList();
  }

  Future<Contact?> getContactByPubkey(String pubkey) async {
    final db = await database;
    final maps = await db.query('contacts', where: 'pubkey = ?', whereArgs: [pubkey]);
    if (maps.isEmpty) return null;
    return Contact.fromMap(maps.first);
  }

  Future<void> updateContactProfilePicture(String pubkey, String url) async {
    final db = await database;
    await db.update('contacts', {'profilePictureUrl': url},
        where: 'pubkey = ?', whereArgs: [pubkey]);
  }

  Future<void> updateContactLocalProfilePicture(String pubkey, String localPath) async {
    final db = await database;
    await db.update('contacts', {'profilePictureLocalPath': localPath},
        where: 'pubkey = ?', whereArgs: [pubkey]);
  }

  Future<void> updateContactName(String pubkey, String name) async {
    final db = await database;
    // Only update if the contact exists and the user has NOT manually customized the name
    await db.update(
      'contacts',
      {'name': name},
      where: 'pubkey = ? AND (isNameCustomized IS NULL OR isNameCustomized = 0)',
      whereArgs: [pubkey],
    );
  }

  /// Updates contact name only if currently null/empty (auto-populate from message).
  /// Never overwrites a user-customized name.
  Future<void> updateContactNameIfEmpty(String pubkey, String name) async {
    final db = await database;
    await db.update(
      'contacts',
      {'name': name},
      where: "pubkey = ? AND (name IS NULL OR name = '') AND (isNameCustomized IS NULL OR isNameCustomized = 0)",
      whereArgs: [pubkey],
    );
  }

  // Create a contact if it doesn't already exist (for unknown senders)
  /// Inserts contact if not already present. Returns true if newly created.
  Future<bool> ensureContact(String pubkey, {String? name}) async {
    final db = await database;
    final existing = await db.query('contacts',
        where: 'pubkey = ?', whereArgs: [pubkey], limit: 1);
    if (existing.isEmpty) {
      await db.insert('contacts', {
        'pubkey': pubkey,
        'name': name,
        'isNearby': 0,
      });
      return true;
    }
    return false;
  }

  Future<void> deleteContact(String pubkey) async {
    final db = await database;
    await db.delete('contacts', where: 'pubkey = ?', whereArgs: [pubkey]);
  }

  /// Returns contacts that have been saved by Short ID but pubkey not yet resolved.
  Future<List<Contact>> getPendingContacts() async {
    final db = await database;
    final maps = await db.query('contacts', where: 'isPending = 1');
    return maps.map((c) => Contact.fromMap(c)).toList();
  }

  /// Resolves a pending contact: replaces placeholder pubkey with real pubkey,
  /// migrates any queued messages, and removes the pending placeholder.
  Future<void> resolvePendingContact(
    String shortId,
    String realPubkey, {
    String? name,
    String? profilePictureUrl,
  }) async {
    final db = await database;
    final placeholderPubkey = 'pending_$shortId';

    await db.transaction((txn) async {
      final rows = await txn.query('contacts',
          where: 'pubkey = ?', whereArgs: [placeholderPubkey], limit: 1);
      if (rows.isEmpty) return;

      final existing = rows.first;
      final isNameCustomized = (existing['isNameCustomized'] as int? ?? 0) == 1;
      final existingName = existing['name'] as String?;

      // Insert (or replace) the resolved contact
      await txn.insert(
        'contacts',
        {
          'pubkey': realPubkey,
          'name': isNameCustomized
              ? existingName
              : (name != null && name.isNotEmpty ? name : existingName),
          'isNearby': 0,
          'isNameCustomized': existing['isNameCustomized'],
          'profilePictureUrl':
              profilePictureUrl ?? existing['profilePictureUrl'],
          'isPending': 0,
          'savedShortId': shortId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // Migrate any queued messages stored under the placeholder pubkey
      await txn.rawUpdate(
        'UPDATE messages SET receiverPubkey = ?, status = ? WHERE receiverPubkey = ? AND status = ?',
        [realPubkey, 'pending', placeholderPubkey, 'queued'],
      );

      // Remove the placeholder contact
      await txn.delete('contacts',
          where: 'pubkey = ?', whereArgs: [placeholderPubkey]);
    });
  }

  Future<void> deleteMessagesForContact(String myPubkey, String contactPubkey) async {
    final db = await database;
    await db.delete(
      'messages',
      where: '(senderPubkey = ? AND receiverPubkey = ?) OR (senderPubkey = ? AND receiverPubkey = ?)',
      whereArgs: [myPubkey, contactPubkey, contactPubkey, myPubkey],
    );
  }

  // Get last message for each contact (for contact list preview)
  Future<Map<String, Message>> getLastMessages(String myPubkey) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT m.* FROM messages m
      INNER JOIN (
        SELECT
          CASE WHEN senderPubkey = ? THEN receiverPubkey ELSE senderPubkey END AS contactPubkey,
          MAX(timestamp) AS maxTs
        FROM messages
        WHERE type IN ('text', 'image', 'voice_note') AND (senderPubkey = ? OR receiverPubkey = ?)
        GROUP BY contactPubkey
      ) latest
      ON (
        (m.senderPubkey = ? AND m.receiverPubkey = latest.contactPubkey)
        OR (m.senderPubkey = latest.contactPubkey AND m.receiverPubkey = ?)
      )
      AND m.timestamp = latest.maxTs
      AND m.type IN ('text', 'image', 'voice_note')
      ORDER BY m.timestamp DESC, m.rowid DESC
    ''', [myPubkey, myPubkey, myPubkey, myPubkey, myPubkey]);

    final result = <String, Message>{};
    for (final map in maps) {
      final msg = Message.fromMap(map);
      final contactPubkey = msg.senderPubkey == myPubkey
          ? msg.receiverPubkey
          : msg.senderPubkey;
      // Keep only the latest if duplicates
      if (!result.containsKey(contactPubkey) ||
          msg.timestamp > result[contactPubkey]!.timestamp) {
        result[contactPubkey] = msg;
      }
    }
    return result;
  }

  // Get unread message count per contact (text + voice_note + image)
  Future<Map<String, int>> getUnreadCounts(String myPubkey) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT senderPubkey, COUNT(*) as cnt
      FROM messages
      WHERE receiverPubkey = ? AND status != 'read'
        AND type IN ('text', 'image', 'voice_note')
      GROUP BY senderPubkey
    ''', [myPubkey]);

    final result = <String, int>{};
    for (final map in maps) {
      result[map['senderPubkey'] as String] = map['cnt'] as int;
    }
    return result;
  }

  // Mark all messages from a contact as read (text + voice_note + image)
  Future<void> markMessagesAsRead(String myPubkey, String contactPubkey) async {
    final db = await database;
    // Mark ALL non-read messages — not just 'delivered' ones.
    // Messages arriving via WebSocket in real-time land with status 'sent'
    // (the server hasn't polled them yet), so restricting to 'delivered'
    // left them permanently counted as unread.
    await db.rawUpdate(
      "UPDATE messages SET status = 'read' "
      "WHERE senderPubkey = ? AND receiverPubkey = ? AND status != 'read' "
      "AND type IN ('text', 'image', 'voice_note')",
      [contactPubkey, myPubkey],
    );
  }

  // Seen messages (for mesh dedup)
  Future<bool> hasSeenMessage(String messageId) async {
    final db = await database;
    final result = await db.query('messages',
        where: 'id = ?', whereArgs: [messageId], limit: 1);
    return result.isNotEmpty;
  }

  // ---- Store-and-forward (relay store) ----

  // Store a message we're holding for someone else
  Future<bool> storeRelayMessage(String messageId, String receiverPubkey, String messageData) async {
    final db = await database;

    return await db.transaction((txn) async {
      // Check if already stored
      final existing = await txn.query('relay_store',
          where: 'id = ?', whereArgs: [messageId], limit: 1);
      if (existing.isNotEmpty) return false;

      // Check limit
      final count = Sqflite.firstIntValue(
          await txn.rawQuery('SELECT COUNT(*) FROM relay_store'));
      if (count != null && count >= maxRelayMessages) {
        // Delete oldest to make room
        await txn.rawDelete(
            'DELETE FROM relay_store WHERE id IN (SELECT id FROM relay_store ORDER BY storedAt ASC LIMIT 1)');
      }

      await txn.insert('relay_store', {
        'id': messageId,
        'receiverPubkey': receiverPubkey,
        'messageData': messageData,
        'storedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      return true;
    });
  }

  // Get stored messages for a specific receiver
  Future<List<String>> getRelayMessagesFor(String receiverPubkey) async {
    final db = await database;
    final maps = await db.query('relay_store',
        where: 'receiverPubkey = ?',
        whereArgs: [receiverPubkey]);
    return maps.map((m) => m['messageData'] as String).toList();
  }

  // Delete delivered relay messages
  Future<void> deleteRelayMessage(String messageId) async {
    final db = await database;
    await db.delete('relay_store', where: 'id = ?', whereArgs: [messageId]);
  }

  // Delete all relay messages for a receiver (after delivery)
  Future<void> deleteRelayMessagesFor(String receiverPubkey) async {
    final db = await database;
    await db.delete('relay_store',
        where: 'receiverPubkey = ?', whereArgs: [receiverPubkey]);
  }

  // Clean up expired relay messages (older than 24 hours)
  Future<int> cleanupExpiredRelayMessages() async {
    final db = await database;
    final expiry = (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
        (relayExpiryHours * 3600);
    return await db.delete('relay_store',
        where: 'storedAt < ?', whereArgs: [expiry]);
  }

  // Get count of stored relay messages
  Future<int> getRelayStoreCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM relay_store')) ??
        0;
  }

  // ---- Channels ----

  Future<void> upsertChannel(Map<String, dynamic> channelMap) async {
    final db = await database;
    await db.insert('channels', channelMap,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getChannels() async {
    final db = await database;
    return await db.query('channels', orderBy: 'lastActivityAt DESC, id ASC');
  }

  Future<Map<String, dynamic>?> getChannel(String channelId) async {
    final db = await database;
    final maps = await db.query('channels',
        where: 'id = ?', whereArgs: [channelId], limit: 1);
    return maps.isNotEmpty ? maps.first : null;
  }

  Future<void> updateChannelJoined(String channelId, bool joined) async {
    final db = await database;
    await db.update('channels', {'joined': joined ? 1 : 0},
        where: 'id = ?', whereArgs: [channelId]);
  }

  Future<void> updateChannelActivity(String channelId, int timestamp) async {
    final db = await database;
    await db.update('channels', {'lastActivityAt': timestamp},
        where: 'id = ?', whereArgs: [channelId]);
  }

  Future<void> deleteChannel(String channelId) async {
    final db = await database;
    await db.delete('channels', where: 'id = ?', whereArgs: [channelId]);
    await db.delete('channel_messages',
        where: 'channelId = ?', whereArgs: [channelId]);
  }

  // Remove channels that haven't had activity in expirySeconds
  Future<int> cleanupExpiredChannels(int expirySeconds) async {
    final db = await database;
    final cutoff = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - expirySeconds;
    // Don't delete the default channel
    return await db.delete('channels',
        where: 'lastActivityAt < ? AND isDefault = 0',
        whereArgs: [cutoff]);
  }

  // ---- Channel Messages ----

  Future<void> insertChannelMessage(Map<String, dynamic> messageMap) async {
    final db = await database;
    await db.insert('channel_messages', messageMap,
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getChannelMessages(
      String channelId, {int limit = 100}) async {
    final db = await database;
    return await db.query('channel_messages',
        where: 'channelId = ?',
        whereArgs: [channelId],
        orderBy: 'timestamp ASC',
        limit: limit);
  }

  // Clean up old channel messages (older than retentionHours)
  Future<int> cleanupOldChannelMessages(int retentionHours) async {
    final db = await database;
    final cutoff = (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
        (retentionHours * 3600);
    return await db.delete('channel_messages',
        where: 'timestamp < ?', whereArgs: [cutoff]);
  }

  // ── Group members ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getGroupMembers(String channelId) async {
    final db = await database;
    return db.query('group_members',
        where: 'channelId = ?', whereArgs: [channelId], orderBy: 'addedAt ASC');
  }

  Future<void> addGroupMember(
      String channelId, String pubkey, String displayName, String shortId) async {
    final db = await database;
    await db.insert(
      'group_members',
      {
        'channelId': channelId,
        'pubkey': pubkey,
        'displayName': displayName,
        'shortId': shortId,
        'addedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeGroupMember(String channelId, String pubkey) async {
    final db = await database;
    await db.delete('group_members',
        where: 'channelId = ? AND pubkey = ?', whereArgs: [channelId, pubkey]);
  }

  Future<void> deleteGroupMembers(String channelId) async {
    final db = await database;
    await db.delete('group_members', where: 'channelId = ?', whereArgs: [channelId]);
  }

  // ── Call logs ───────────────────────────────────────────────────────────────

  Future<void> insertCallLog(CallLog log) async {
    final db = await database;
    await db.insert('call_logs', log.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<CallLog>> getCallLogs({int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      'call_logs',
      orderBy: 'startedAt DESC',
      limit: limit,
    );
    return rows.map(CallLog.fromMap).toList();
  }

  Future<void> deleteCallLog(String id) async {
    final db = await database;
    await db.delete('call_logs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearCallLogs() async {
    final db = await database;
    await db.delete('call_logs');
  }
}
