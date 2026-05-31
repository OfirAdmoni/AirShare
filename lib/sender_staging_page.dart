import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_tier.dart';
import 'package:air_share/session_teardown.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_auth.dart';
import 'package:air_share/host_ble_endpoint_snapshot.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_session_registry.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/session_crypto.dart';
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
  bool _isInitializing = true;
  bool _isPreparing = false;
  bool _prepareStarted = false;
  bool _hotspotDialogShown = false;
  bool _teardownRan = false;
  bool _hotspotStarting = false;

  HubStatus get _hubStatus => HubStatusScope.of(context);

  /// Releases ap0 / LocalOnlyHotspot so later LAN sessions are not polluted.
  Future<void> _releaseHostRadio() async {
    if (!Platform.isAndroid) return;
    try {
      await WlanLinkManager.instance.stopNativeHotspot();
      await ConnectionLogger.instance.log('Connection | Host hotspot released');
    } catch (e) {
      debugPrint('[SenderStaging] stopNativeHotspot: $e');
      await ConnectionLogger.instance.log(
        'Connection | Host hotspot release failed',
        details: '$e',
      );
    }
    try {
      await WlanLinkManager.instance.stopWifiDirectGroup();
    } catch (_) {}
  }

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
      final gateway = HotspotGateway.forHostPlatform();
      apply(ssid, password, gateway);
      if (hubIp.isNotEmpty && hubIp != gateway) {
        await ConnectionLogger.instance.log(
          'Network | Hotspot hub IP normalized',
          details: 'native=$hubIp → gateway=$gateway (Tier 2 standard gateway)',
        );
      }
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

  bool _isRealAdvertisableIp(String ip) {
    final candidate = ip.trim();
    if (candidate.isEmpty || candidate == '127.0.0.1') return false;
    if (HotspotGateway.isLikelyCarrierWanIp(candidate)) return false;
    final isLan = candidate.startsWith('192.168.');
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

  /// Pushes tier endpoints + TLS fingerprint into BLE (no [host_public_key] until Approve).
  Future<void> _syncBleHandshakeEndpoints({
    required int hubPort,
    String lanIp = '',
    String p2pIp = '',
    String p2pMac = '',
    String hotspotSsid = '',
    String hotspotPass = '',
    String hotspotHubIp = '',
    bool includeSessionKeys = false,
  }) async {
    final tlsFp = HubSessionRegistry.instance.tls?.certSha256Hex ?? '';
    final hostPk = includeSessionKeys
        ? (HubSessionRegistry.instance.host?.hostPublicKeyBase64Url ?? '')
        : '';
    final snapshot = HostBleEndpointSnapshot(
      lanIp: lanIp,
      p2pIp: p2pIp,
      p2pMac: p2pMac,
      hotspotSsid: hotspotSsid,
      hotspotPass: hotspotPass,
      hotspotHubIp: hotspotHubIp,
      hubPort: hubPort,
      hostPublicKey: hostPk,
      tlsCertSha256: tlsFp,
    );
    if (!snapshot.hasInfrastructure && hostPk.isEmpty) return;

    await BleTransport.instance.updateConnectionEndpoints(
      lanIp: lanIp,
      p2pIp: p2pIp,
      p2pMac: p2pMac,
      hotspotSsid: hotspotSsid,
      hotspotPass: hotspotPass,
      hotspotHubIp: hotspotHubIp,
      hubPort: hubPort,
      hostPublicKey: hostPk,
      tlsCertSha256: tlsFp,
    );
    HubEndpointState.instance.rememberBleSnapshot(snapshot);
    await ConnectionLogger.instance.log(
      includeSessionKeys
          ? 'BLE | Session keys released (post-approve)'
          : 'BLE | Handshake JSON primed (pre-approve)',
      details:
          'lan=${lanIp.isNotEmpty ? lanIp : "—"} port=$hubPort '
          'tls_fp=${tlsFp.isNotEmpty} host_pk=${hostPk.isNotEmpty}',
    );
  }

  /// Push hub `ip:port` into the native GATT endpoint characteristic as soon as
  /// it is known (Android/Windows). Reduces Android↔Android races where the
  /// guest reads `:8080` or an empty endpoint before the approve dialog runs.
  Future<void> _primeBleGattEndpoint({required String ip, required int port}) async {
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isIOS) return;
    try {
      await BleTransport.instance.updateHubEndpoint(
        ip: ip,
        port: port,
      );
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

  /// LocalOnlyHotspot (ap0), Wi‑Fi Direct (p2p-*), and tether USB — not home/office LAN.
  bool _isExcludedFromTier1Lan(String ifaceName) {
    final l = ifaceName.toLowerCase();
    if (l.startsWith('ap') || l.contains('softap')) return true;
    if (l.contains('p2p')) return true;
    if (l.contains('rndis') || l.contains('usb')) return true;
    if (l.contains('swlan')) return true;
    return false;
  }

  /// Tier 1 candidates: station-mode Wi‑Fi (wlan0, etc.) only.
  bool _isTier1LanEligibleInterface(String ifaceName) {
    if (_isExcludedFromTier1Lan(ifaceName)) return false;
    final l = ifaceName.toLowerCase();
    if (Platform.isWindows) {
      return l.contains('wi-fi') ||
          l.contains('wifi') ||
          l.contains('wlan') ||
          l.contains('ethernet') ||
          l.startsWith('eth');
    }
    return l.contains('wlan') || l.contains('wifi');
  }

  int _tier1LanPreferenceScore(String ifaceName, String ip) {
    final l = ifaceName.toLowerCase();
    var score = 0;
    if (l == 'wlan0' || l.endsWith('wlan0')) score += 50;
    if (l.contains('wlan')) score += 30;
    if (l.contains('wifi')) score += 20;
    final parts = ip.split('.');
    if (parts.length == 4 && parts[3] == '1') score += 4;
    return score;
  }

  Future<bool> _ipOnlyOnExcludedInterfaces(String ip) async {
    var onEligible = false;
    var onExcluded = false;
    for (final iface in await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    )) {
      for (final addr in iface.addresses) {
        if (addr.address != ip) continue;
        if (_isTier1LanEligibleInterface(iface.name)) {
          onEligible = true;
        } else if (_isExcludedFromTier1Lan(iface.name)) {
          onExcluded = true;
        }
      }
    }
    return onExcluded && !onEligible;
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
      if (!_isTier1LanEligibleInterface(iface.name)) continue;
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        final ip = addr.address;
        if (!_isRealAdvertisableIp(ip)) continue;
        final score = _tier1LanPreferenceScore(iface.name, ip);
        scored.add((name: iface.name, ip: ip, score: score));
      }
    }

    if (scored.isEmpty && Platform.isWindows) {
      for (final iface in interfaces) {
        if (_isLikelyCellularOrWan(iface.name)) continue;
        if (_isExcludedFromTier1Lan(iface.name)) continue;
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final ip = addr.address;
          if (!_isRealAdvertisableIp(ip)) continue;
          scored.add((name: iface.name, ip: ip, score: 10));
        }
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

  @override
  void dispose() {
    unawaited(_runFullTeardown());
    super.dispose();
  }

  /// Ensures TLS credentials exist in [HubSessionRegistry] after [ensureStarted].
  void _requireTlsFingerprint() {
    final fp = HubSessionRegistry.instance.tls?.certSha256Hex;
    if (fp == null || fp.isEmpty) {
      throw StateError('Hub TLS fingerprint is not available');
    }
  }

  Future<void> _prepareSender() async {
    if (!mounted || _isPreparing || _teardownRan) return;
    setState(() {
      _isInitializing = true;
      _isPreparing = true;
      _status = 'Generating TLS certificate…';
      _error = null;
    });

    try {
      if (!mounted) return;

      HubSessionRegistry.instance.clear();

      if (!mounted) return;
      setState(() => _status = 'Starting secure HTTPS hub…');

      await LocalHubRuntime.instance.ensureStarted(_hubStatus);
      _requireTlsFingerprint();

      if (!mounted) return;
      setState(() => _status = 'Preparing session keys…');

      final hostKeyPair = await SessionCrypto.generateKeyPair();
      final hostPublicKey = await SessionCrypto.publicKeyBase64Url(hostKeyPair);
      HubSessionRegistry.instance.host = HostHubSession(
        hostKeyPair: hostKeyPair,
        hostPublicKeyBase64Url: hostPublicKey,
      );
      await ConnectionLogger.instance.log(
        'Security | Host ECDH key ready (released on Approve)',
        details: 'host_public_key_len=${hostPublicKey.length}',
      );

      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _status = 'Discovering network endpoints…';
      });

      final localIdentity = await LocalPeerIdentity.resolve();
      await LocalHubRuntime.instance.setRoomHostIdentity(
        peerId: localIdentity.peerId,
        displayName: localIdentity.displayName,
      );
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
      if (discoveredIp != null &&
          discoveredIp.isNotEmpty &&
          await _ipOnlyOnExcludedInterfaces(discoveredIp)) {
        await ConnectionLogger.instance.log(
          'Network | getWifiIP ignored',
          details: '$discoveredIp is only on ap/p2p virtual interfaces — not Tier 1 LAN',
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
      final lanIp = _pickRealIp([interfaceIp, discoveredIp]);
      if (lanIp != null && lanIp.isNotEmpty) {
        await _syncBleHandshakeEndpoints(hubPort: port, lanIp: lanIp);
        await _primeBleGattEndpoint(ip: lanIp, port: port);
      }
      var p2pIp = '';
      var p2pMac = '';
      var hotspotSsid = '';
      var hotspotPass = '';
      var hotspotHubIp = '';
      var manualHotspot = false;

      if (Platform.isWindows) {
        await ConnectionLogger.instance.log(
          'Connection | Windows desktop LAN/TCP mode',
          details: lanIp ?? 'no LAN IP — local hub still available on 127.0.0.1',
        );
        if (mounted) {
          setState(
            () => _status = lanIp != null && lanIp.isNotEmpty
                ? 'Windows LAN ready — starting BLE advertisement…'
                : 'Windows hub on 127.0.0.1 — connect receivers on the same Wi‑Fi/LAN',
          );
        }
      } else if (lanIp != null && lanIp.isNotEmpty) {
        await ConnectionLogger.instance.log(
          'Connection | Tier 1 LAN ready',
          details: lanIp,
        );
        if (mounted) {
          setState(() => _status = 'LAN ready — skipping Wi‑Fi Direct (radio save)');
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
          setState(() => _status = 'iOS LAN ready — starting BLE advertisement…');
        }
      } else if (Platform.isAndroid) {
        await WifiTierPrerequisites.ensureReadyForWifiTier(context: context);
        if (!mounted) return;
        if (mounted) setState(() => _status = 'Tier 2: Starting temporary hotspot…');
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
          if (mounted) setState(() => _status = 'Tier 3: Starting Wi‑Fi Direct group…');
          try {
            final p2pInfo = await WlanLinkManager.instance.startWifiDirectGroup();
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
        if (mounted) setState(() => _status = 'Tier 2: Starting temporary hotspot…');
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
          await ConnectionLogger.instance.log('Connection | Tier 2 hotspot failed', details: '$e');
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

      var effectiveLanIp = lanIp ?? '';
      var effectiveHotspotHubIp = hotspotHubIp;
      if (hotspotSsid.isNotEmpty) {
        final hotspotBle = HotspotGateway.bleEndpointsForHotspotHost(
          hostPlatform: Platform.operatingSystem,
        );
        effectiveHotspotHubIp = hotspotBle.hotspotHubIp;
        if (effectiveLanIp.isEmpty ||
            HotspotGateway.isLikelyCarrierWanIp(effectiveLanIp)) {
          effectiveLanIp = hotspotBle.lanIp;
        }
        await ConnectionLogger.instance.log(
          'BLE | Tier 2 hotspot endpoints',
          details:
              'lan_ip=$effectiveLanIp hotspot_hub_ip=$effectiveHotspotHubIp '
              '(carrier WAN excluded from BLE)',
        );
      }

      await _syncBleHandshakeEndpoints(
        hubPort: port,
        lanIp: effectiveLanIp,
        p2pIp: p2pIp,
        p2pMac: p2pMac,
        hotspotSsid: hotspotSsid,
        hotspotPass: hotspotPass,
        hotspotHubIp: effectiveHotspotHubIp,
      );

      final advertisedIp = effectiveLanIp.isNotEmpty
          ? effectiveLanIp
          : (effectiveHotspotHubIp.isNotEmpty ? effectiveHotspotHubIp : p2pIp);
      if (advertisedIp.isNotEmpty) {
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
        await ConnectionLogger.instance.log('BLE Advertise Result', details: 'success');
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
      await ConnectionLogger.instance.log('BLE Advertise Result', details: 'failed: $e');
      await _runFullTeardown();
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
        _isInitializing = false;
        _isPreparing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Send — Hub preparation')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

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
