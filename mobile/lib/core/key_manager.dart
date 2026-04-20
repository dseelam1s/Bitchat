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

  /// Load existing keys from secure storage. Returns true if a valid key was
  /// found and loaded, false if no key exists (first install / new device).
  /// Does NOT generate a new key — call generateKeyPair() for that.
  Future<bool> loadExistingKeys() async {
    String? savedPrivateKey = await _secureStorage.read(key: 'privateKey');

    if (savedPrivateKey == null) {
      // Migrate from old SharedPreferences storage if present
      final prefs = await SharedPreferences.getInstance();
      final oldKey = prefs.getString('privateKey');
      if (oldKey != null && _keyApi.isValidPrivateKey(oldKey)) {
        savedPrivateKey = oldKey;
        await _secureStorage.write(key: 'privateKey', value: oldKey);
        await prefs.remove('privateKey');
      }
    }

    if (savedPrivateKey == null || !_keyApi.isValidPrivateKey(savedPrivateKey)) {
      return false;
    }

    _privateKey = savedPrivateKey;
    _publicKey = _keyApi.getPublicKey(savedPrivateKey);

    final prefs = await SharedPreferences.getInstance();
    _username = prefs.getString('username');
    return true;
  }

  // Load saved keys or generate new secp256k1 key pair (used by onboarding)
  Future<void> generateKeyPair() async {
    // If keys were already loaded by loadExistingKeys(), skip the storage read
    if (_privateKey != null && _publicKey != null) return;

    _privateKey = _keyApi.generatePrivateKey();
    _publicKey = _keyApi.getPublicKey(_privateKey!);
    await _secureStorage.write(key: 'privateKey', value: _privateKey!);
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
  /// If keys are already loaded in memory, skips the storage read.
  Future<bool> hasStoredKey() async {
    if (_privateKey != null) return true;
    final key = await _secureStorage.read(key: 'privateKey');
    return key != null && _keyApi.isValidPrivateKey(key);
  }
}
