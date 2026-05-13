import 'dart:async';

import 'package:air_share/air_share_constants.dart';
import 'package:air_share/handshake_trace.dart';
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
    this.p2pMac = '',
  });

  final String ssid;
  final String password;
  final String hubIp;
  final int hubPort;
  /// Wi-Fi Direct device address of the hub (e.g. "AA:BB:CC:DD:EE:FF").
  /// Empty string when the hub did not create a P2P group.
  final String p2pMac;

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
      p2pMac: (map['p2pMac'] ?? '').toString(),
    );
  }

  /// Log-safe summary (no password or SSID contents).
  String describeForLog() =>
      'hubIp=$hubIp hubPort=$hubPort ssid_len=${ssid.length} '
      'pwd_present=${password.isNotEmpty} p2pMac_present=${p2pMac.isNotEmpty}';
}

class PeerEndpoint {
  const PeerEndpoint({
    required this.ip,
    required this.port,
  });

  final String ip;
  final int port;

  factory PeerEndpoint.fromMap(Map<dynamic, dynamic> map) {
    final portRaw = map['port'];
    final port = portRaw is int ? portRaw : int.tryParse('${portRaw ?? ''}') ?? 8080;
    return PeerEndpoint(
      ip: (map['ip'] ?? '').toString(),
      port: port,
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
      final expectedUuid = kAirShareBleServiceUuid.toLowerCase();
      return event
          .whereType<Map>()
          .map(BlePeer.fromMap)
          .where((peer) => peer.serviceUuid.toLowerCase() == expectedUuid)
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
    final payload = await HandshakeTrace.run(
      'ClientHello→ServerHello (BLE read handshake JSON)',
      () async {
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
      },
      extra: 'peerId=${peer.id} name=${peer.friendlyName}',
      hardTimeout: const Duration(seconds: 45),
    );
    return payload;
  }

  Future<PeerEndpoint> readPeerEndpoint(BlePeer peer) async {
    final endpoint = await HandshakeTrace.run(
      'Auth (BLE read hub endpoint ip:port)',
      () async {
        final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
          'readPeerEndpoint',
          {
            'peerId': peer.id,
            'serviceUuid': peer.serviceUuid,
          },
        );
        if (raw == null) {
          throw Exception('Peer endpoint read returned empty payload');
        }
        return PeerEndpoint.fromMap(raw);
      },
      extra: 'peerId=${peer.id} name=${peer.friendlyName}',
      hardTimeout: const Duration(seconds: 60),
    );
    return endpoint;
  }

  Future<void> updateHubEndpoint({
    required String ip,
    required int port,
  }) async {
    await _methodChannel.invokeMethod(
      'updateHubEndpoint',
      {
        'ip': ip,
        'port': port,
      },
    );
  }
}
