import 'dart:io';

import 'package:flutter/services.dart';

class WlanLinkManager {
  WlanLinkManager._();

  static final WlanLinkManager instance = WlanLinkManager._();

  static const MethodChannel _channel = MethodChannel('air_share/wlan_link');

  bool get _isAndroidMobile => Platform.isAndroid;

  /// Verifies ACCESS_FINE_LOCATION is granted and GPS/location services are on.
  Future<void> ensureLocationForWifiTier() async {
    if (!_isAndroidMobile) return;
    await _channel.invokeMethod<void>('ensureLocationForWifiTier');
  }

  /// Removes an active Wi‑Fi Direct group and waits for the radio to settle (Tier 2 → 3).
  Future<void> teardownP2pBeforeHotspot() async {
    if (!_isAndroidMobile) return;
    await _channel.invokeMethod<void>('teardownP2pBeforeHotspot');
  }

  /// Android LocalOnlyHotspot ignores [ssid]/[password]; native returns system values.
  Future<Map<dynamic, dynamic>?> startTemporaryHotspot({
    int? hubPort,
    String? ssid,
    String? password,
  }) async {
    final args = <String, dynamic>{
      if (hubPort != null) 'hubPort': hubPort,
    };
    if (Platform.isWindows) {
      args['ssid'] = ssid ?? 'AirShareLink';
      args['password'] = password ?? 'AirShare@2026';
    }
    if (!Platform.isWindows && !_isAndroidMobile) {
      throw UnsupportedError('Temporary hotspot is only supported on Android and Windows');
    }
    return _channel.invokeMethod<Map<dynamic, dynamic>>('startTemporaryHotspot', args);
  }

  Future<void> connectToHubWlan({
    required String ssid,
    required String password,
  }) async {
    if (!_isAndroidMobile) {
      throw UnsupportedError('connectToHubWlan is only supported on Android');
    }
    await _channel.invokeMethod('connectToHubWlan', {
      'ssid': ssid,
      'password': password,
    });
  }

  Future<Map<dynamic, dynamic>?> startWifiDirectGroup() async {
    if (!_isAndroidMobile) {
      throw UnsupportedError('Wi‑Fi Direct is only supported on Android');
    }
    return _channel.invokeMethod<Map<dynamic, dynamic>>('startWifiDirectGroup');
  }

  Future<void> stopWifiDirectGroup() async {
    if (!_isAndroidMobile) return;
    await _channel.invokeMethod<void>('stopWifiDirectGroup');
  }

  /// Releases LocalOnlyHotspot (ap0) and related WLAN state on the host.
  Future<void> stopNativeHotspot() async {
    if (!_isAndroidMobile) return;
    await _channel.invokeMethod<void>('stopNativeHotspot');
  }

  /// Connects to the Wi-Fi Direct group owned by [peerMac] using
  /// WifiP2pManager.connect(). Returns the group owner's IP address
  /// (typically "192.168.49.1") once the connection is established.
  /// Opens the system wireless settings panel (Android).
  Future<void> openWirelessSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openWirelessSettings');
  }

  Future<String> connectToWifiDirectPeer(String peerMac) async {
    if (!_isAndroidMobile) {
      throw UnsupportedError('Wi‑Fi Direct is only supported on Android');
    }
    final result = await _channel.invokeMethod<String>(
      'connectToWifiDirectPeer',
      {'peerMac': peerMac},
    );
    return result ?? '192.168.49.1';
  }
}
