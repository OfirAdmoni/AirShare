import 'dart:async';
import 'dart:io';

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

/// 3-tier handshake payload broadcast by the host over BLE GATT.
class HandshakePayload {
  const HandshakePayload({
    this.lanIp = '',
    this.p2pIp = '',
    this.p2pMac = '',
    this.hotspotSsid = '',
    this.hotspotPass = '',
    this.hotspotHubIp = '',
    this.hubPort = 8080,
  });

  final String lanIp;
  final String p2pIp;
  final String p2pMac;
  final String hotspotSsid;
  final String hotspotPass;
  /// Hub IPv4 on the hotspot interface (tier 3).
  final String hotspotHubIp;
  final int hubPort;

  /// Legacy primary hub IP (LAN preferred, then hotspot, then P2P).
  String get hubIp {
    if (lanIp.isNotEmpty) return lanIp;
    if (hotspotHubIp.isNotEmpty) return hotspotHubIp;
    if (p2pIp.isNotEmpty) return p2pIp;
    return '';
  }

  String get ssid => hotspotSsid;
  String get password => hotspotPass;

  bool get hasLan => lanIp.isNotEmpty;
  bool get hasP2p => p2pMac.isNotEmpty;
  bool get hasHotspot => hotspotSsid.isNotEmpty && hotspotPass.isNotEmpty;

  /// [lan_ip] must be explicit in JSON — never alias [hubIp] (often ap0) into Tier 1 LAN.
  factory HandshakePayload.fromMap(Map<dynamic, dynamic> map) {
    final portRaw = map['hub_port'] ?? map['hubPort'];
    final port = portRaw is int
        ? portRaw
        : int.tryParse(portRaw?.toString() ?? '') ?? 8080;
    final lan = (map['lan_ip'] ?? '').toString();
    final hotspotSsid = (map['hotspot_ssid'] ?? map['ssid'] ?? '').toString();
    final hotspotHubRaw = (map['hotspot_hub_ip'] ?? '').toString();
    final legacyHub = (map['hubIp'] ?? '').toString();
    final hotspotHubIp = hotspotHubRaw.isNotEmpty
        ? hotspotHubRaw
        : (hotspotSsid.isNotEmpty ? legacyHub : '');
    return HandshakePayload(
      lanIp: lan,
      p2pIp: (map['p2p_ip'] ?? '').toString(),
      p2pMac: (map['p2p_mac'] ?? map['p2pMac'] ?? '').toString(),
      hotspotSsid: hotspotSsid,
      hotspotPass: (map['hotspot_pass'] ?? map['password'] ?? '').toString(),
      hotspotHubIp: hotspotHubIp,
      hubPort: port,
    );
  }

  String describeForLog() =>
      'lan_ip=$lanIp p2p_ip=$p2pIp p2p_mac_present=${p2pMac.isNotEmpty} '
      'hotspot_present=${hotspotSsid.isNotEmpty} hub_port=$hubPort';
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

  /// Android and Windows: whether the Bluetooth adapter is powered on.
  Future<bool> isBluetoothEnabled() async {
    if (!Platform.isAndroid && !Platform.isWindows) return true;
    final enabled = await _methodChannel.invokeMethod<bool>('isBluetoothEnabled');
    return enabled ?? false;
  }

  /// Android: launches [BluetoothAdapter.ACTION_REQUEST_ENABLE] when BT is off.
  Future<bool> requestEnableBluetooth() async {
    if (!Platform.isAndroid) return true;
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'requestEnableBluetooth',
    );
    return raw?['enabled'] == true;
  }

  /// Opens the system Bluetooth settings panel.
  /// Android: navigates to Settings.ACTION_BLUETOOTH_SETTINGS.
  /// Windows: opens ms-settings:bluetooth.
  Future<void> openBluetoothSettings() async {
    if (Platform.isAndroid) {
      await _methodChannel.invokeMethod<void>('openBluetoothSettings');
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', 'ms-settings:bluetooth']);
    }
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

  /// Pushes all tier endpoints to native before guest approval.
  Future<void> updateConnectionEndpoints({
    required String lanIp,
    required String p2pIp,
    required String p2pMac,
    required String hotspotSsid,
    required String hotspotPass,
    required String hotspotHubIp,
    required int hubPort,
  }) async {
    if (Platform.isWindows) {
      final primary = lanIp.isNotEmpty
          ? lanIp
          : (p2pIp.isNotEmpty ? p2pIp : hotspotHubIp);
      await updateHubEndpoint(ip: primary, port: hubPort);
      return;
    }
    await _methodChannel.invokeMethod('updateConnectionEndpoints', {
      'lanIp': lanIp,
      'p2pIp': p2pIp,
      'p2pMac': p2pMac,
      'hotspotSsid': hotspotSsid,
      'hotspotPass': hotspotPass,
      'hotspotHubIp': hotspotHubIp,
      'hubPort': hubPort,
    });
  }

  /// Waits for host approval via GATT notification (no read polling).
  Future<HandshakePayload> establishSecureHandshake(BlePeer peer) async {
    final payload = await HandshakeTrace.run(
      'ClientHello→ServerHello (BLE notify handshake JSON)',
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

  /// Local BLE peer id (Android BT address when available, else stable persisted id).
  Future<String> getLocalPeerId() async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw UnsupportedError('getLocalPeerId is only supported on Android and Windows');
    }
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'getLocalPeerId',
    );
    final id = raw?['peerId']?.toString().trim();
    if (id == null || id.isEmpty) {
      throw Exception('getLocalPeerId returned empty id');
    }
    return id;
  }
}
