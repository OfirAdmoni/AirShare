import 'dart:convert';

/// Guest → host identity payload written to the handshake GATT characteristic
/// before the ServerHello read/notify exchange.
class ClientHello {
  ClientHello._();

  static const String wireType = 'client_hello';

  static Map<String, dynamic> toMap({
    required String peerId,
    required String displayName,
  }) =>
      {
        'type': wireType,
        'peer_id': peerId.trim(),
        'display_name': displayName.trim(),
      };

  static String encode({
    required String peerId,
    required String displayName,
  }) =>
      jsonEncode(
        toMap(
          peerId: peerId,
          displayName: displayName.isEmpty ? 'Guest' : displayName,
        ),
      );

  static ({String peerId, String displayName})? tryParse(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>?;
      if (map == null) return null;
      if ((map['type'] as String?)?.trim() != wireType) return null;
      final displayName = (map['display_name'] as String?)?.trim() ?? '';
      if (displayName.isEmpty) return null;
      final peerId = (map['peer_id'] as String?)?.trim() ?? '';
      return (peerId: peerId, displayName: displayName);
    } catch (_) {
      return null;
    }
  }
}
