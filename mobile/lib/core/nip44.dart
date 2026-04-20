import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// NIP-44 v2 encryption (XChaCha20-Poly1305 + HKDF-SHA256).
/// Used for all end-to-end encrypted messages in BitChat.
class Nip44 {
  final _xchacha20 = Xchacha20.poly1305Aead();
  final _hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  final _random = Random.secure();

  /// Encrypt plaintext for a recipient using NIP-44 v2.
  ///
  /// [privateKeyHex] — sender's 32-byte hex private key
  /// [recipientPubkeyHex] — receiver's 32-byte hex public key
  /// [plaintext] — message content
  ///
  /// Returns base64-encoded ciphertext with version prefix.
  Future<String> encrypt(
    String privateKeyHex,
    String recipientPubkeyHex,
    String plaintext,
  ) async {
    final conversationKey = await _deriveConversationKey(
      privateKeyHex,
      recipientPubkeyHex,
    );

    // Generate 24-byte nonce
    final nonce = Uint8List(24);
    for (int i = 0; i < 24; i++) {
      nonce[i] = _random.nextInt(256);
    }

    // Pad plaintext (NIP-44 padding: 2-byte big-endian length prefix + padded content)
    final plaintextBytes = utf8.encode(plaintext);
    final padded = _pad(plaintextBytes);

    // Encrypt with XChaCha20-Poly1305
    final secretBox = await _xchacha20.encrypt(
      padded,
      secretKey: SecretKey(conversationKey),
      nonce: nonce,
    );

    // Build payload: version(1) + nonce(24) + ciphertext + mac(16)
    final payload = Uint8List(1 + 24 + secretBox.cipherText.length + secretBox.mac.bytes.length);
    payload[0] = 0x02; // NIP-44 v2
    payload.setRange(1, 25, nonce);
    payload.setRange(25, 25 + secretBox.cipherText.length, secretBox.cipherText);
    payload.setRange(
      25 + secretBox.cipherText.length,
      payload.length,
      secretBox.mac.bytes,
    );

    return base64Encode(payload);
  }

  /// Decrypt a NIP-44 v2 message.
  ///
  /// Returns the plaintext string.
  /// Throws if decryption fails.
  Future<String> decrypt(
    String privateKeyHex,
    String senderPubkeyHex,
    String payload,
  ) async {
    final raw = base64Decode(payload);
    if (raw.length < 1 + 24 + 16 + 2) {
      throw FormatException('NIP-44 payload too short');
    }

    final version = raw[0];
    if (version != 0x02) {
      throw FormatException('Unsupported NIP-44 version: $version');
    }

    final nonce = Uint8List.sublistView(raw, 1, 25);
    final macStart = raw.length - 16;
    final ciphertext = Uint8List.sublistView(raw, 25, macStart);
    final mac = Mac(List<int>.from(Uint8List.sublistView(raw, macStart)));

    final conversationKey = await _deriveConversationKey(
      privateKeyHex,
      senderPubkeyHex,
    );

    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: mac,
    );

    final padded = await _xchacha20.decrypt(
      secretBox,
      secretKey: SecretKey(conversationKey),
    );

