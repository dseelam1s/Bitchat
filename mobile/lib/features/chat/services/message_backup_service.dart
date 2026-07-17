import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:bitchat_messenger/core/database_service.dart';
import 'package:bitchat_messenger/core/nip44.dart';
import 'package:bitchat_messenger/core/server_service.dart';
import 'package:bitchat_messenger/features/chat/models/message.dart';

/// Backs up and restores message history via the server.
///
/// Privacy: the export is NIP-44 encrypted to the user's own key before
/// upload — the server stores ciphertext only and can never read messages.
///
/// Backup runs at most once per 24h (on app start) plus whenever [backupNow]
/// is called. Restore runs once after a key restore, alongside the contacts
/// restore.
class MessageBackupService {
  static final MessageBackupService _instance =
      MessageBackupService._internal();
  factory MessageBackupService() => _instance;
  MessageBackupService._internal();

  static const _lastBackupKey = 'last_message_backup_at';
  static const _maxMessages = 2000;

  final _nip44 = Nip44();

  /// Back up if the last successful backup is older than 24h.
  /// Fire-and-forget — never throws.
  Future<void> backupIfDue({
    required DatabaseService dbService,
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastBackupKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 24).inMilliseconds) return;
      await backupNow(
          dbService: dbService, privateKey: privateKey, publicKey: publicKey);
    } catch (_) {}
  }

  /// Encrypt the most recent messages and upload. Returns true on success.
  Future<bool> backupNow({
    required DatabaseService dbService,
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      if (!ServerService().isAuthenticated) return false;

      final messages =
          await dbService.getRecentMessagesForBackup(limit: _maxMessages);
      if (messages.isEmpty) return false;

      final json = jsonEncode(messages.map((m) => m.toMap()).toList());
      final encrypted = await _nip44.encrypt(privateKey, publicKey, json);
      final ok = await ServerService().saveMessagesBackup(encrypted);
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
            _lastBackupKey, DateTime.now().millisecondsSinceEpoch);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Fetch, decrypt and merge the backup into the local DB (insert-if-absent,
  /// so nothing local is ever overwritten). Returns messages restored.
  Future<int> restore({
    required DatabaseService dbService,
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      final encrypted = await ServerService().fetchMessagesBackup();
      if (encrypted == null || encrypted.isEmpty) return 0;

      final json = await _nip44.decrypt(privateKey, publicKey, encrypted);
      final list = jsonDecode(json) as List<dynamic>;

      int count = 0;
      for (final item in list) {
        try {
          await dbService.insertMessageIfAbsent(
              Message.fromMap(Map<String, dynamic>.from(item as Map)));
          count++;
        } catch (_) {}
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}
