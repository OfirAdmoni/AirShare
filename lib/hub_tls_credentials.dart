import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/asymmetric/api.dart';

/// Runtime self-signed TLS material for the local HTTPS hub (pure Dart).
class HubTlsCredentials {
  HubTlsCredentials._({
    required this.securityContext,
    required this.certSha256Hex,
  });

  final SecurityContext securityContext;

  /// Lowercase hex SHA-256 of the certificate DER (no colons).
  final String certSha256Hex;

  static Future<HubTlsCredentials> generate() async {
    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;
    final subject = {
      'CN': 'AirShare Hub',
      'O': 'AirShare',
    };
    final csr = X509Utils.generateRsaCsrPem(subject, privateKey, publicKey);
    final certPem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      365,
      sans: const ['localhost', '127.0.0.1'],
    );
    final privateKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);

    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(certPem));
    context.usePrivateKeyBytes(utf8.encode(privateKeyPem));

    final der = _certificateDerFromPem(certPem);
    final hex = sha256.convert(der).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return HubTlsCredentials._(
      securityContext: context,
      certSha256Hex: hex,
    );
  }

  static Uint8List _certificateDerFromPem(String pem) {
    final normalized = pem
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s+'), '');
    return Uint8List.fromList(base64.decode(normalized));
  }
}
