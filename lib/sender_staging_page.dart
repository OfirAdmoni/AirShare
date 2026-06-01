import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:air_share/ble_transport.dart';
import 'package:air_share/session_teardown.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/host_network_tier.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/local_peer_identity.dart';
import 'package:air_share/wlan_link_manager.dart';
import 'package:air_share/ux_prompts.dart';
import 'package:air_share/wifi_tier_prerequisites.dart';
import 'package:flutter/services.dart';

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
  bool _hotspotDialogShown = false;
  bool _teardownRan = false;
  bool _hotspotStarting = false;

  HubStatus get _hubStatus => HubStatusScope.of(context);

  Future<void> _runFullTeardown() async {
    if (_teardownRan) return;
    _teardownRan = true;
    await SessionTeardown.runSenderTeardown(
      hotspotStartInFlight: _hotspotStarting,
    );
  }

  /// LocalOnlyHotspot: only system-generated SSID/password are valid for BLE/guest join.
  Future<bool> _tryStartSystemHotspot({
    required int hubPort,
    required void Function(String ssid, String password, String hubIp) apply,
  }) async {
    try {
      final hotspotInfo = await WlanLinkManager.instance.startTemporaryHotspot(
        hubPort: hubPort,
      );
      if (hotspotInfo?['tier1PreConnected'] == true) {
        final hubIp = (hotspotInfo?['hubIp'] ?? '').toString().trim();
        if (hubIp.isNotEmpty) {
          apply('', '', hubIp);
        }
        return false;
      }
      if (hotspotInfo?['hotspotActive'] != true) {
        return false;
      }
      final ssid = (hotspotInfo?['ssid'] ?? '').toString().trim();
      final password = (hotspotInfo?['password'] ?? '').toString().trim();
      final hubIp = (hotspotInfo?['hubIp'] ?? '').toString().trim();
      if (ssid.isEmpty) {
        debugPrint('[SenderStaging] Hotspot started but system SSID is empty');
        return false;
      }
      apply(ssid, password, hubIp);
      debugPrint(
        '[SenderStaging] BLE will advertise system hotspot SSID="$ssid" '
        '(password length=${password.length}, hubIp=${hubIp.isEmpty ? "pending" : hubIp})',
      );
      await ConnectionLogger.instance.log(
        'BLE | Hotspot credentials for guest (system-generated)',
        details: 'ssid=$ssid password_len=${password.length} hub=$hubIp',
      );
      return true;
    } on PlatformException {
      rethrow;
    } catch (e) {
      debugPrint('[SenderStaging] _tryStartSystemHotspot failed: $e');
      return false;
    }
  }

  static const String _kIosLanOnlyMessage =
      'iOS currently supports same-Wi-Fi LAN sharing only.';

  Future<void> _showIosLanOnlyBlocked() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Same Wi‑Fi required'),
        content: const Text(_kIosLanOnlyMessage),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _notifyManualHotspotRequired() async {
    if (_hotspotDialogShown || !mounted) return;
    _hotspotDialogShown = true;
    await UxPrompts.showManualHotspotFallback(context);
  }

  /// Push hub `ip:port` into the native GATT endpoint characteristic as soon as
  /// it is known (Android/Windows). Reduces Android↔Android races where the
  /// guest reads `:8080` or an empty endpoint before the approve dialog runs.
  Future<void> _primeBleGattEndpoint({
    required String ip,
    required int port,
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isIOS) return;
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

  Future<void> _logAllNetworkInterfaces(List<NetworkInterface> interfaces) async {
    debugPrint('Network | Interfaces | dump start (${interfaces.length} ifaces, IPv4)');
    await ConnectionLogger.instance.log(
      'Network | Interfaces',
      details:
          'dumping ${interfaces.length} non-loopback IPv4-capable interfaces',
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        final line = '${iface.name}: ${addr.address}';
        debugPrint('Network | Interface $line');
        await ConnectionLogger.instance.log(
          'Network | Interface',
          details: line,
        );
      }
    }
    debugPrint('Network | Interfaces | dump end');
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

  @override
  void dispose() {
    unawaited(_runFullTeardown());
    super.dispose();
  }

  Future<void> _prepareSender() async {
    if (!mounted || _isPreparing || _teardownRan) return;
    setState(() {
      _isPreparing = true;
      _status = 'Preparing network endpoints…';
      _error = null;
    });

    try {
      if (!mounted) return;

      if (!mounted) return;
      setState(() => _status = 'Starting local HTTP hub…');

      await LocalHubRuntime.instance.ensureStarted(_hubStatus);
      final localIdentity = await LocalPeerIdentity.resolve();
      await LocalHubRuntime.instance.setRoomHostIdentity(
        peerId: localIdentity.peerId,
        displayName: localIdentity.displayName,
      );
      final port = LocalHubRuntime.instance.activePort;
      await ConnectionLogger.instance.log(
        'HTTP Server Start',
        details: 'port=$port',
      );
      await ConnectionLogger.instance.log(
        'HTTP Server | Listening on all interfaces (0.0.0.0:$port)',
      );
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      await _logAllNetworkInterfaces(interfaces);

      final networkPlan = await HostNetworkTier.planSenderStartup();
      await ConnectionLogger.instance.log(
        'Network | Sender tier plan',
        details: networkPlan.useTier1Only
            ? 'Tier 1 only — ${networkPlan.tier1LanIp} on ${networkPlan.pickedInterface ?? "?"} '
                '(bypass automated hotspot/P2P)'
            : 'no pre-connected private IP — offline Tier 2/3 may run',
      );

      if (!mounted) return;
      final lanIp = networkPlan.tier1LanIp;
      final useTier1Only = networkPlan.useTier1Only;
      var p2pIp = '';
      var p2pMac = '';
      var hotspotSsid = '';
      var hotspotPass = '';
      var hotspotHubIp = '';
      var manualHotspot = false;

      if (Platform.isWindows) {
        await ConnectionLogger.instance.log(
          'Connection | Windows desktop LAN/TCP mode',
          details:
              lanIp ?? 'no LAN IP — local hub still available on 127.0.0.1',
        );
        if (mounted) {
          setState(
            () => _status = lanIp != null && lanIp.isNotEmpty
                ? 'Windows LAN ready — starting BLE advertisement…'
                : 'Windows hub on 127.0.0.1 — connect receivers on the same Wi‑Fi/LAN',
          );
        }
      } else if (useTier1Only && lanIp != null && lanIp.isNotEmpty) {
        final ifaceHint = networkPlan.pickedInterface ?? '';
        final onAp = HostNetworkTier.isHotspotAccessPointInterface(ifaceHint);
        await ConnectionLogger.instance.log(
          'Connection | Tier 1 LAN ready',
          details: onAp
              ? '$lanIp (pre-connected hotspot $ifaceHint — Tier 2/3 bypassed)'
              : '$lanIp ($ifaceHint — Tier 2/3 bypassed)',
        );
        if (mounted) {
          setState(
            () => _status = onAp
                ? 'Hotspot/LAN ready — using existing network (no auto hotspot)'
                : 'LAN ready — skipping automated hotspot and Wi‑Fi Direct',
          );
        }
      } else if (Platform.isIOS) {
        await ConnectionLogger.instance.log(
          'Connection | iOS sender — LAN only (no offline hotspot host)',
          details: lanIp ?? 'no LAN IP',
        );
        if (mounted) {
          setState(() {
            _status = _kIosLanOnlyMessage;
            _networkWarning = _kIosLanOnlyMessage;
          });
        }
        if (lanIp == null || lanIp.isEmpty) {
          await _showIosLanOnlyBlocked();
          if (mounted) {
            setState(() {
              _isPreparing = false;
              _status = _kIosLanOnlyMessage;
            });
          }
          return;
        }
        if (mounted) {
          setState(
            () => _status = 'iOS LAN ready — starting BLE advertisement…',
          );
        }
      } else if (Platform.isAndroid) {
        await WifiTierPrerequisites.ensureReadyForWifiTier(context: context);
        if (!mounted) return;
        if (mounted) {
          setState(() => _status = 'Tier 2: Starting temporary hotspot…');
        }
        var hotspotStarted = false;
        _hotspotStarting = true;
        try {
          final hotspotReady = await _tryStartSystemHotspot(
            hubPort: port,
            apply: (ssid, pass, hubIp) {
              hotspotSsid = ssid;
              hotspotPass = pass;
              hotspotHubIp = hubIp;
            },
          );
          if (hotspotReady) {
            hotspotStarted = true;
            await ConnectionLogger.instance.log(
              'Connection | Tier 2 hotspot ready',
              details: 'ssid=$hotspotSsid hub=$hotspotHubIp',
            );
          } else {
            await ConnectionLogger.instance.log(
              'Connection | Tier 2 hotspot not active',
              details: 'onStarted was not confirmed or system SSID missing',
            );
          }
        } on PlatformException catch (e) {
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 hotspot failed',
            details: '${e.code}: ${e.message}',
          );
        } catch (e) {
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 hotspot failed',
            details: '$e',
          );
        } finally {
          _hotspotStarting = false;
        }
        if (!hotspotStarted) {
          await WlanLinkManager.instance.stopNativeHotspot();
          if (!mounted) return;
          if (mounted) {
            setState(() => _status = 'Tier 3: Starting Wi‑Fi Direct group…');
          }
          try {
            final p2pInfo = await WlanLinkManager.instance
                .startWifiDirectGroup();
            p2pIp = (p2pInfo?['hubIp'] ?? '').toString().trim();
            p2pMac = (p2pInfo?['p2pMac'] ?? '').toString().trim();
            await ConnectionLogger.instance.log(
              'Connection | Tier 3 P2P ready',
              details: 'ip=$p2pIp mac=$p2pMac',
            );
          } catch (e) {
            await ConnectionLogger.instance.log(
              'Connection | Tier 3 P2P failed',
              details: '$e',
            );
            manualHotspot = true;
            await _notifyManualHotspotRequired();
          }
        }
      } else if (!Platform.isWindows) {
        if (mounted) {
          setState(() => _status = 'Tier 2: Starting temporary hotspot…');
        }
        _hotspotStarting = true;
        try {
          final hotspotReady = await _tryStartSystemHotspot(
            hubPort: port,
            apply: (ssid, pass, hubIp) {
              hotspotSsid = ssid;
              hotspotPass = pass;
              hotspotHubIp = hubIp;
            },
          );
          if (!hotspotReady) {
            manualHotspot = true;
            await _notifyManualHotspotRequired();
          }
        } on PlatformException catch (e) {
          manualHotspot = true;
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 hotspot failed',
            details: '${e.code}: ${e.message}',
          );
          if (e.code == 'hotspot_failed' || e.code == 'hotspot_permission') {
            await _notifyManualHotspotRequired();
          }
        } catch (e) {
          manualHotspot = true;
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 hotspot failed',
            details: '$e',
          );
          await _notifyManualHotspotRequired();
        } finally {
          _hotspotStarting = false;
        }
      }

      if (Platform.isAndroid &&
          (lanIp == null || lanIp.isEmpty) &&
          p2pIp.isEmpty &&
          hotspotSsid.isEmpty &&
          manualHotspot) {
        await _notifyManualHotspotRequired();
      }

      if (hotspotSsid.isNotEmpty) {
        debugPrint(
          '[SenderStaging] Pushing to BLE handshake: hotspot_ssid="$hotspotSsid" '
          '(system-generated, password_len=${hotspotPass.length})',
        );
      }

      await ConnectionLogger.instance.log(
        'BLE Handshake | Endpoint fields',
        details:
            'lan_ip=${lanIp ?? ""} hotspot_hub_ip=$hotspotHubIp '
            'p2p_ip=$p2pIp hub_port=$port platform=${Platform.operatingSystem}',
      );

      await BleTransport.instance.updateConnectionEndpoints(
        lanIp: lanIp ?? '',
        p2pIp: p2pIp,
        p2pMac: p2pMac,
        hotspotSsid: hotspotSsid,
        hotspotPass: hotspotPass,
        hotspotHubIp: hotspotHubIp,
        hubPort: port,
      );

      HubEndpointState.instance.rememberBleEndpoints(
        lanIp: lanIp ?? '',
        p2pIp: p2pIp,
        p2pMac: p2pMac,
        hotspotSsid: hotspotSsid,
        hotspotPass: hotspotPass,
        hotspotHubIp: hotspotHubIp,
        hubPort: port,
      );
      final advertisedIp = lanIp ?? (hotspotHubIp.isNotEmpty ? hotspotHubIp : p2pIp);
      if (advertisedIp.isNotEmpty) {
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
            _networkWarning = lanIp == '127.0.0.1'
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
      if (Platform.isIOS && (lanIp == null || lanIp.isEmpty)) {
        await _showIosLanOnlyBlocked();
        return;
      }
      final advertiseAs = await DeviceBranding.effectiveAdvertisingName();
      setState(() => _status = 'Starting BLE advertisement…');
      await ConnectionLogger.instance.log(
        'BLE Advertise Start',
        details: 'endpoints ready; advertising as $advertiseAs',
      );
      await ConnectionLogger.instance.log(
        'DeviceName | BLE advertising restarted with new name: $advertiseAs',
      );
      try {
        await BleTransport.instance.startHubAdvertising(
          friendlyName: advertiseAs,
        );
        await ConnectionLogger.instance.log(
          'BLE Advertise Result',
          details: 'success',
        );
      } on PlatformException catch (e) {
        await ConnectionLogger.instance.log(
          'BLE Advertise Result',
          details: 'failed: ${e.code} ${e.message}',
        );
        if (Platform.isIOS && mounted) {
          await _showIosLanOnlyBlocked();
          return;
        }
        rethrow;
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
      _currentAdvertisedIp = null;
      _networkWarning = null;
      await _runFullTeardown();
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      debugPrint('[SenderStaging] $e\n$st');
      await ConnectionLogger.instance.log(
        'BLE Advertise Result',
        details: 'failed: $e',
      );
      await _runFullTeardown();
      _currentAdvertisedIp = null;
      _networkWarning = null;
      if (!mounted) return;
      setState(() {
        _error = e;
        _status = 'Preparation failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPreparing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_runFullTeardown());
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Send — Hub preparation')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height - kToolbarHeight - 48,
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                  onPressed: () async {
                    await _runFullTeardown();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
