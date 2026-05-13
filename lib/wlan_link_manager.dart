import 'package:flutter/services.dart';

class WlanLinkManager {
  WlanLinkManager._();

  static final WlanLinkManager instance = WlanLinkManager._();

  static const MethodChannel _channel = MethodChannel('air_share/wlan_link');

  Future<Map<dynamic, dynamic>?> startTemporaryHotspot({
    required String ssid,
    required String password,
    int? hubPort,
  }) async {
    return _channel.invokeMethod<Map<dynamic, dynamic>>('startTemporaryHotspot', {
      'ssid': ssid,
      'password': password,
      if (hubPort != null) 'hubPort': hubPort,
    });
  }

  Future<void> connectToHubWlan({
    required String ssid,
    required String password,
  }) async {
    await _channel.invokeMethod('connectToHubWlan', {
      'ssid': ssid,
      'password': password,
    });
  }

  Future<Map<dynamic, dynamic>?> startWifiDirectGroup() async {
    return _channel.invokeMethod<Map<dynamic, dynamic>>('startWifiDirectGroup');
  }

  Future<void> stopWifiDirectGroup() async {
    await _channel.invokeMethod<void>('stopWifiDirectGroup');
  }

  /// Connects to the Wi-Fi Direct group owned by [peerMac] using
  /// WifiP2pManager.connect(). Returns the group owner's IP address
  /// (typically "192.168.49.1") once the connection is established.
  Future<String> connectToWifiDirectPeer(String peerMac) async {
    final result = await _channel.invokeMethod<String>(
      'connectToWifiDirectPeer',
      {'peerMac': peerMac},
    );
    return result ?? '192.168.49.1';
  }
}
