import 'dart:convert';
import 'dart:math';

/// Session auth tokens issued after host approves [POST /join].
class HubAuth {
  HubAuth._();

  static final Map<String, String> _tokenToGuest = {};
  static final Random _rng = Random.secure();

  static int _sessionEpoch = 0;
  static final Map<String, int> _tokenEpoch = {};

  static const String headerName = 'x-airshare-auth-token';

  static void bindToSessionEpoch(int epoch) {
    if (epoch == _sessionEpoch) return;
    _sessionEpoch = epoch;
    _tokenToGuest.clear();
    _tokenEpoch.clear();
  }

  static int get sessionEpoch => _sessionEpoch;

  /// Creates a URL-safe random token bound to [guestName].
  static String issueToken(String guestName) {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    _tokenToGuest[token] = guestName.trim().isEmpty ? 'guest' : guestName.trim();
    _tokenEpoch[token] = _sessionEpoch;
    return token;
  }

  static bool isValidToken(String? token) {
    if (token == null || token.trim().isEmpty) return false;
    final key = token.trim();
    if (!_tokenToGuest.containsKey(key)) return false;
    return _tokenEpoch[key] == _sessionEpoch;
  }

  static String? guestNameFor(String? token) {
    if (token == null) return null;
    return _tokenToGuest[token.trim()];
  }

  static void revokeToken(String token) {
    _tokenToGuest.remove(token.trim());
  }

  static void revokeAll() {
    _tokenToGuest.clear();
    _tokenEpoch.clear();
  }
}
