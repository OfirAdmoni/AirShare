import 'dart:io';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/device_branding.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable BLE-style peer id and display name for the local device.
class LocalPeerIdentity {
  LocalPeerIdentity._({
    required this.peerId,
    required this.displayName,
  });

  static LocalPeerIdentity? _cached;

  /// Clears the cached identity so the next [resolve] re-reads the current
  /// device name from storage. Call after saving a new name.
  static void invalidate() => _cached = null;

  final String peerId;
  final String displayName;

  static const String _prefPeerIdKey = 'air_share_local_peer_id';

  static Future<LocalPeerIdentity> resolve() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var peerId = prefs.getString(_prefPeerIdKey);
    if (peerId == null || peerId.trim().isEmpty) {
      if (Platform.isAndroid || Platform.isWindows) {
        try {
          peerId = await BleTransport.instance.getLocalPeerId();
        } catch (_) {
          peerId = null;
        }
      }
      peerId ??= 'local-${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString(_prefPeerIdKey, peerId);
    }
    final displayName = await DeviceBranding.effectiveAdvertisingName();
    _cached = LocalPeerIdentity._(peerId: peerId, displayName: displayName);
    return _cached!;
  }
}
