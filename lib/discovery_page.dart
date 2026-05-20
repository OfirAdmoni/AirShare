import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:air_share/air_share_constants.dart';
import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/connection_tier.dart';
import 'package:air_share/guest_connection_guard.dart';
import 'package:air_share/handshake_trace.dart';
import 'package:air_share/wlan_link_manager.dart';
import 'package:air_share/wifi_tier_prerequisites.dart';
import 'package:flutter/services.dart';

/// Receiver: BLE scan and endpoint extraction until [onEndpointReady] completes.
class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({required this.onEndpointReady, super.key});

  final Future<void> Function(PeerEndpoint endpoint) onEndpointReady;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

enum _GuestDiscoveryPhase {
  scanning,
  handshaking,
  connecting,
}

/// Static label only — no phase-driven UI churn during hotspot join.
const String _kHotspotConnectingOverlayMessage =
    'Connecting to Hub Hotspot...\nPlease approve the system prompt.';

class _DiscoveryPageState extends State<DiscoveryPage> {
  StreamSubscription<List<BlePeer>>? _scanSubscription;
  final List<BlePeer> _peers = [];
  final Set<String> _seenPeers = <String>{};
  _GuestDiscoveryPhase _phase = _GuestDiscoveryPhase.scanning;
  String _status = 'Peer Discovery via BLE';
  double _pulseScale = 1.0;
  Timer? _pulseTimer;

  bool get _connectionUiLocked =>
      _phase == _GuestDiscoveryPhase.handshaking ||
      _phase == _GuestDiscoveryPhase.connecting;

  bool get _isScanning => _phase == _GuestDiscoveryPhase.scanning;

