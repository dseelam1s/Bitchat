import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_service.dart';

/// Handles client-side encryption of the private key and upload to server.
///
/// The server never sees the plaintext key — only the encrypted blob.
/// Encryption: PBKDF2-SHA256 (100k iterations) → AES-256-GCM.
/// Blob format (base64): [16B salt][12B nonce][16B MAC][ciphertext]
class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  static const _prefKey = 'backup_active';

  final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );
  final _aesGcm = AesGcm.with256bits();

  // ── Status ───────────────────────────────────────────────────────────────

  Future<bool> isBackupActive() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? false;
  }

  Future<void> _setBackupActive(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
  }

  // ── Encryption ───────────────────────────────────────────────────────────

  Future<String> _encrypt(String privateKey, String password) async {
    final salt = Uint8List.fromList(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final derivedKey = await _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final box = await _aesGcm.encrypt(
      utf8.encode(privateKey),
      secretKey: derivedKey,
    );
    // Concatenate: salt + nonce + MAC + ciphertext
    final blob = Uint8List.fromList([
      ...salt,
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
    return base64Encode(blob);
  }

  /// Decrypts a blob. Returns the private key or null if the password is wrong.
  Future<String?> decrypt(String blob, String password) async {
    try {
      final bytes = base64Decode(blob);
      final salt = bytes.sublist(0, 16);
      final nonce = bytes.sublist(16, 28);  // 12 bytes
      final mac = bytes.sublist(28, 44);    // 16 bytes
      final cipherText = bytes.sublist(44);

      final derivedKey = await _pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );
      final plaintext = await _aesGcm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: derivedKey,
      );
      return utf8.decode(plaintext);
    } catch (_) {
      return null; // wrong password or corrupted blob
    }
  }

  // ── Backup ───────────────────────────────────────────────────────────────

  /// Encrypts the private key and uploads to server.
  /// Returns true on success, false if server unreachable.
  Future<bool> backupToServer(String privateKey, String password) async {
    final blob = await _encrypt(privateKey, password);
    final success = await ServerService().backupEncryptedKey(blob);
    if (success) await _setBackupActive(true);
    return success;
  }
}
