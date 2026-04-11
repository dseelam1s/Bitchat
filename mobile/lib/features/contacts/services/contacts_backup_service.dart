import 'dart:convert';

import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/features/contacts/models/contact.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/features/profile/services/profile_picture_cache_service.dart';
import 'package:bitchat_messenger/core/server_service.dart';

/// Backs up and restores the user's contact list via the server.
///
/// Privacy: contacts are NIP-44 encrypted with the user's own private key
/// before upload — the server stores ciphertext only and cannot read names
/// or pubkeys.
///
/// Backup format (before encryption):
///   [{"pubkey": "...", "name": "...", "isNameCustomized": true/false}, ...]
///
/// Backup is triggered:
///   - After any contact is added/updated/deleted
///   - On first launch after key restore (fetch path)
class ContactsBackupService {
  static final ContactsBackupService _instance = ContactsBackupService._internal();
  factory ContactsBackupService() => _instance;
  ContactsBackupService._internal();

  final _nip44 = Nip44();

  // ── Upload ──────────────────────────────────────────────────────────────

  /// Encrypt all real (non-pending) contacts and upload to server.
  /// Fire-and-forget — if server is down nothing happens.
  Future<void> backup({
    required DatabaseService dbService,
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      if (!ServerService().isAuthenticated) return;

      final contacts = await dbService.getAllContacts();
      // Only back up real contacts — skip pending (unresolved short IDs)
      final real = contacts.where((c) => !c.isPending).toList();

      final payload = real.map((c) => {
        'pubkey': c.pubkey,
        'name': c.name ?? '',
        'isNameCustomized': c.isNameCustomized,
      }).toList();

      final json = jsonEncode(payload);

      // Encrypt with NIP-44 — encrypt to self (receiver = sender pubkey)
      final encrypted = await _nip44.encrypt(privateKey, publicKey, json);

      await ServerService().saveContactsBackup(encrypted);
    } catch (_) {
      // Never surface errors — backup is best-effort
    }
  }

  // ── Restore ─────────────────────────────────────────────────────────────

  /// Fetch and decrypt contact list from server, then insert into local DB.
  /// Called once after a key restore (reinstall scenario).
  /// Returns the number of contacts restored, 0 if nothing to restore.
  Future<int> restore({
    required DatabaseService dbService,
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      final encrypted = await ServerService().fetchContactsBackup();
      if (encrypted == null || encrypted.isEmpty) return 0;

      final json = await _nip44.decrypt(privateKey, publicKey, encrypted);
      final list = jsonDecode(json) as List<dynamic>;

      int count = 0;
      for (final item in list) {
        try {
          final pubkey = item['pubkey'] as String? ?? '';
          if (pubkey.isEmpty) continue;

          final name = item['name'] as String?;
          final isNameCustomized = item['isNameCustomized'] as bool? ?? false;

          await dbService.insertContact(Contact(
            pubkey: pubkey,
            name: name?.isNotEmpty == true ? name : null,
            isNameCustomized: isNameCustomized,
          ));

          // Silently fetch their profile picture from server and cache locally
          _fetchAndCacheProfile(dbService, pubkey);

          count++;
        } catch (_) {}
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  void _fetchAndCacheProfile(DatabaseService dbService, String pubkey) {
    () async {
      try {
        final result = await ServerService().getProfile(pubkey);
        if (result == null) return;

        final picUrl = result['profile_picture_url'] as String?;
        final name = result['display_name'] as String?;

        if (name != null && name.isNotEmpty) {
          await dbService.updateContactName(pubkey, name);
        }
        if (picUrl != null && picUrl.isNotEmpty) {
          await dbService.updateContactProfilePicture(pubkey, picUrl);
          final localPath = await ProfilePictureCacheService().download(pubkey, picUrl);
          if (localPath != null) {
            await dbService.updateContactLocalProfilePicture(pubkey, localPath);
          }
        }
      } catch (_) {}
    }();
  }
}