  void _setPhase(_GuestDiscoveryPhase phase, String status) {
    if (!mounted) return;
    if (GuestConnectionGuard.isActive &&
        phase == _GuestDiscoveryPhase.scanning &&
        _phase != _GuestDiscoveryPhase.scanning) {
      debugPrint(
        '[Discovery] Blocked phase reset to scanning while connection active '
        '(requested status: $status)',
      );
      return;
    }
    setState(() {
      _phase = phase;
      _status = status;
    });
  }
  Future<void> _logNetworkInterfaces() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: true,
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        await ConnectionLogger.instance.log(
          'Network | Interface ${iface.name}: ${addr.address}',
        );
      }
    }
  }

  /// TCP probe failed: slow Wi‑Fi, or AP/client isolation (guest SYN never reaches hub).
  bool _looksLikeTcpTimeout(Object e) {
    if (e is TimeoutException) return true;
    if (e is SocketException) {
      final msg = e.message.toLowerCase();
      final osMsg = e.osError?.message.toLowerCase() ?? '';
      if (msg.contains('timed out') || osMsg.contains('timed out')) return true;
      if (e.osError?.errorCode == 110) return true; // ETIMEDOUT on Android/Linux
    }
    return false;
  }

  Future<PeerEndpoint?> _tryTcpConnect(String ip, int port) async {
    try {
      await HandshakeTrace.run<void>(
        'TCP verify (guest → hub HTTP port)',
        () async {
          final socket = await Socket.connect(
            ip,
            port,
            timeout: const Duration(seconds: 10),
          );
          await socket.close();
        },
        extra: '$ip:$port',
        hardTimeout: const Duration(seconds: 14),
      );
      await ConnectionLogger.instance.log(
        'Socket Connection Success',
        details: '$ip:$port',
      );
      return PeerEndpoint(ip: ip, port: port);
    } on TimeoutException catch (e) {
      await ConnectionLogger.instance.log(
        'Connection | TCP timeout',
        details: '$ip:$port $e',
      );
    } on SocketException catch (e) {
      if (_looksLikeTcpTimeout(e)) {
        await ConnectionLogger.instance.log(
          'Connection | TCP timeout (socket)',
          details: '$ip:$port $e',
        );
      } else {
        await ConnectionLogger.instance.log(
          'Socket Connection Failed',
          details: '$ip:$port $e',
        );
      }
    }
    final gateway = ConnectionTier.deriveGatewayIp(ip);
    if (gateway == null || gateway == ip) return null;
    try {
      await HandshakeTrace.run<void>(
        'TCP verify Fallback (Gateway)',
        () async {
          final socket = await Socket.connect(
            gateway,
            port,
            timeout: const Duration(seconds: 10),
          );
          await socket.close();
        },
        extra: '$gateway:$port',
        hardTimeout: const Duration(seconds: 14),
      );
      await ConnectionLogger.instance.log(
        'Socket Connection Success',
        details: 'gateway $gateway:$port',
      );
      return PeerEndpoint(ip: gateway, port: port);
    } catch (_) {
      return null;
    }
  }

  void _pauseDiscoverySideEffects() {
    _pulseTimer?.cancel();
    _pulseTimer = null;
  }

  /// Tier 2 only: permissions + WifiNetworkSpecifier (no TCP / Wi‑Fi probes before dialog).
  Future<void> _joinHostHotspotAp(HandshakePayload payload) async {
    if (!Platform.isAndroid || !payload.hasHotspot) return;

    await WifiTierPrerequisites.ensureReadyForWifiTier(context: context);
    if (!mounted) throw StateError('unmounted');

    final locationGranted = await WifiTierPrerequisites.ensureFineLocationPermission(
      context: context,
    );
    if (!locationGranted) {
      throw StateError(
        'Location permission is required to join the host Wi‑Fi network',
      );
    }
    if (!mounted) throw StateError('unmounted');

    await ConnectionLogger.instance.log(
      'Connection | Tier 2 hotspot',
      details: 'ssid_len=${payload.hotspotSsid.length}',
    );
    await HandshakeTrace.run<void>(
      'WLAN connect (guest → hub hotspot via WifiNetworkSpecifier)',
      () => WlanLinkManager.instance.connectToHubWlan(
        ssid: payload.hotspotSsid,
        password: payload.hotspotPass,
      ),
      extra: 'ssid_len=${payload.hotspotSsid.length}',
      hardTimeout: const Duration(seconds: 50),
    );
  }

  Future<PeerEndpoint?> _probeHubAfterHotspot(HandshakePayload payload, int port) async {
    final candidates = <String>[
      if (payload.hotspotHubIp.isNotEmpty) payload.hotspotHubIp,
      if (payload.p2pIp.isNotEmpty) payload.p2pIp,
      '192.168.43.1',
      '192.168.137.1',
    ];
    for (final ip in candidates) {
      final endpoint = await _tryTcpConnect(ip, port);
      if (endpoint != null) return endpoint;
    }
    return null;
  }

  Future<PeerEndpoint> _connectViaTierStrategy(HandshakePayload payload) async {
    final port = payload.hubPort;
    final skipWifiProbe = GuestConnectionGuard.isActive;

    // Android offline: join hotspot FIRST — no Wi‑Fi scans before system dialog.
    if (Platform.isAndroid && payload.hasHotspot) {
      if (!mounted) throw StateError('unmounted');
      try {
        await _joinHostHotspotAp(payload);
        final hotspotEndpoint = await _probeHubAfterHotspot(payload, port);
        if (hotspotEndpoint != null) return hotspotEndpoint;
        await ConnectionLogger.instance.log(
          'Connection | Tier 2 TCP failed after hotspot join',
          details: 'no hub reachable on candidate IPs',
        );
      } on PlatformException catch (e) {
        await ConnectionLogger.instance.log(
          'Connection | Tier 2 hotspot failed',
          details: '${e.code} ${e.message}',
        );
      } catch (e) {
        await ConnectionLogger.instance.log(
          'Connection | Tier 2 hotspot failed',
          details: e.toString(),
        );
      }
    }

    // Tier 1 — same LAN (primary, no P2P/hotspot radio use).
    if (payload.hasLan) {
      if (await ConnectionTier.guestOnSameLanAs(
        payload.lanIp,
        skipWifiProbe: skipWifiProbe,
      )) {
        if (!mounted) throw StateError('unmounted');
        _setPhase(_GuestDiscoveryPhase.connecting, 'Tier 1: Connecting over home Wi‑Fi…');
        await ConnectionLogger.instance.log(
          'Connection | Tier 1 LAN',
          details: '${payload.lanIp}:$port',
        );
        final lanEndpoint = await _tryTcpConnect(payload.lanIp, port);
        if (lanEndpoint != null) return lanEndpoint;
        await ConnectionLogger.instance.log(
          'Connection | Tier 1 failed',
          details: 'TCP to ${payload.lanIp}:$port',
        );
      } else {
        await ConnectionLogger.instance.log(
          'Connection | Tier 1 skipped',
          details: 'guest not on same subnet as ${payload.lanIp}',
        );
      }
    }

    // Tier 3 — Wi‑Fi Direct (last-resort fallback).
    if (Platform.isAndroid && payload.hasP2p) {
      if (!mounted) throw StateError('unmounted');
      await WifiTierPrerequisites.ensureReadyForWifiTier(context: context);
      if (!mounted) throw StateError('unmounted');
      _setPhase(_GuestDiscoveryPhase.connecting, 'Tier 3: Joining Wi‑Fi Direct group…');
      await ConnectionLogger.instance.log(
        'Connection | Tier 3 P2P',
        details: 'mac=${payload.p2pMac}',
      );
      try {
        final ownerIp = await HandshakeTrace.run<String>(
          'WLAN connect (guest → hub P2P group)',
          () => WlanLinkManager.instance.connectToWifiDirectPeer(payload.p2pMac),
          extra: 'peerMac=${payload.p2pMac}',
          hardTimeout: const Duration(seconds: 35),
        );
        final targetIp = payload.p2pIp.isNotEmpty ? payload.p2pIp : ownerIp;
        final p2pEndpoint = await _tryTcpConnect(targetIp, port);
        if (p2pEndpoint != null) return p2pEndpoint;
      } on PlatformException catch (e) {
        final reason = e.details?.toString() ?? '';
        await ConnectionLogger.instance.log(
          'Connection | Tier 3 P2P failed',
          details: '${e.code} $reason',
        );
        final busy = reason.contains('reason=2') || e.message?.contains('reason=2') == true;
        if (!busy && e.code != 'p2p_timeout') {
          // Non-busy hard failure — P2P is the last resort; no further tier to try.
        }
      } catch (e) {
        await ConnectionLogger.instance.log(
          'Connection | Tier 3 P2P failed',
          details: e.toString(),
        );
      }
    }

    throw Exception('All connection tiers failed (Hotspot → LAN → P2P)');
  }

  @override
  void initState() {
    super.initState();
    _startPulseAnimation();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startDiscovery());
  }

  @override
  void dispose() {
    GuestConnectionGuard.reset();
    _stopDiscovery();
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _startPulseAnimation() {
    _pulseTimer?.cancel();
    var grow = true;
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted) return;
      setState(() {
        _pulseScale = grow ? 1.08 : 1.0;
      });
      grow = !grow;
    });
  }

  /// Android: BLE scan needs Location services enabled (system requirement).
  Future<bool> _ensureAndroidLocationForBle() async {
    if (!Platform.isAndroid) return true;
    var enabled = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return false;
    if (enabled) return true;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn on Location'),
        content: const Text(
          'Android requires Location services (GPS) to be on for Bluetooth LE scanning. '
          'Without it, peer discovery usually finds no devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Continue anyway'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await Geolocator.openLocationSettings();
            },
            child: const Text('Open Location settings'),
          ),
        ],
      ),
    );
    enabled = await Geolocator.isLocationServiceEnabled();
    return enabled;
  }

  Future<void> _startDiscovery() async {
    if (GuestConnectionGuard.isActive || _connectionUiLocked) {
      debugPrint(
        '[Discovery] Ignoring _startDiscovery — connection in progress '
        '(guard=${GuestConnectionGuard.isActive} locked=$_connectionUiLocked)',
      );
      return;
    }
    try {
      if (!Platform.isWindows) {
        await _ensureAndroidLocationForBle();
      }
      if (!mounted) return;

      await _logNetworkInterfaces();
      await ConnectionLogger.instance.log('BLE Scan Start');
      await BleTransport.instance.startScanning();
      _scanSubscription?.cancel();
      _seenPeers.clear();
      _scanSubscription = BleTransport.instance.scanPeers().listen(
        (peers) {
          if (GuestConnectionGuard.isActive || _connectionUiLocked) return;
          for (final peer in peers) {
            if (_seenPeers.add(peer.id)) {
              ConnectionLogger.instance.log(
                'BLE Scan Peer Found',
                details: '${peer.friendlyName} (${peer.id})',
              );
            }
          }
          if (!mounted || GuestConnectionGuard.isActive || _connectionUiLocked) {
            return;
          }
          setState(() {
            _peers
              ..clear()
              ..addAll(peers);
            if (_phase == _GuestDiscoveryPhase.scanning) {
              _status = 'Peer Discovery via BLE';
            }
          });
        },
        onError: (Object e) {
          if (GuestConnectionGuard.isActive || _connectionUiLocked) {
            debugPrint(
              '[Discovery] Ignoring BLE scan stream error during connection: $e',
            );
            return;
          }
          debugPrint('[Discovery] BLE scan stream error: $e');
        },
      );
      _setPhase(_GuestDiscoveryPhase.scanning, 'Peer Discovery via BLE');
    } catch (e) {
      if (!mounted) return;
      debugPrint('[Discovery] start failed: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Peer discovery error: $e')));
    }
  }

  Future<void> _stopDiscovery() async {
    await BleTransport.instance.stopScanning();
    await _scanSubscription?.cancel();
    _scanSubscription = null;

    if (mounted &&
        !GuestConnectionGuard.isActive &&
        !_connectionUiLocked &&
        _phase == _GuestDiscoveryPhase.scanning) {
      _setPhase(_GuestDiscoveryPhase.scanning, _status);
    }
  }

  Future<void> _lockUiForConnection() async {
    _pauseDiscoverySideEffects();
    _setPhase(_GuestDiscoveryPhase.connecting, _kHotspotConnectingOverlayMessage);
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await BleTransport.instance.stopScanning();
    } catch (_) {}
  }

  Future<void> _selectPeer(BlePeer peer) async {
    GuestConnectionGuard.enter();
    _pauseDiscoverySideEffects();
    try {
      _setPhase(_GuestDiscoveryPhase.handshaking, _kHotspotConnectingOverlayMessage);

      await ConnectionLogger.instance.log(
        'BLE | Handshake sequence start',
        details: 'peer=${peer.friendlyName} (${peer.id})',
      );
      final handshakePayload =
          await BleTransport.instance.establishSecureHandshake(peer);
      await ConnectionLogger.instance.log(
        'HS | ServerHello payload (BLE JSON, log-safe)',
        details: handshakePayload.describeForLog(),
      );

      if (!mounted) return;
      await _lockUiForConnection();
      if (!mounted) return;
      final effectiveEndpoint = await _connectViaTierStrategy(handshakePayload);

      if (!mounted) return;
      _setPhase(_GuestDiscoveryPhase.connecting, 'Opening file console…');
      await ConnectionLogger.instance.log(
        'Connection | Tier strategy succeeded',
        details: '${effectiveEndpoint.ip}:${effectiveEndpoint.port}',
      );
      GuestConnectionGuard.exit();
      await widget.onEndpointReady(effectiveEndpoint);
      // Gap 5 fix: reset to scanning so the user is not stuck on the
      // connecting overlay after backing out of FileListScreen.
      if (mounted) {
        _setPhase(_GuestDiscoveryPhase.scanning, 'Peer Discovery via BLE');
        await _startDiscovery();
      }
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'Handshake Failure',
        details: '${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] Handshake Failure stack:\n$st');
      if (!mounted) return;
      final wasHandshaking = _phase == _GuestDiscoveryPhase.handshaking;
      if (wasHandshaking) {
        GuestConnectionGuard.exit();
        _setPhase(_GuestDiscoveryPhase.scanning, 'Peer Discovery via BLE');
        await _startDiscovery();
      } else {
        GuestConnectionGuard.exit();
        _setPhase(
          _GuestDiscoveryPhase.connecting,
          'Connection failed — tap ← back to search again',
        );
      }
      final message = e is PlatformException
          ? '${e.code}: ${e.message ?? e.details ?? "unknown"}'
          : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasHandshaking
                ? 'Secure handshake failed: $message'
                : 'Connection failed: $message',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    } finally {
      if (!mounted) return;
      if (_phase == _GuestDiscoveryPhase.handshaking) {
        GuestConnectionGuard.exit();
        _setPhase(_GuestDiscoveryPhase.scanning, 'Peer Discovery via BLE');
        await _startDiscovery();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_connectionUiLocked) {
      return Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
        ),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 28),
                  Text(
                    _kHotspotConnectingOverlayMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Peer Discovery via BLE')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Service UUID: $kAirShareBleServiceUuid',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _peers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedScale(
                            scale: _pulseScale,
                            duration: const Duration(milliseconds: 500),
                            child: const Icon(Icons.bluetooth_searching, size: 42),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isScanning
                                ? 'Peer Discovery via BLE in progress…'
                                : 'No senders discovered',
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _peers.length,
                      itemBuilder: (context, index) {
                        final peer = _peers[index];

                        return ListTile(
                          leading: const Icon(Icons.hub),
                          title: Text(peer.friendlyName),
                          subtitle: Text(
                            peer.serviceUuid.toLowerCase() ==
                                    kAirShareBleServiceUuid.toLowerCase()
                                ? 'Transfer hub • $kAirShareBleServiceUuid'
                                : 'UUID ${peer.serviceUuid}',
                          ),
                          onTap: _connectionUiLocked ? null : () => _selectPeer(peer),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: _connectionUiLocked
          ? null
          : FloatingActionButton(
              onPressed: () async {
                await _stopDiscovery();
                await _startDiscovery();
              },
              child: const Icon(Icons.refresh),
            ),
    );
  }
}
