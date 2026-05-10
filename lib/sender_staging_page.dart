import 'dart:io';

import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/wlan_link_manager.dart';

/// Sender (hub): start BLE advertising immediately, then HTTP hub + hotspot with matching port.
class SenderStagingPage extends StatefulWidget {
  const SenderStagingPage({super.key});

  @override
  State<SenderStagingPage> createState() => _SenderStagingPageState();
}

class _SenderStagingPageState extends State<SenderStagingPage> {
  String _status = 'Preparing hub…';
  String? _currentAdvertisedIp;
  String? _networkWarning;
  Object? _error;
  bool _isPreparing = false;
  bool _prepareStarted = false;

  HubStatus get _hubStatus => HubStatusScope.of(context);

  bool _isRealAdvertisableIp(String ip) {
    final candidate = ip.trim();
    if (candidate.isEmpty || candidate == '127.0.0.1') return false;
    final isLan = candidate.startsWith('192.168.') || candidate.startsWith('10.');
    if (!isLan) return false;
    final knownVirtualRanges = <String>[
      '192.168.56.',
      '192.168.153.',
      '192.168.188.',
      '192.168.232.',
    ];
    for (final prefix in knownVirtualRanges) {
      if (candidate.startsWith(prefix)) return false;
    }
    return true;
  }

  bool _isHotspotFallbackIp(String ip) {
    return ip.trim().startsWith('192.168.137.');
  }

  bool _isPreferredLanIp(String ip) {
    return _isRealAdvertisableIp(ip) && !_isHotspotFallbackIp(ip);
  }

  String? _pickRealIp(List<String?> candidates) {
    String? hotspotFallback;
    for (final candidate in candidates) {
      final value = (candidate ?? '').trim();
      if (!_isRealAdvertisableIp(value)) continue;
      if (_isHotspotFallbackIp(value)) {
        hotspotFallback ??= value;
        continue;
      }
      return value;
    }
    return hotspotFallback;
  }

  bool _isLikelyCellularOrWan(String name) {
    final lower = name.toLowerCase();
    return lower.contains('rmnet') ||
        lower.contains('cell') ||
        lower.contains('wwan') ||
        lower.contains('mobile') ||
        lower.contains('tun') ||
        lower.contains('tap') ||
        lower.contains('vbox') ||
        lower.contains('vmnet') ||
        lower.contains('vpn');
  }

