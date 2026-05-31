import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:air_share/connection_tier.dart';
import 'package:air_share/hub_session_registry.dart';

/// HTTPS-only hub client with BLE-pinned certificate fingerprints.
abstract final class HubHttpClient {
  static const String scheme = 'https';

  static String baseUrlFor(String host, int port) => '$scheme://$host:$port';

  /// Pinned [http.Client] for guest or host file transfers.
  static http.Client createPinned({required String expectedCertSha256Hex}) {
    final expected = _normalizeFingerprint(expectedCertSha256Hex);
    if (expected.isEmpty) {
      throw ArgumentError('TLS certificate fingerprint is required');
    }

    final ioClient = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (cert, host, port) {
        return _fingerprintMatches(cert, expected);
      }
      // Avoid system HTTP proxy / cellular fallback (critical for Android Tier 2 hotspot).
      ..findProxy = (_) => 'DIRECT';
    return IOClient(ioClient);
  }

  /// Uses [HubSessionRegistry] TLS fingerprint (host or guest handshake).
  static http.Client fromRegistry() {
    final fp = HubSessionRegistry.instance.expectedTlsFingerprint ??
        HubSessionRegistry.instance.tls?.certSha256Hex;
    if (fp == null || fp.isEmpty) {
      throw StateError('Hub TLS fingerprint is not available');
    }
    return createPinned(expectedCertSha256Hex: fp);
  }

  static bool _fingerprintMatches(X509Certificate cert, String expectedHex) {
    final der = cert.der;
    if (der.isEmpty) return false;
    final actual = sha256.convert(der).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return actual == expectedHex;
  }

  static String _normalizeFingerprint(String raw) {
    return raw.trim().toLowerCase().replaceAll(':', '').replaceAll(' ', '');
  }

  /// TLS reachability probe (401/200 both mean the HTTPS hub is up).
  ///
  /// When [asGuest] is true, refuses loopback and any address on this device so
  /// receivers cannot hit a local hub runtime (loopback ghost).
  static Future<bool> probeHub({
    required String host,
    required int port,
    required String expectedCertSha256Hex,
    bool asGuest = true,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (asGuest) {
      final rejection = await ConnectionTier.guestHubTargetRejectionReason(host);
      if (rejection != null) {
        return false;
      }
    }
    final client = createPinned(expectedCertSha256Hex: expectedCertSha256Hex);
    try {
      final uri = Uri.parse('${baseUrlFor(host, port)}/files');
      final response = await client.get(uri).timeout(timeout);
      return response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.unauthorized;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
