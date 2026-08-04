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
}
