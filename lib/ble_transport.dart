import 'dart:async';
import 'dart:io';

import 'package:air_share/air_share_constants.dart';
import 'package:air_share/handshake_trace.dart';
import 'package:air_share/platform_guards.dart';
import 'package:air_share/wire_contract.dart';
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
    this.hostPublicKey = '',
    this.tlsCertSha256 = '',
    this.hostPlatform = '',
  });

  final String lanIp;
  final String p2pIp;
  final String p2pMac;
  final String hotspotSsid;
  final String hotspotPass;
  /// Hub IPv4 on the hotspot interface (tier 3).
  final String hotspotHubIp;
  final int hubPort;
  /// X25519 public key (base64url) for ECDH session bearer derivation.
  final String hostPublicKey;
  final String tlsCertSha256;
  /// Host OS hint for Tier 2 gateway selection (`android` / `ios` / `windows`).
  final String hostPlatform;

  bool get hasTlsFingerprint => tlsCertSha256.isNotEmpty;

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

  /// Prefer explicit [lan_ip]. [hubIp] is accepted as LAN only when no hotspot
  /// is present (legacy Windows BLE parser / older payloads).
  factory HandshakePayload.fromMap(Map<dynamic, dynamic> map) {
    final portRaw = map['hub_port'] ?? map['hubPort'];
    final port = portRaw is int
        ? portRaw
        : int.tryParse(portRaw?.toString() ?? '') ?? 8080;
    final hotspotSsid = (map['hotspot_ssid'] ?? map['ssid'] ?? '').toString();
    var lan = (map['lan_ip'] ?? '').toString();
    if (lan.isEmpty && hotspotSsid.isEmpty) {
      final legacyHub = (map['hubIp'] ?? '').toString();
      if (legacyHub.isNotEmpty) lan = legacyHub;
    }
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
      hostPublicKey: (map[WireContract.hostPublicKey] ?? '').toString(),
      tlsCertSha256: (map[WireContract.tlsCertSha256] ?? '').toString(),
      hostPlatform: (map['host_platform'] ?? map['platform'] ?? '').toString(),
    );
  }

  String describeForLog() =>
      'lan_ip=$lanIp p2p_ip=$p2pIp p2p_mac_present=${p2pMac.isNotEmpty} '
      'hotspot_present=${hotspotSsid.isNotEmpty} hub_port=$hubPort '
      'tls_fp_present=${tlsCertSha256.isNotEmpty} '
      'host_pk_present=${hostPublicKey.isNotEmpty}';
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

  /// Whether the Bluetooth adapter is powered on (native BLE targets only).
  Future<bool> isBluetoothEnabled() async {
    if (!PlatformGuards.supportsBleTransport) return true;
    final enabled = await _methodChannel.invokeMethod<bool>('isBluetoothEnabled');
    return enabled ?? false;
  }

  /// Android: launches [BluetoothAdapter.ACTION_REQUEST_ENABLE] when BT is off.
  Future<bool> requestEnableBluetooth() async {
    if (!PlatformGuards.isAndroid) return true;
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
    if (!PlatformGuards.supportsBleTransport) return;
    await _methodChannel.invokeMethod('startScanning', {
      'serviceUuid': airShareServiceUuid,
    });
  }

  Future<void> stopScanning() async {
    if (!PlatformGuards.supportsBleTransport) return;
    await resetGuestHandshakeState();
    await _methodChannel.invokeMethod('stopScanning');
  }

  /// Clears in-flight guest GATT client, notify subscriptions, and handshake waiters.
  Future<void> resetGuestHandshakeState() async {
    if (!PlatformGuards.supportsBleTransport) return;
    try {
      await _methodChannel.invokeMethod<void>('resetGuestHandshakeState');
    } catch (_) {}
  }

  /// Clears per-peer host approvals and BLE notify subscriber state on the GATT server.
  Future<void> resetHostHandshakeState() async {
    if (!PlatformGuards.supportsBleTransport) return;
    try {
      await _methodChannel.invokeMethod<void>('resetHostHandshakeState');
    } catch (_) {}
  }

  Future<void> startHubAdvertising({required String friendlyName}) async {
    if (!PlatformGuards.supportsBleTransport) return;
    await _methodChannel.invokeMethod('startHubAdvertising', {
      'friendlyName': friendlyName,
      'serviceUuid': airShareServiceUuid,
    });
  }

  Future<void> stopHubAdvertising() async {
    if (!PlatformGuards.supportsBleTransport) return;
    await resetHostHandshakeState();
    await _methodChannel.invokeMethod('stopHubAdvertising');
  }

  /// Approves or declines a guest session ([sessionKey] = guest ECDH public key, base64url).
  Future<void> approveConnection({
    required bool approved,
    String sessionKey = '',
    String hostPublicKey = '',
  }) async {
    if (!PlatformGuards.supportsBleTransport) return;
    await _methodChannel.invokeMethod('approveConnection', {
      'approved': approved,
      if (sessionKey.isNotEmpty) 'peerId': sessionKey,
      if (sessionKey.isNotEmpty) 'sessionKey': sessionKey,
      if (hostPublicKey.isNotEmpty) 'hostPublicKey': hostPublicKey,
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
    String hostPublicKey = '',
    String tlsCertSha256 = '',
  }) async {
    if (!PlatformGuards.supportsBleTransport) return;
    await _methodChannel.invokeMethod('updateConnectionEndpoints', {
      'lanIp': lanIp,
      'p2pIp': p2pIp,
      'p2pMac': p2pMac,
      'hotspotSsid': hotspotSsid,
      'hotspotPass': hotspotPass,
      'hotspotHubIp': hotspotHubIp,
      'hubPort': hubPort,
      'hostPublicKey': hostPublicKey,
      'tlsCertSha256': tlsCertSha256,
    });
  }

  /// Waits for host approval via GATT notification (no read polling).
  Future<HandshakePayload> establishSecureHandshake(
    BlePeer peer, {
    required String guestPublicKey,
  }) async {
    if (!PlatformGuards.supportsBleTransport) {
      throw UnsupportedError('BLE handshake is not available on this platform');
    }
    final guestPk = guestPublicKey.trim();
    if (guestPk.isEmpty) {
      throw ArgumentError('guestPublicKey is required for BLE handshake');
    }
    // Stop scanning before GATT client work so the native stack can deliver notifications.
    await stopScanning();
    final payload = await HandshakeTrace.run(
      'ClientHello→ServerHello (BLE notify handshake JSON)',
      () async {
        final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
          'establishSecureHandshake',
          {
            'peerId': peer.id,
            'serviceUuid': peer.serviceUuid,
            'guestPublicKey': guestPk,
          },
        );
        if (raw == null) {
          throw Exception('Secure handshake returned empty payload');
        }
        return HandshakePayload.fromMap(raw);
      },
      extra:
          'peerId=${peer.id} guestPk=${guestPk.length > 12 ? '${guestPk.substring(0, 12)}…' : guestPk} name=${peer.friendlyName}',
      hardTimeout: const Duration(seconds: 45),
    );
    return payload;
  }

  /// After [establishSecureHandshake], waits for host Approve via GATT notification
  /// (Windows) or native notify/read (mobile). Do not poll the characteristic in Dart.
  Future<HandshakePayload> waitForSessionHandshake(
    BlePeer peer, {
    String guestPublicKey = '',
  }) async {
    if (!PlatformGuards.supportsBleTransport) {
      throw UnsupportedError('BLE session wait is not available on this platform');
    }
    final guestPk = guestPublicKey.trim();
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'waitForSessionHandshake',
      {
        'peerId': peer.id,
        'serviceUuid': peer.serviceUuid,
        if (guestPk.isNotEmpty) 'guestPublicKey': guestPk,
        if (guestPk.isNotEmpty) 'sessionKey': guestPk,
      },
    );
    if (raw == null) {
      throw Exception('Session handshake wait returned empty payload');
    }
    return HandshakePayload.fromMap(raw);
  }

  Future<PeerEndpoint> readPeerEndpoint(BlePeer peer) async {
    if (!PlatformGuards.supportsBleTransport) {
      throw UnsupportedError('BLE endpoint read is not available on this platform');
    }
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
    String hostPublicKey = '',
  }) async {
    if (!PlatformGuards.supportsBleTransport) return;
    await _methodChannel.invokeMethod(
      'updateHubEndpoint',
      {
        'ip': ip,
        'port': port,
        if (hostPublicKey.isNotEmpty) 'hostPublicKey': hostPublicKey,
      },
    );
  }

  /// Local BLE peer id (Android BT address when available, else stable persisted id).
  Future<String> getLocalPeerId() async {
    if (!PlatformGuards.isAndroid && !PlatformGuards.isWindows) {
      throw UnsupportedError(
        'getLocalPeerId is only supported on Android and Windows',
      );
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
