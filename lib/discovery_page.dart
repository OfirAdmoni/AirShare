import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:network_info_plus/network_info_plus.dart';

import 'package:air_share/air_share_constants.dart';
import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/handshake_trace.dart';
import 'package:air_share/wlan_link_manager.dart';

/// Receiver: BLE scan and endpoint extraction until [onEndpointReady] completes.
class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({required this.onEndpointReady, super.key});

  final Future<void> Function(PeerEndpoint endpoint) onEndpointReady;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  StreamSubscription<List<BlePeer>>? _scanSubscription;
  final List<BlePeer> _peers = [];
  final Set<String> _seenPeers = <String>{};
  bool _isScanning = false;
  bool _isHandshaking = false;
  String _status = 'Peer Discovery via BLE';
  double _pulseScale = 1.0;
  Timer? _pulseTimer;
  static const int _endpointReadRetries = 5;

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

  bool _isRetriableEmptyEndpointError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('empty') ||
        msg.contains('malformed') ||
        msg.contains('invalid_endpoint_payload') ||
        msg.contains('peer endpoint read returned empty payload');
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

  Future<void> _logTcpVerifyApIsolationHint(PeerEndpoint endpoint) async {
    await ConnectionLogger.instance.log(
      'Network | Possible AP Isolation / Wi-Fi blocking P2P traffic. Hotspot fallback required',
      details:
          'target=${endpoint.ip}:${endpoint.port} (TCP verify timed out; if hub logs never show HTTP | First inbound, packets may not reach the hub)',
    );
  }

  /// On Android hotspot, the host advertises its tethering interface IP (e.g.
  /// 192.168.45.244) but iptables drops packets to that address from clients.
  /// The Wi-Fi gateway (e.g. 192.168.45.1) is the routable alias that does
  /// accept inbound TCP — try it as a fallback when the primary IP times out.
  /// Derives the likely gateway IP from an advertised host IP by replacing the
  /// last octet with 1 (e.g. 192.168.45.244 → 192.168.45.1), which matches
  /// the standard Android hotspot DHCP gateway assignment.
  String? _deriveGatewayIp(String advertisedIp) {
    final parts = advertisedIp.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.1';
  }

  Future<PeerEndpoint?> _tryGatewayFallback(PeerEndpoint endpoint) async {
    String? gatewayIp;
    try {
      gatewayIp = await NetworkInfo().getWifiGatewayIP();
    } catch (_) {}

    if (gatewayIp == null || gatewayIp.isEmpty) {
      final derived = _deriveGatewayIp(endpoint.ip);
      await ConnectionLogger.instance.log(
        'HS | TCP verify Fallback (Derived Gateway) | TRYING $derived',
        details: 'native_gateway=null advertised=${endpoint.ip} derived=$derived',
      );
      gatewayIp = derived;
    }

    if (gatewayIp == null || gatewayIp == endpoint.ip) {
      await ConnectionLogger.instance.log(
        'HS | TCP verify Fallback (Gateway) | SKIP',
        details: 'gatewayIp=${gatewayIp ?? 'null'} advertised=${endpoint.ip}',
      );
      return null;
    }

    try {
      await HandshakeTrace.run<void>(
        'TCP verify Fallback (Gateway)',
        () async {
          final socket = await Socket.connect(
            gatewayIp!,
            endpoint.port,
            timeout: const Duration(seconds: 10),
          );
          await socket.close();
        },
        extra: '$gatewayIp:${endpoint.port}',
        hardTimeout: const Duration(seconds: 14),
      );
      return PeerEndpoint(ip: gatewayIp, port: endpoint.port);
    } catch (_) {
      return null;
    }
  }

  Future<PeerEndpoint> _readEndpointWithRetries(BlePeer peer) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _endpointReadRetries; attempt++) {
      try {
        return await BleTransport.instance.readPeerEndpoint(peer);
      } catch (e) {
        lastError = e;
        if (!_isRetriableEmptyEndpointError(e) || attempt == _endpointReadRetries) {
          rethrow;
        }
        await ConnectionLogger.instance.log(
          'BLE | Retrying endpoint read',
          details: 'attempt=$attempt/$_endpointReadRetries',
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw Exception('Endpoint read failed: $lastError');
  }

  @override
  void initState() {
    super.initState();
    _startPulseAnimation();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startDiscovery());
  }

  @override
  void dispose() {
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
    try {
      await _ensureAndroidLocationForBle();
      if (!mounted) return;

      await _logNetworkInterfaces();
      await ConnectionLogger.instance.log('BLE Scan Start');
      await BleTransport.instance.startScanning();
      _scanSubscription?.cancel();
      _seenPeers.clear();
      _scanSubscription = BleTransport.instance.scanPeers().listen((peers) {
        for (final peer in peers) {
          if (_seenPeers.add(peer.id)) {
            ConnectionLogger.instance.log(
              'BLE Scan Peer Found',
              details: '${peer.friendlyName} (${peer.id})',
            );
          }
        }
        if (!mounted) return;
        setState(() {
          _peers
            ..clear()
            ..addAll(peers);
          _isScanning = true;
          _status = 'Peer Discovery via BLE';
        });
      });
      setState(() {
        _isScanning = true;
      });
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

    if (mounted) {
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _selectPeer(BlePeer peer) async {
    try {
      setState(() {
        _isHandshaking = true;
        _status = 'Waiting for peer to approve...';
      });

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

      // On Android with a Wi-Fi Direct host: use WifiP2pManager.connect() (proper P2P API)
      // so the guest's socket is routed over the p2p interface, bypassing hotspot iptables.
      // The returned groupOwnerIp overrides the BLE-advertised endpoint IP.
      String? p2pGroupOwnerIp;
      if (Platform.isAndroid && handshakePayload.p2pMac.isNotEmpty) {
        if (!mounted) return;
        setState(() => _status = 'Connecting to hub Wi-Fi Direct…');
        try {
          p2pGroupOwnerIp = await HandshakeTrace.run<String>(
            'WLAN connect (guest → hub P2P group)',
            () => WlanLinkManager.instance.connectToWifiDirectPeer(handshakePayload.p2pMac),
            extra: 'peerMac=${handshakePayload.p2pMac}',
            hardTimeout: const Duration(seconds: 35),
          );
          await ConnectionLogger.instance.log(
            'WLAN connect | P2P connected',
            details: 'groupOwnerIp=$p2pGroupOwnerIp',
          );
        } catch (e) {
          await ConnectionLogger.instance.log(
            'WLAN connect | P2P failed — proceeding with BLE-advertised IP',
            details: e.toString(),
          );
          p2pGroupOwnerIp = null;
        }
      }

      if (!mounted) return;
      setState(() {
        _status = 'Reading endpoint from peer…';
      });
      final endpoint = await _readEndpointWithRetries(peer);
      await ConnectionLogger.instance.log(
        'HS | Auth endpoint vs ServerHello',
        details:
            'endpoint=${endpoint.ip}:${endpoint.port} vs hello_hub=${handshakePayload.hubIp}:${handshakePayload.hubPort}',
      );
      await ConnectionLogger.instance.log(
        'BLE | Extracted IP',
        details: '${endpoint.ip}:${endpoint.port}',
      );
      debugPrint(
        'Network | Guest BLE endpoint (Auth): ${endpoint.ip}:${endpoint.port}',
      );
      // If the P2P connection succeeded, replace the BLE-advertised IP with
      // the confirmed group-owner IP (avoids stale/mismatched BLE values).
      final resolvedEndpoint = (p2pGroupOwnerIp != null && p2pGroupOwnerIp.isNotEmpty)
          ? PeerEndpoint(ip: p2pGroupOwnerIp, port: endpoint.port)
          : endpoint;
      if (resolvedEndpoint.ip != endpoint.ip) {
        await ConnectionLogger.instance.log(
          'Network | Endpoint overridden by P2P group owner',
          details: '${endpoint.ip} → ${resolvedEndpoint.ip}:${resolvedEndpoint.port}',
        );
      }

      if (!mounted) return;
      setState(() {
        _status = 'Triggering auto-connect…';
      });
      await ConnectionLogger.instance.log(
        'Connection | Triggering auto-connect',
        details: '${endpoint.ip}:${endpoint.port}',
      );
      var effectiveEndpoint = resolvedEndpoint;
      try {
        await HandshakeTrace.run<void>(
          'TCP verify (guest → hub HTTP port)',
          () async {
            final socket = await Socket.connect(
              resolvedEndpoint.ip,
              resolvedEndpoint.port,
              timeout: const Duration(seconds: 10),
            );
            await socket.close();
          },
          extra: '${resolvedEndpoint.ip}:${resolvedEndpoint.port}',
          hardTimeout: const Duration(seconds: 14),
        );
        await ConnectionLogger.instance.log(
          'Socket Connection Success',
          details: '${resolvedEndpoint.ip}:${resolvedEndpoint.port}',
        );
      } on TimeoutException catch (e) {
        await ConnectionLogger.instance.log(
          'Connection | Timeout trying to reach ${resolvedEndpoint.ip} - Check if devices are on the same Wi-Fi and if Client Isolation is active.',
          details: '$e',
        );
        await _logTcpVerifyApIsolationHint(resolvedEndpoint);
        if (resolvedEndpoint.ip.startsWith('10.') || resolvedEndpoint.ip.startsWith('172.')) {
          await ConnectionLogger.instance.log(
            'Network Hint',
            details: 'Potential Client Isolation detected on this network.',
          );
        }
        final gatewayEndpoint = await _tryGatewayFallback(resolvedEndpoint);
        if (gatewayEndpoint != null) {
          effectiveEndpoint = gatewayEndpoint;
        } else {
          rethrow;
        }
      } on SocketException catch (e) {
        final looksLikeTimeout = _looksLikeTcpTimeout(e);
        if (looksLikeTimeout) {
          await ConnectionLogger.instance.log(
            'Connection | Timeout trying to reach ${resolvedEndpoint.ip} - Check if devices are on the same Wi-Fi and if Client Isolation is active.',
            details: e.toString(),
          );
          await _logTcpVerifyApIsolationHint(resolvedEndpoint);
        } else {
          await ConnectionLogger.instance.log(
            'Socket Connection Failed',
            details: e.toString(),
          );
        }
        if (resolvedEndpoint.ip.startsWith('10.') || resolvedEndpoint.ip.startsWith('172.')) {
          await ConnectionLogger.instance.log(
            'Network Hint',
            details: 'Potential Client Isolation detected on this network.',
          );
        }
        if (looksLikeTimeout) {
          final gatewayEndpoint = await _tryGatewayFallback(resolvedEndpoint);
          if (gatewayEndpoint != null) {
            effectiveEndpoint = gatewayEndpoint;
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }
      await widget.onEndpointReady(effectiveEndpoint);
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'Handshake Failure',
        details: '${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] Handshake Failure stack:\n$st');
      if (!mounted) return;
      setState(() {
        _status = 'Peer Discovery via BLE';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Secure handshake failed: $e')));
    } finally {
      if (!mounted) return;
      setState(() {
        _isHandshaking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
            if (_isHandshaking)
              Row(
                children: const [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Waiting for sender to approve the connection...'),
                  ),
                ],
              ),
            if (_isHandshaking) const SizedBox(height: 8),
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
                            _isHandshaking
                                ? 'Waiting for sender to approve the connection...'
                                : _isScanning
                                ? 'Peer Discovery via BLE in progress…'
                                : 'No senders discovered',
                          ),
                          if (_isHandshaking) ...[
                            const SizedBox(height: 8),
                            const CircularProgressIndicator(strokeWidth: 2),
                          ],
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
                          onTap: _isHandshaking ? null : () => _selectPeer(peer),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await _stopDiscovery();
          await _startDiscovery();
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
