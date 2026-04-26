import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_messenger/core/nip44.dart';

void main() {
  final nip44 = Nip44();

  // Standard secp256k1 test keys: private key 1 and 2, their x-only public keys.
  // pub1 = x-coordinate of G (generator * 1)
  // pub2 = x-coordinate of 2G (generator * 2)
  const sec1 = '0000000000000000000000000000000000000000000000000000000000000001';
  const pub1 = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
  const sec2 = '0000000000000000000000000000000000000000000000000000000000000002';
  const pub2 = 'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';

  group('encrypt / decrypt round-trip', () {
    test('A encrypts for B, B decrypts', () async {
      const msg = 'Hello BitChat';
      final ct = await nip44.encrypt(sec1, pub2, msg);
      expect(await nip44.decrypt(sec2, pub1, ct), msg);
    });

    test('B encrypts for A, A decrypts', () async {
      const msg = 'Hello back';
      final ct = await nip44.encrypt(sec2, pub1, msg);
      expect(await nip44.decrypt(sec1, pub2, ct), msg);
    });

    test('preserves unicode and emoji', () async {
      const msg = '🔒 こんにちは мир — secret!';
      final ct = await nip44.encrypt(sec1, pub2, msg);
      expect(await nip44.decrypt(sec2, pub1, ct), msg);
    });

    test('preserves long message (1000 chars)', () async {
      final msg = 'A' * 1000;
      final ct = await nip44.encrypt(sec1, pub2, msg);
      expect(await nip44.decrypt(sec2, pub1, ct), msg);
    });

    test('preserves single character', () async {
      const msg = 'x';
      final ct = await nip44.encrypt(sec1, pub2, msg);
      expect(await nip44.decrypt(sec2, pub1, ct), msg);
    });

    test('each call produces different ciphertext (random nonce)', () async {
      const msg = 'same plaintext';
      final ct1 = await nip44.encrypt(sec1, pub2, msg);
      final ct2 = await nip44.encrypt(sec1, pub2, msg);
      expect(ct1, isNot(equals(ct2)));
      // But both still decrypt correctly
      expect(await nip44.decrypt(sec2, pub1, ct1), msg);
      expect(await nip44.decrypt(sec2, pub1, ct2), msg);
    });

    test('ECDH is symmetric — shared key same from both sides', () async {
      // If ECDH(sec1, pub2) == ECDH(sec2, pub1), then A can decrypt B's messages and vice versa.
      // Verified implicitly: encrypt with sec1+pub2, decrypt with sec2+pub1.
      const msg = 'symmetry check';
      final ct = await nip44.encrypt(sec1, pub2, msg);
      expect(await nip44.decrypt(sec2, pub1, ct), msg);
    });
  });

  group('decrypt error cases', () {
    test('wrong private key throws (AEAD auth failure)', () async {
      final ct = await nip44.encrypt(sec1, pub2, 'secret');
      // sec2 encrypting for itself rather than for pub2 → wrong shared key
      expect(() => nip44.decrypt(sec2, pub2, ct), throwsA(anything));
    });

    test('payload too short throws FormatException', () {
      // min valid length: 1 (version) + 24 (nonce) + 16 (mac) + 2 (min padded) = 43
      final tooShort = base64Encode(Uint8List(20));
      expect(
        () => nip44.decrypt(sec1, pub2, tooShort),
        throwsA(isA<FormatException>()),
      );
    });

    test('wrong version byte throws FormatException', () {
      final raw = Uint8List(50);
      raw[0] = 0x01; // version 1 not supported, only 0x02
      final badPayload = base64Encode(raw);
      expect(
        () => nip44.decrypt(sec1, pub2, badPayload),
        throwsA(isA<FormatException>()),
      );
    });

    test('corrupted ciphertext throws', () async {
      final ct = await nip44.encrypt(sec1, pub2, 'intact message');
      final raw = base64Decode(ct);
      // Flip a byte in the ciphertext body
      raw[30] ^= 0xFF;
      final corrupted = base64Encode(raw);
      expect(() => nip44.decrypt(sec2, pub1, corrupted), throwsA(anything));
    });
  });

  group('isNip44', () {
    test('returns true for a freshly encrypted payload', () async {
      final ct = await nip44.encrypt(sec1, pub2, 'test');
      expect(Nip44.isNip44(ct), isTrue);
    });

    test('returns false for NIP-04 format (contains ?iv=)', () {
      expect(Nip44.isNip44('abc123==?iv=xyz456=='), isFalse);
    });

    test('returns false for invalid base64', () {
      expect(Nip44.isNip44('not-valid-base64!!!'), isFalse);
    });

    test('returns false for empty string', () {
      expect(Nip44.isNip44(''), isFalse);
    });

    test('returns false for valid base64 but wrong version', () {
      final raw = Uint8List(50);
      raw[0] = 0x01;
      expect(Nip44.isNip44(base64Encode(raw)), isFalse);
    });
  });

  group('padding', () {
    test('empty string throws ArgumentError', () {
      expect(
        () => nip44.encrypt(sec1, pub2, ''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
