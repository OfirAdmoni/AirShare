import 'dart:convert';

/// Cross-platform wire format for BLE handshake JSON and HTTP headers.
///
/// All platforms must use these keys and encodings so Android, iOS, and Windows
/// can complete handshakes and authenticate with one another.
abstract final class WireContract {
  // BLE handshake JSON (UTF-8, snake_case primary keys).
  static const String lanIp = 'lan_ip';
  static const String p2pIp = 'p2p_ip';
  static const String p2pMac = 'p2p_mac';
  static const String hotspotSsid = 'hotspot_ssid';
  static const String hotspotPass = 'hotspot_pass';
  static const String hotspotHubIp = 'hotspot_hub_ip';
  static const String hubPort = 'hub_port';
  static const String hostPublicKey = 'host_public_key';
  /// Guest X25519 public key (base64url) written to BLE handshake before read/notify.
  static const String guestPublicKeyBle = 'guest_public_key';
  /// SHA-256 fingerprint of hub TLS certificate DER (lowercase hex, no colons).
  static const String tlsCertSha256 = 'tls_cert_sha256';

  // HTTP headers.
  static const String authorization = 'authorization';
  static const String guestPublicKey = 'x-airshare-guest-public-key';
  static const String requesterPeerId = 'x-airshare-requester-peer-id';
  static const String requesterRole = 'x-airshare-requester-role';
  static const String senderId = 'x-airshare-sender-id';
  static const String senderName = 'x-airshare-sender-name';

  static const String bearerScheme = 'Bearer';

  /// HKDF info label for session bearer derivation (must match on every platform).
  static const String bearerDerivationInfo = 'airshare.v1.bearer';

  /// HKDF salt for bearer derivation (UTF-8 bytes).
  static const String bearerDerivationSalt = 'airshare.v1';
}

/// Base64url encoding shared by BLE JSON fields and HTTP headers.
abstract final class WireEncoding {
  static String bytesToBase64Url(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static List<int> base64UrlToBytes(String encoded) {
    var normalized = encoded.replaceAll('-', '+').replaceAll('_', '/');
    final pad = normalized.length % 4;
    if (pad == 2) {
      normalized += '==';
    } else if (pad == 3) {
      normalized += '=';
    } else if (pad == 1) {
      throw FormatException('Invalid base64url length');
    }
    return base64Url.decode(normalized);
  }
}