    return utf8.decode(_unpad(Uint8List.fromList(padded)));
  }

  /// Detect whether a ciphertext is NIP-44 (vs NIP-04).
  ///
  /// NIP-04 uses `?iv=` separator; NIP-44 is pure base64 starting with version byte.
  static bool isNip44(String ciphertext) {
    if (ciphertext.contains('?iv=')) return false;
    try {
      final raw = base64Decode(ciphertext);
      return raw.isNotEmpty && raw[0] == 0x02;
    } catch (_) {
      return false;
    }
  }

  /// Derive a shared conversation key using ECDH + HKDF.
  Future<List<int>> _deriveConversationKey(
    String privateKeyHex,
    String publicKeyHex,
  ) async {
    // Compute ECDH shared point using secp256k1
    final sharedPoint = _ecdhSharedSecret(
      _hexToBytes(privateKeyHex),
      _hexToBytes(publicKeyHex),
    );

    // Derive conversation key using HKDF-SHA256
    final derivedKey = await _hkdf.deriveKey(
      secretKey: SecretKey(sharedPoint),
      nonce: utf8.encode('nip44-v2'),
    );

    return derivedKey.extractBytes();
  }

  /// Pad plaintext following NIP-44 spec.
  /// 2-byte big-endian length prefix + content + zero-padding to next power-of-2 boundary.
  Uint8List _pad(List<int> plaintext) {
    final len = plaintext.length;
    if (len < 1 || len > 65535) {
      throw ArgumentError('Plaintext must be 1-65535 bytes');
    }

    // Calculate padded size: next power of 2, minimum 32
    int paddedLen = max(32, _nextPowerOf2(len + 2)); // +2 for length prefix

    final result = Uint8List(paddedLen);
    // Big-endian length prefix
    result[0] = (len >> 8) & 0xFF;
    result[1] = len & 0xFF;
    // Copy content
    result.setRange(2, 2 + len, plaintext);
    // Rest is already zero-filled
    return result;
  }

  /// Remove NIP-44 padding.
  Uint8List _unpad(Uint8List padded) {
    if (padded.length < 2) throw FormatException('Padded data too short');
    final len = (padded[0] << 8) | padded[1];
    if (len < 1 || 2 + len > padded.length) {
      throw FormatException('Invalid padding length');
    }
    return Uint8List.sublistView(padded, 2, 2 + len);
  }

  int _nextPowerOf2(int n) {
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  /// Compute ECDH shared secret on secp256k1.
  ///
  /// Uses the `cryptography` package's X25519-style scalar multiply
  /// adapted for secp256k1 via the nostr_tools ECDH.
  /// Since the `cryptography` package doesn't support secp256k1 natively,
  /// we use a simplified approach: SHA-256 of the concatenated keys as
  /// a deterministic shared secret. In production, this should use
  /// proper secp256k1 point multiplication.
  ///
  /// NOTE: We rely on nostr_tools' Nip04 internally for the ECDH step,
  /// then apply HKDF on top for NIP-44 key derivation.
  List<int> _ecdhSharedSecret(List<int> privateKey, List<int> publicKey) {
    // Use nostr_tools' internal ECDH to get raw shared point
    // The NIP-04 encrypt/decrypt uses ECDH internally.
    // We need the raw shared secret, which is the x-coordinate
    // of privateKey * PublicKeyPoint on secp256k1.
    //
    // Since nostr_tools doesn't expose raw ECDH, we compute it
    // using the pointycastle library that nostr_tools depends on.
    return _secp256k1SharedSecret(privateKey, publicKey);
  }

  /// Raw secp256k1 ECDH: returns x-coordinate of sk * PK.
  List<int> _secp256k1SharedSecret(List<int> sk, List<int> pk) {
    // secp256k1 parameters
    final p = BigInt.parse(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
        radix: 16);
    final a = BigInt.zero;

    // Parse private key
    final d = _bytesToBigInt(sk);

    // Parse public key (compressed or x-only)
    final pkBytes = Uint8List.fromList(pk);
    final x = _bytesToBigInt(pkBytes);

    // Recover y from x using secp256k1 curve equation: y² = x³ + 7 mod p
    final y2 = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y = y2.modPow((p + BigInt.one) ~/ BigInt.from(4), p);

    // Scalar multiply: d * (x, y)
    final result = _ecScalarMul(d, x, y, a, p);

    // Return x-coordinate as 32 bytes
    return _bigIntToBytes(result[0], 32);
  }

  /// Elliptic curve scalar multiplication using double-and-add.
  List<BigInt> _ecScalarMul(
      BigInt k, BigInt px, BigInt py, BigInt a, BigInt p) {
    // Point at infinity represented as (0, 0)
    BigInt rx = BigInt.zero, ry = BigInt.zero;
    BigInt qx = px, qy = py;
    bool isInfinity = true;

    while (k > BigInt.zero) {
      if (k.isOdd) {
        if (isInfinity) {
          rx = qx;
          ry = qy;
          isInfinity = false;
        } else {
          final added = _ecAdd(rx, ry, qx, qy, a, p);
          rx = added[0];
          ry = added[1];
        }
      }
      final doubled = _ecDouble(qx, qy, a, p);
      qx = doubled[0];
      qy = doubled[1];
      k >>= 1;
    }

    return [rx, ry];
  }

  /// Elliptic curve point addition.
  List<BigInt> _ecAdd(
      BigInt x1, BigInt y1, BigInt x2, BigInt y2, BigInt a, BigInt p) {
    if (x1 == x2 && y1 == y2) return _ecDouble(x1, y1, a, p);
    final dx = (x2 - x1) % p;
    final dy = (y2 - y1) % p;
    final s = (dy * dx.modInverse(p)) % p;
    final x3 = (s * s - x1 - x2) % p;
    final y3 = (s * (x1 - x3) - y1) % p;
    return [x3 < BigInt.zero ? x3 + p : x3, y3 < BigInt.zero ? y3 + p : y3];
  }

  /// Elliptic curve point doubling.
  List<BigInt> _ecDouble(BigInt x, BigInt y, BigInt a, BigInt p) {
    final s =
        ((BigInt.from(3) * x * x + a) * (BigInt.from(2) * y).modInverse(p)) %
            p;
    final x3 = (s * s - BigInt.from(2) * x) % p;
    final y3 = (s * (x - x3) - y) % p;
    return [x3 < BigInt.zero ? x3 + p : x3, y3 < BigInt.zero ? y3 + p : y3];
  }

  BigInt _bytesToBigInt(List<int> bytes) {
    BigInt result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  List<int> _bigIntToBytes(BigInt n, int length) {
    final bytes = Uint8List(length);
    var temp = n;
    for (int i = length - 1; i >= 0; i--) {
      bytes[i] = (temp & BigInt.from(0xFF)).toInt();
      temp >>= 8;
    }
    return bytes;
  }

  Uint8List _hexToBytes(String hex) {
    final h = hex.length.isOdd ? '0$hex' : hex;
    final bytes = Uint8List(h.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
