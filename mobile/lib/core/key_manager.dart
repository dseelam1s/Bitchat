import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nostr_tools/nostr_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class KeyManager {
  String? _privateKey;
  String? _publicKey;
  String? _username;
  final _keyApi = KeyApi();
  final _secureStorage = const FlutterSecureStorage();

  String? get privateKey => _privateKey;
  String? get publicKey => _publicKey;
  String? get username => _username;
  KeyApi get keyApi => _keyApi;

  // Load saved keys or generate new secp256k1 key pair
  Future<void> generateKeyPair() async {
    // Try secure storage first, then migrate from SharedPreferences
    String? savedPrivateKey = await _secureStorage.read(key: 'privateKey');

    if (savedPrivateKey == null) {
      // Check if key exists in old SharedPreferences (migrate it)
      final prefs = await SharedPreferences.getInstance();
      final oldKey = prefs.getString('privateKey');
      if (oldKey != null && _keyApi.isValidPrivateKey(oldKey)) {
        savedPrivateKey = oldKey;
        // Migrate to secure storage
        await _secureStorage.write(key: 'privateKey', value: oldKey);
        // Remove from insecure storage
        await prefs.remove('privateKey');
      }
    }

    if (savedPrivateKey != null && _keyApi.isValidPrivateKey(savedPrivateKey)) {
      _privateKey = savedPrivateKey;
      _publicKey = _keyApi.getPublicKey(savedPrivateKey);
    } else {
      _privateKey = _keyApi.generatePrivateKey();
      _publicKey = _keyApi.getPublicKey(_privateKey!);
      await _secureStorage.write(key: 'privateKey', value: _privateKey!);
    }

    // Load saved username, or generate a default one on first install
    final prefs = await SharedPreferences.getInstance();
    _username = prefs.getString('username');
    if (_username == null || _username!.isEmpty) {
      final number = Random().nextInt(9000) + 1000; // 1000–9999
      _username = 'User$number';
      await prefs.setString('username', _username!);
    }
  }

  Future<void> setUsername(String? name) async {
    _username = name;
    final prefs = await SharedPreferences.getInstance();
    if (name != null && name.isNotEmpty) {
      await prefs.setString('username', name);
    } else {
      await prefs.remove('username');
    }
  }

  // Load existing keys
  Future<void> loadKeys(String privateKeyHex, String publicKeyHex) async {
    _privateKey = privateKeyHex;
    _publicKey = publicKeyHex;
    await _secureStorage.write(key: 'privateKey', value: privateKeyHex);
  }

  // Generate a unique message ID
  String generateMessageId() {
    return const Uuid().v4();
  }

  bool get hasKeys => _privateKey != null && _publicKey != null;

  /// Returns true if a valid private key is already saved on this device.
  /// Used on first launch to decide whether to show onboarding or load normally.
  Future<bool> hasStoredKey() async {
    final key = await _secureStorage.read(key: 'privateKey');
    return key != null && _keyApi.isValidPrivateKey(key);
  }
}
