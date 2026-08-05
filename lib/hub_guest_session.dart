/// Guest-side TLS pin + auth token from BLE handshake and [POST /join].
class HubGuestSession {
  HubGuestSession._();

  static final HubGuestSession instance = HubGuestSession._();

  String? tlsCertSha256Pin;
  String? authToken;

  void applyHandshakePin(String? pin) {
    final trimmed = pin
        ?.replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim()
        .toLowerCase();
    tlsCertSha256Pin =
        (trimmed != null && trimmed.isNotEmpty) ? trimmed : tlsCertSha256Pin;
  }

  void applyJoinToken(String? token) {
    final trimmed = token
        ?.replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim();
    authToken = (trimmed != null && trimmed.isNotEmpty) ? trimmed : authToken;
  }

  void clear() {
    tlsCertSha256Pin = null;
    authToken = null;
  }
}
