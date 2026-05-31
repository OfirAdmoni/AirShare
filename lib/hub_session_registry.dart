import 'package:air_share/hub_auth.dart';
import 'package:air_share/hub_tls_credentials.dart';

/// In-memory session credentials for the active send/receive flow.
class HubSessionRegistry {
  HubSessionRegistry._();

  static final HubSessionRegistry instance = HubSessionRegistry._();

  HostHubSession? host;
  GuestHubSession? guest;
  HubTlsCredentials? tls;

  /// Guest: SHA-256 fingerprint from BLE handshake (pins HTTPS client).
  String? expectedTlsFingerprint;

  void clear() {
    host = null;
    guest = null;
    tls = null;
    expectedTlsFingerprint = null;
  }
}