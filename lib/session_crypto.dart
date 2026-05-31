import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:air_share/wire_contract.dart';

/// Pure-Dart X25519 + HKDF + AES-GCM helpers (no platform plugins).
abstract final class SessionCrypto {
  static final X25519 _x25519 = X25519();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final AesGcm _aesGcm = AesGcm.with256bits();

  static Future<SimpleKeyPair> generateKeyPair() => _x25519.newKeyPair();

  static Future<String> publicKeyBase64Url(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return WireEncoding.bytesToBase64Url(publicKey.bytes);
  }

  /// Derives the HTTP [Authorization: Bearer] token from an ECDH shared secret.
  static Future<String> deriveBearerToken({
    required SimpleKeyPair localKeyPair,
    required String remotePublicKeyBase64Url,
  }) async {
    final remoteBytes = WireEncoding.base64UrlToBytes(remotePublicKeyBase64Url);
    final remotePublic = SimplePublicKey(
      remoteBytes,
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: remotePublic,
    );
    final sharedBytes = await sharedSecret.extractBytes();
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      info: utf8.encode(WireContract.bearerDerivationInfo),
      nonce: utf8.encode(WireContract.bearerDerivationSalt),
    );
    return WireEncoding.bytesToBase64Url(await derived.extractBytes());
  }

  /// AES-256-GCM encrypt (nonce + ciphertext + mac concatenated).
  static Future<List<int>> encryptBytes({
    required List<int> aesKeyBytes,
    required List<int> plaintext,
  }) async {
    final secretKey = SecretKey(aesKeyBytes);
    final box = await _aesGcm.encrypt(plaintext, secretKey: secretKey);
    return box.concatenation();
  }

  /// AES-256-GCM decrypt from [encryptBytes] output.
  static Future<List<int>> decryptBytes({
    required List<int> aesKeyBytes,
    required List<int> payload,
  }) async {
    final secretKey = SecretKey(aesKeyBytes);
    final box = SecretBox.fromConcatenation(
      payload,
      nonceLength: _aesGcm.nonceLength,
      macLength: _aesGcm.macAlgorithm.macLength,
    );
    return _aesGcm.decrypt(box, secretKey: secretKey);
  }

  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
