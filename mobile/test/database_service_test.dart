import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Tests the SQL logic for updateMessageStatusIfHigher and updateContactNameIfEmpty
// using an in-memory FFI database with the same schema as DatabaseService.
// We test the raw SQL rather than DatabaseService directly to avoid its static
// singleton, which cannot be reset between tests.

Database? _db;

Future<Database> _openTestDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            senderPubkey TEXT NOT NULL,
            receiverPubkey TEXT NOT NULL,
            content TEXT NOT NULL,
            type TEXT DEFAULT 'text',
            timestamp INTEGER NOT NULL,
            status TEXT DEFAULT 'pending'
          )
        ''');
        await db.execute('''
          CREATE TABLE contacts (
            pubkey TEXT PRIMARY KEY,
            name TEXT,
            isNameCustomized INTEGER DEFAULT 0
          )
        ''');
      },
    ),
  );
}

// Same SQL as DatabaseService.updateMessageStatusIfHigher
Future<void> updateStatusIfHigher(Database db, String id, String status) async {
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

// Same SQL as DatabaseService.updateContactNameIfEmpty
Future<void> updateContactNameIfEmpty(Database db, String pubkey, String name) async {
  await db.update(
    'contacts',
    {'name': name},
    where: "pubkey = ? AND (name IS NULL OR name = '') AND (isNameCustomized IS NULL OR isNameCustomized = 0)",
    whereArgs: [pubkey],
  );
}

Future<String?> getStatus(Database db, String id) async {
  final rows = await db.query('messages', where: 'id = ?', whereArgs: [id]);
  return rows.isEmpty ? null : rows.first['status'] as String?;
}

Future<String?> getContactName(Database db, String pubkey) async {
  final rows = await db.query('contacts', where: 'pubkey = ?', whereArgs: [pubkey]);
  return rows.isEmpty ? null : rows.first['name'] as String?;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Database db;

  setUp(() async {
    db = await _openTestDb();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertMessage(String id, String status) async {
    await db.insert('messages', {
      'id': id,
      'senderPubkey': 'a',
      'receiverPubkey': 'b',
      'content': 'test',
      'timestamp': 0,
      'status': status,
    });
  }

  group('updateMessageStatusIfHigher — ranking: pending < sent < delivered < read', () {
    test('pending → sent (upgrade allowed)', () async {
      await insertMessage('m1', 'pending');
      await updateStatusIfHigher(db, 'm1', 'sent');
      expect(await getStatus(db, 'm1'), 'sent');
    });

    test('sent → delivered (upgrade allowed)', () async {
      await insertMessage('m1', 'sent');
      await updateStatusIfHigher(db, 'm1', 'delivered');
      expect(await getStatus(db, 'm1'), 'delivered');
    });

    test('delivered → read (upgrade allowed)', () async {
      await insertMessage('m1', 'delivered');
      await updateStatusIfHigher(db, 'm1', 'read');
      expect(await getStatus(db, 'm1'), 'read');
    });

    test('pending → read (skip ahead allowed)', () async {
      await insertMessage('m1', 'pending');
      await updateStatusIfHigher(db, 'm1', 'read');
      expect(await getStatus(db, 'm1'), 'read');
    });

    test('read → delivered (downgrade blocked)', () async {
      await insertMessage('m1', 'read');
      await updateStatusIfHigher(db, 'm1', 'delivered');
      expect(await getStatus(db, 'm1'), 'read');
    });

    test('read → sent (downgrade blocked)', () async {
      await insertMessage('m1', 'read');
      await updateStatusIfHigher(db, 'm1', 'sent');
      expect(await getStatus(db, 'm1'), 'read');
    });

    test('delivered → sent (downgrade blocked)', () async {
      await insertMessage('m1', 'delivered');
      await updateStatusIfHigher(db, 'm1', 'sent');
      expect(await getStatus(db, 'm1'), 'delivered');
    });

    test('sent → pending (downgrade blocked)', () async {
      await insertMessage('m1', 'sent');
      await updateStatusIfHigher(db, 'm1', 'pending');
      expect(await getStatus(db, 'm1'), 'sent');
    });

    test('same status is a no-op (idempotent)', () async {
      await insertMessage('m1', 'delivered');
      await updateStatusIfHigher(db, 'm1', 'delivered');
      expect(await getStatus(db, 'm1'), 'delivered');
    });

    test('unknown message id is a no-op (no crash)', () async {
      await updateStatusIfHigher(db, 'nonexistent', 'sent');
      // just verifying no exception thrown
    });
  });

  group('updateContactNameIfEmpty', () {
    Future<void> insertContact(String pubkey,
        {String? name, int isNameCustomized = 0}) async {
      await db.insert('contacts', {
        'pubkey': pubkey,
        'name': name,
        'isNameCustomized': isNameCustomized,
      });
    }

    test('sets name when contact has no name', () async {
      await insertContact('pk1', name: null);
      await updateContactNameIfEmpty(db, 'pk1', 'Alice');
      expect(await getContactName(db, 'pk1'), 'Alice');
    });

    test('sets name when contact has empty string name', () async {
      await insertContact('pk1', name: '');
      await updateContactNameIfEmpty(db, 'pk1', 'Alice');
      expect(await getContactName(db, 'pk1'), 'Alice');
    });

    test('does not overwrite existing name', () async {
      await insertContact('pk1', name: 'Bob');
      await updateContactNameIfEmpty(db, 'pk1', 'Alice');
      expect(await getContactName(db, 'pk1'), 'Bob');
    });

    test('does not overwrite user-customized name (isNameCustomized = 1)', () async {
      await insertContact('pk1', name: null, isNameCustomized: 1);
      await updateContactNameIfEmpty(db, 'pk1', 'Alice');
      expect(await getContactName(db, 'pk1'), isNull);
    });

    test('no-op for unknown pubkey (no crash)', () async {
      await updateContactNameIfEmpty(db, 'unknown', 'Alice');
      // just verifying no exception thrown
    });
  });
}
