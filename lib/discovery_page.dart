import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:air_share/air_share_constants.dart';
import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';

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
  bool _isScanning = false;
  bool _isHandshaking = false;
  String _status = 'Peer Discovery via BLE';
  double _pulseScale = 1.0;
  Timer? _pulseTimer;

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

      await ConnectionLogger.instance.log('BLE Scan Start');
      await BleTransport.instance.startScanning();
      _scanSubscription?.cancel();
      _scanSubscription = BleTransport.instance.scanPeers().listen((peers) {
        for (final peer in peers) {
          ConnectionLogger.instance.log(
            'BLE Scan Peer Found',
            details: '${peer.friendlyName} (${peer.id})',
          );
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
        _status = 'Reading endpoint from peer…';
      });

      await ConnectionLogger.instance.log(
        'BLE | Reading IP from peer...',
        details: 'peer=${peer.friendlyName} (${peer.id})',
      );
      final endpoint = await BleTransport.instance.readPeerEndpoint(peer);
      await ConnectionLogger.instance.log(
        'BLE | Extracted IP',
        details: '${endpoint.ip}:${endpoint.port}',
      );

      if (!mounted) return;
      setState(() {
        _status = 'Triggering auto-connect…';
      });
      await ConnectionLogger.instance.log(
        'Connection | Triggering auto-connect',
        details: '${endpoint.ip}:${endpoint.port}',
      );
      await widget.onEndpointReady(endpoint);
    } catch (e) {
      await ConnectionLogger.instance.log('Handshake Failure', details: e.toString());
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
                                ? 'Establishing secure link…'
                                : _isScanning
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
                            peer.serviceUuid == kAirShareBleServiceUuid
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
