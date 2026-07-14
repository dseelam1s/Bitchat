import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/calls/models/call_log.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';

/// Debug-only demo content so the app feels lived-in — for design review
/// and Play Store screenshots. Seeded/cleared from Settings (debug builds).
class DemoData {
  // Recognizably fake pubkeys (all end in 'demo0...' padding).
  static const _people = [
    ('Meera', 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7edem0'),
    ('Arjun', 'b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8dem0'),
    ('Sana', 'c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9dem0'),
    ('Ravi anna', 'd4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90adem0'),
    ('Kiran', 'e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1bdem0'),
  ];

  static Future<void> seed(DatabaseService db, String myPubkey) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var msgN = 0;
    Message m(String peer, String text, int agoMin,
        {bool fromMe = false, String status = 'read', String transport = 'server'}) {
      msgN++;
      return Message(
        id: 'demo_msg_$msgN',
        senderPubkey: fromMe ? myPubkey : peer,
        receiverPubkey: fromMe ? peer : myPubkey,
        content: text,
        timestamp: now - agoMin * 60,
        status: status,
        transport: transport,
        senderName: fromMe ? null : _people.firstWhere((p) => p.$2 == peer).$1,
      );
    }

    final meera = _people[0].$2, arjun = _people[1].$2, sana = _people[2].$2;
    final ravi = _people[3].$2, kiran = _people[4].$2;

    for (final p in _people) {
      await db.insertContact(Contact(pubkey: p.$2, name: p.$1));
    }

    final messages = [
      // Meera — fresh, unread, mixed transports (shows coral air bubbles)
      m(meera, 'wya? we\'re near the food stalls', 34),
      m(meera, 'network is DEAD here btw', 33),
      m(meera, 'we don\'t need it, check your radar', 32, fromMe: true, transport: 'bitchat', status: 'sent'),
      m(meera, 'ok that\'s actually insane 😂', 5, status: 'delivered'),
      m(meera, 'coming to you', 2, status: 'delivered'),
      // Arjun — plans from earlier today
      m(arjun, 'bro send the location', 260),
      m(arjun, 'shared. come by 7, everyone\'s here', 258, fromMe: true, status: 'read'),
      m(arjun, 'ETA 20 mins', 250),
      // Sana — yesterday
      m(sana, 'did you try that new place near campus?', 1500),
      m(sana, 'overrated. the chai is good though', 1495, fromMe: true, status: 'read'),
      m(sana, 'lol noted', 1490),
      // Ravi anna — few days back
      m(ravi, 'call amma when you\'re free', 4300),
      m(ravi, 'done, spoke for an hour 😄', 4200, fromMe: true, status: 'read'),
      // Kiran — saved contact, no messages (shows 'say hi' row)
    ];
    for (final msg in messages) {
      await db.insertMessage(msg);
    }

    // Call history
    final calls = [
      CallLog(id: 'demo_call_1', remotePubkey: meera, remoteName: 'Meera', direction: 'incoming', status: 'answered', startedAt: now - 3600, duration: 754),
      CallLog(id: 'demo_call_2', remotePubkey: arjun, remoteName: 'Arjun', direction: 'outgoing', status: 'answered', startedAt: now - 86400, duration: 191),
      CallLog(id: 'demo_call_3', remotePubkey: sana, remoteName: 'Sana', direction: 'incoming', status: 'missed', startedAt: now - 90000, duration: 0),
      CallLog(id: 'demo_call_4', remotePubkey: ravi, remoteName: 'Ravi anna', direction: 'outgoing', status: 'no_answer', startedAt: now - 200000, duration: 0),
    ];
    for (final c in calls) {
      await db.insertCallLog(c);
    }

    // Radar 'seen earlier' band
    await db.upsertBleHistory(meera, 'Meera', (now - 45 * 60) * 1000);
    await db.upsertBleHistory(kiran, 'Kiran', (now - 3 * 3600) * 1000);
    await db.upsertBleHistory(arjun, 'Arjun', (now - 26 * 3600) * 1000);
  }

  static Future<void> clear(DatabaseService db) async {
    final dbx = await db.database;
    for (final p in _people) {
      await dbx.delete('contacts', where: 'pubkey = ?', whereArgs: [p.$2]);
      await dbx.delete('ble_history', where: 'pubkey = ?', whereArgs: [p.$2]);
    }
    await dbx.delete('messages', where: "id LIKE 'demo_msg_%'");
    await dbx.delete('call_logs', where: "id LIKE 'demo_call_%'");
  }
}
