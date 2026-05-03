import 'dart:async';

import 'package:air_share/air_share_constants.dart';
import 'package:flutter/services.dart';

class BlePeer {
  const BlePeer({
    required this.id,
    required this.friendlyName,
    required this.serviceUuid,
  });

  final String id;
  final String friendlyName;
  final String serviceUuid;

  factory BlePeer.fromMap(Map<dynamic, dynamic> map) {
    return BlePeer(
      id: (map['id'] ?? '').toString(),
      friendlyName: (map['friendlyName'] ?? 'Unknown Peer').toString(),
      serviceUuid: (map['serviceUuid'] ?? '').toString(),
    );
  }
}

class HandshakePayload {
  const HandshakePayload({
    required this.ssid,
    required this.password,
    required this.hubIp,
    this.hubPort = 8080,
  });

  final String ssid;
  final String password;
  final String hubIp;
  final int hubPort;

  factory HandshakePayload.fromMap(Map<dynamic, dynamic> map) {
    final portRaw = map['hubPort'];
    final port = portRaw is int
        ? portRaw
        : int.tryParse(portRaw?.toString() ?? '') ?? 8080;
    return HandshakePayload(
      ssid: (map['ssid'] ?? '').toString(),
      password: (map['password'] ?? '').toString(),
      hubIp: (map['hubIp'] ?? '').toString(),
      hubPort: port,
    );
  }
}

class BleTransport {
  BleTransport._();

  static final BleTransport instance = BleTransport._();
  static String get airShareServiceUuid => kAirShareBleServiceUuid;

  static const MethodChannel _methodChannel = MethodChannel(
    'air_share/ble_transport',
  );
  static const MethodChannel _uiChannel = MethodChannel('air_share/ble_ui');
  static const EventChannel _scanChannel = EventChannel(
    'air_share/ble_scan_events',
  );

  Stream<List<BlePeer>> scanPeers() {
    return _scanChannel.receiveBroadcastStream().map((event) {
      if (event is! List) return const <BlePeer>[];
      return event
          .whereType<Map>()
          .map(BlePeer.fromMap)
          .where((peer) => peer.serviceUuid == kAirShareBleServiceUuid)
          .toList();
    });
  }

  Future<void> startScanning() async {
    await _methodChannel.invokeMethod('startScanning', {
      'serviceUuid': airShareServiceUuid,
    });
  }

  Future<void> stopScanning() async {
    await _methodChannel.invokeMethod('stopScanning');
  }

  Future<void> startHubAdvertising({required String friendlyName}) async {
    await _methodChannel.invokeMethod('startHubAdvertising', {
      'friendlyName': friendlyName,
      'serviceUuid': airShareServiceUuid,
    });
  }

  Future<void> stopHubAdvertising() async {
    await _methodChannel.invokeMethod('stopHubAdvertising');
  }

  Future<void> approveConnection({required bool approved}) async {
    await _methodChannel.invokeMethod('approveConnection', {
      'approved': approved,
    });
  }

  void setUiHandler(Future<dynamic> Function(MethodCall call) handler) {
    _uiChannel.setMethodCallHandler(handler);
  }

  Future<HandshakePayload> establishSecureHandshake(BlePeer peer) async {
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'establishSecureHandshake',
      {
        'peerId': peer.id,
        'serviceUuid': peer.serviceUuid,
      },
    );
    if (raw == null) {
      throw Exception('Secure handshake returned empty payload');
    }
    return HandshakePayload.fromMap(raw);
  }
}