  Future<String?> _pickInterfaceIp() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    String? fallback;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        await ConnectionLogger.instance.log(
          'Network | Interface ${iface.name}: ${addr.address}',
        );
        if (!_isRealAdvertisableIp(addr.address)) {
          continue;
        }
        if (!_isLikelyCellularOrWan(iface.name)) {
          return addr.address;
        }
        fallback ??= addr.address;
      }
    }
    return fallback;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_prepareStarted) return;
      _prepareStarted = true;
      _prepareSender();
    });
  }

  Future<void> _prepareSender() async {
    if (!mounted || _isPreparing) return;
    setState(() {
      _isPreparing = true;
      _status = 'Starting BLE advertisement…';
      _error = null;
    });

    try {
      final advertiseAs = await DeviceBranding.effectiveAdvertisingName();
      await ConnectionLogger.instance.log('BLE Advertise Start', details: advertiseAs);
      await BleTransport.instance.startHubAdvertising(
        friendlyName: advertiseAs,
      );
      await ConnectionLogger.instance.log('BLE Advertise Result', details: 'success');
      if (!mounted) return;
      setState(() => _status = 'Starting local HTTP hub…');

      await LocalHubRuntime.instance.ensureStarted(_hubStatus);
      final port = LocalHubRuntime.instance.activePort;
      await ConnectionLogger.instance.log('HTTP Server Start', details: 'port=$port');
      await ConnectionLogger.instance.log(
        'HTTP Server | Listening on all interfaces (0.0.0.0:$port)',
      );
      final networkInfo = NetworkInfo();
      final discoveredIp = (await networkInfo.getWifiIP())?.trim();
      final interfaceIp = await _pickInterfaceIp();
      await ConnectionLogger.instance.log(
        'Self IP discovered',
        details:
            'network_info=${discoveredIp ?? "unavailable"}, interface_pick=${interfaceIp ?? "none"}',
      );

      if (!mounted) return;
      final existingLanIp = _pickRealIp([interfaceIp, discoveredIp]);
      final shouldStartHotspot = existingLanIp == null;

      var manualHotspot = false;
      String? hotspotIp;
      if (shouldStartHotspot) {
        if (mounted) {
          setState(() => _status = 'Starting temporary hotspot…');
        }
        try {
          final hotspotInfo = await WlanLinkManager.instance.startTemporaryHotspot(
            ssid: 'AirShareLink',
            password: 'AirShare@2026',
            hubPort: port,
          );
          hotspotIp = (hotspotInfo?['hubIp'] ?? '').toString().trim();
          if (hotspotIp.isNotEmpty) {
            await ConnectionLogger.instance.log(
              'Self IP discovered',
              details: hotspotIp,
            );
          }
          await ConnectionLogger.instance.log(
            'Hotspot Status',
            details: 'automatic start success',
          );
        } catch (e) {
          manualHotspot = true;
          await ConnectionLogger.instance.log(
            'Hotspot Status',
            details: 'manual required: $e',
          );
        }
      } else {
        await ConnectionLogger.instance.log(
          'Hotspot Status',
          details: 'skipped: active LAN/Wi-Fi detected ($existingLanIp)',
        );
      }

      final advertisedIp = _pickRealIp([hotspotIp, interfaceIp, discoveredIp]);
      if (advertisedIp != null) {
        HubEndpointState.instance.setPending(ip: advertisedIp, port: port);
        if (mounted) {
          setState(() {
            _currentAdvertisedIp = advertisedIp;
            _networkWarning = null;
          });
        }
        await ConnectionLogger.instance.log(
          'Connection | Advertising real IP',
          details: advertisedIp,
        );
      } else {
        HubEndpointState.instance.clear();
        if (mounted) {
          setState(() {
            _currentAdvertisedIp = null;
            _networkWarning = discoveredIp == '127.0.0.1'
                || interfaceIp == '127.0.0.1'
                ? 'No active network detected. Please connect to Wi-Fi or enable Hotspot.'
                : null;
          });
        }
        await ConnectionLogger.instance.log(
          'Connection | Advertising real IP',
          details: 'not available; awaiting manual fallback',
        );
      }

      if (!mounted) return;
      setState(
        () => _status = manualHotspot
            ? 'Manual Hotspot: enable hotspot in settings and ensure the PC is connected.'
            : 'Hub ready — opening file console',
      );

      final sessionNotifier = FileZoneSessionScope.of(context);
      sessionNotifier.value = FileZoneSession(
        hubHost: '127.0.0.1',
        hubPort: port,
        isLocalHub: true,
      );

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => FileListScreen(
            hubHost: '127.0.0.1',
            hubPort: port,
            modeTitle: 'Send Files',
            isHubMode: true,
          ),
        ),
      );

      sessionNotifier.value = null;
      HubEndpointState.instance.clear();
      _currentAdvertisedIp = null;
      _networkWarning = null;
      await BleTransport.instance.stopHubAdvertising();
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      debugPrint('[SenderStaging] $e\n$st');
      await ConnectionLogger.instance.log('BLE Advertise Result', details: 'failed: $e');
      HubEndpointState.instance.clear();
      _currentAdvertisedIp = null;
      _networkWarning = null;
      if (!mounted) return;
      setState(() {
        _error = e;
        _status = 'Preparation failed';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isPreparing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send — Hub preparation')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.of(context).size.height - kToolbarHeight - 48,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              if (_isPreparing) const LinearProgressIndicator(),
              if (_isPreparing) const SizedBox(height: 16),
              if (_error != null)
                Text(
                  _error.toString(),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_currentAdvertisedIp != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Current IP: $_currentAdvertisedIp',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Make sure the receiver is on the same network.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              if (_networkWarning != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _networkWarning!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _isPreparing ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
