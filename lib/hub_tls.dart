import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// In-memory TLS credentials for the local hub (self-signed, LAN-only).
class HubTlsCredentials {
  HubTlsCredentials._({
    required this.securityContext,
    required this.sha256Pin,
    required this.certificatePem,
  });

  final SecurityContext securityContext;
  final String sha256Pin;
  final String certificatePem;

  /// [extraIps] — e.g. detected wlan0 / ap0 address for SAN.
  static Future<HubTlsCredentials> generate({
    Iterable<String> extraIps = const [],
  }) async {
    final san = <String>{'127.0.0.1', 'localhost'};
    san.addAll(extraIps.where((ip) => ip.trim().isNotEmpty));

    try {
      for (final iface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            san.add(addr.address);
          }
        }
      }
    } catch (_) {}

    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;

    final subject = <String, String>{
      'CN': 'AirShare Hub',
      'O': 'AirShare',
      'OU': 'Local Session',
    };

    final csrPem = X509Utils.generateRsaCsrPem(
      subject,
      privateKey,
      publicKey,
      san: san.toList(),
    );

    final certPemRaw = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csrPem,
      365,
      sans: san.toList(),
      notBefore: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    final keyPemRaw = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
    final certPem = _normalizePem(certPemRaw);
    final keyPem = _normalizePem(keyPemRaw);

    final der = _pemToDer(certPem);
    final pin = sha256
        .convert(der)
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final context = SecurityContext(withTrustedRoots: false);
    // Always pass normalized PEM to SecurityContext to avoid CRLF/base64 parser issues.
    context.useCertificateChainBytes(utf8.encode(certPem));
    context.usePrivateKeyBytes(utf8.encode(keyPem));

    return HubTlsCredentials._(
      securityContext: context,
      sha256Pin: pin,
      certificatePem: certPem,
    );
  }

  static String _normalizePem(String pem) {
    // Normalize Windows CRLF and trim trailing whitespace across providers.
    return pem.replaceAll('\r', '').trim();
  }

  static Uint8List _pemToDer(String pem) {
    final normalized = _normalizePem(pem);
    final base64Body = normalized
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join()
        .replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim();
    return Uint8List.fromList(base64.decode(base64Body));
  }
}
