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

  /// Push hub `ip:port` into the native GATT endpoint characteristic as soon as
  /// it is known (Android/Windows). Reduces Android↔Android races where the
  /// guest reads `:8080` or an empty endpoint before the approve dialog runs.
  Future<void> _primeBleGattEndpoint({required String ip, required int port}) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      await BleTransport.instance.updateHubEndpoint(ip: ip, port: port);
      await ConnectionLogger.instance.log(
        'BLE | GATT endpoint primed (pre-guest)',
        details: '$ip:$port',
      );
    } catch (e) {
      await ConnectionLogger.instance.log(
        'BLE | GATT endpoint priming failed',
        details: '$e',
      );
    }
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

  /// Data / carrier / VPN interfaces — never use these for BLE‑advertised hub IP
  /// when a hotspot/LAN address exists (avoids rmnet/ccmni carrier NAT IPs).
  bool _isLikelyCellularOrWan(String name) {
    final lower = name.toLowerCase();
    return lower.contains('rmnet') ||
        lower.contains('ccmni') ||
        lower.contains('pdp') ||
        lower.contains('cell') ||
        lower.contains('wwan') ||
        lower.contains('mobile') ||
        lower.contains('epdg') ||
        lower.contains('v4-rmnet') ||
        lower.contains('clat') ||
        lower.contains('tun') ||
        lower.contains('tap') ||
        lower.contains('vbox') ||
        lower.contains('vmnet') ||
        lower.contains('vpn') ||
        lower.contains('wg') ||
        lower.contains('dummy');
  }

  /// SoftAP / USB tether / second radio — typical Android mobile hotspot uplink.
  int _hotspotTetherPreferenceScore(String ifaceName, String ip) {
    final l = ifaceName.toLowerCase();
    var score = 0;
    if (l.contains('swlan')) score += 45;
    if (l.contains('softap')) score += 45;
    if (l.contains('ap') && !l.contains('map')) score += 25;
    if (l.contains('rndis') || l.contains('usb')) score += 30;
    if (l.contains('wlan') && (l.contains('1') || l.contains('2'))) score += 12;
    if (l.contains('p2p')) score += 8;
    if (l.contains('wifi') && l.contains('ap')) score += 40;
    final parts = ip.split('.');
    if (parts.length == 4 && parts[3] == '1') score += 6;
    return score;
  }

  Future<void> _logAllNetworkInterfaces(List<NetworkInterface> interfaces) async {
    debugPrint('Network | Interfaces | dump start (${interfaces.length} ifaces, IPv4)');
    await ConnectionLogger.instance.log(
      'Network | Interfaces',
      details: 'dumping ${interfaces.length} non-loopback IPv4-capable interfaces',
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        final line = '${iface.name}: ${addr.address}';
        debugPrint('Network | Interface $line');
        await ConnectionLogger.instance.log('Network | Interface', details: line);
      }
    }
    debugPrint('Network | Interfaces | dump end');
  }

  /// Picks an IPv4 to advertise over BLE: LAN/hotspot first, never cellular rmnet/ccmni.
  Future<({String? pickedIp, Set<String> ipsSeenOnCellular})>
      _pickHubAdvertiseIpv4FromInterfaces() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    await _logAllNetworkInterfaces(interfaces);

    final ipsOnCellular = <String>{};
    for (final iface in interfaces) {
      if (!_isLikelyCellularOrWan(iface.name)) continue;
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          ipsOnCellular.add(addr.address);
        }
      }
    }

    final scored = <({String name, String ip, int score})>[];
    for (final iface in interfaces) {
      if (_isLikelyCellularOrWan(iface.name)) continue;
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        final ip = addr.address;
        if (!_isRealAdvertisableIp(ip)) continue;
        final score = _hotspotTetherPreferenceScore(iface.name, ip);
        scored.add((name: iface.name, ip: ip, score: score));
      }
    }

    if (scored.isEmpty) {
      await ConnectionLogger.instance.log(
        'Network | Hub IPv4 pick',
        details: 'no non-cellular LAN candidates (cellular_iface_ips=${ipsOnCellular.length})',
      );
      return (pickedIp: null, ipsSeenOnCellular: ipsOnCellular);
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final best = scored.first;
    await ConnectionLogger.instance.log(
      'Network | Hub IPv4 pick',
      details:
          'chose ${best.ip} on ${best.name} score=${best.score} '
          '(candidates=${scored.length}; skipped cellular ifaces)',
    );
    return (pickedIp: best.ip, ipsSeenOnCellular: ipsOnCellular);
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
      final discoveredIpRaw = (await networkInfo.getWifiIP())?.trim();
      final ifaceAnalysis = await _pickHubAdvertiseIpv4FromInterfaces();
      final interfaceIp = ifaceAnalysis.pickedIp;
      final ipsOnCellular = ifaceAnalysis.ipsSeenOnCellular;

      var discoveredIp = discoveredIpRaw;
      if (discoveredIp != null &&
          discoveredIp.isNotEmpty &&
          ipsOnCellular.contains(discoveredIp)) {
        await ConnectionLogger.instance.log(
          'Network | getWifiIP ignored',
          details:
              '$discoveredIp matches an address on a cellular/WAN interface — not using for BLE hub IP',
        );
        discoveredIp = null;
      }

      await ConnectionLogger.instance.log(
        'Self IP discovered',
        details:
            'network_info_plus=${discoveredIpRaw ?? "unavailable"}, '
            'wifi_ip_after_filter=${discoveredIp ?? "none"}, '
            'interface_pick=${interfaceIp ?? "none"}',
      );

      if (!mounted) return;
      final existingLanIp = _pickRealIp([interfaceIp, discoveredIp]);
      final shouldStartHotspot = existingLanIp == null;

      var manualHotspot = false;
      String? hotspotIp;
      if (Platform.isAndroid) {
        // Wi-Fi Direct autonomous group: creates a separate p2p-* interface that
        // coexists with any system hotspot and is NOT subject to AP isolation iptables.
        if (mounted) setState(() => _status = 'Starting Wi-Fi Direct group…');
        try {
          final p2pInfo = await WlanLinkManager.instance.startWifiDirectGroup();
          hotspotIp = (p2pInfo?['hubIp'] ?? '').toString().trim();
          if (hotspotIp.isNotEmpty) {
            await ConnectionLogger.instance.log(
              'Self IP discovered',
              details: hotspotIp,
            );
          }
          await ConnectionLogger.instance.log(
            'Hotspot Status',
            details: 'Wi-Fi Direct group started: $hotspotIp',
          );
        } catch (e) {
          await ConnectionLogger.instance.log(
            'Hotspot Status',
            details: 'Wi-Fi Direct failed ($e) — falling back',
          );
          // Fallback: LocalOnlyHotspot if no LAN already exists
          if (shouldStartHotspot) {
            if (mounted) setState(() => _status = 'Starting temporary hotspot…');
            try {
              final hotspotInfo = await WlanLinkManager.instance.startTemporaryHotspot(
                ssid: 'AirShareLink',
                password: 'AirShare@2026',
                hubPort: port,
              );
              hotspotIp = (hotspotInfo?['hubIp'] ?? '').toString().trim();
              if (hotspotIp.isNotEmpty) {
                await ConnectionLogger.instance.log('Self IP discovered', details: hotspotIp);
              }
              await ConnectionLogger.instance.log('Hotspot Status', details: 'fallback hotspot started');
            } catch (e2) {
              manualHotspot = true;
              await ConnectionLogger.instance.log('Hotspot Status', details: 'manual required: $e2');
            }
          } else {
            await ConnectionLogger.instance.log(
              'Hotspot Status',
              details: 'Wi-Fi Direct unavailable; using existing LAN ($existingLanIp)',
            );
          }
        }
      } else if (shouldStartHotspot) {
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
        await _primeBleGattEndpoint(ip: advertisedIp, port: port);
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
      if (Platform.isAndroid) {
        try {
          await WlanLinkManager.instance.stopWifiDirectGroup();
        } catch (_) {}
      }
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
