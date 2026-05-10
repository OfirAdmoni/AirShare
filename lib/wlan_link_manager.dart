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
}
