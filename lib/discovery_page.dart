import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:air_share/air_share_constants.dart';
import 'package:air_share/ble_peer_filter.dart';
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

enum _GuestDiscoveryPhase { scanning, handshaking, connecting }

class _ManualHotspotFlowCancelled implements Exception {
  const _ManualHotspotFlowCancelled();
}

/// Static label only — no phase-driven UI churn during hotspot join.
const String _kHotspotConnectingOverlayMessage =
    'Connecting to Hub Hotspot...\nPlease approve the system prompt.';

/// Guest discovery hint (same-Wi-Fi focus on iOS).
const String _kOfflineTransferPlatformNote =
    'Same Wi‑Fi: connect to the same network, then receive from an Android or Windows sender.\n'
    'iPhone/iPad uses LAN first, then manual hotspot join if the sender advertises hotspot credentials.\n'
    'iOS Send works on the same Wi‑Fi only (offline hotspot host is not supported).';

/// Offline hotspot join (Tier 2) — Android automatic join; iOS/macOS manual settings UI.
bool _supportsHotspotGuestJoin() => Platform.isAndroid;

bool _usesManualHotspotJoinUi() => Platform.isIOS || Platform.isMacOS;

class _DiscoveryPageState extends State<DiscoveryPage> {
  StreamSubscription<List<BlePeer>>? _scanSubscription;
  final List<BlePeer> _peers = [];
  final Set<String> _seenPeers = <String>{};
  _GuestDiscoveryPhase _phase = _GuestDiscoveryPhase.scanning;
  String _status = 'Peer Discovery via BLE';
  double _pulseScale = 1.0;
  Timer? _pulseTimer;
  bool _leavingForMainMenu = false;
  int _manualProbeGeneration = 0;

  /// Name shown in the connecting overlay; set when the user taps a peer and
  /// updated once the GATT handshake resolves the full custom name.
  String _connectingPeerName = '';

  /// Strips raw BLE fallbacks ("Nearby peer", "Unknown Peer") so the user
  /// always sees a friendly label instead of an internal default.
  static String _cleanDisplayName(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty || name == 'Nearby peer' || name == 'Unknown Peer') {
      return 'AirShare Device';
    }
    return name;
  }

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
    try {
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
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Network | Interface dump failed',
        details: '$e',
      );
    }
  }

  /// TCP probe failed: slow Wi‑Fi, or AP/client isolation (guest SYN never reaches hub).
  bool _looksLikeTcpTimeout(Object e) {
    if (e is TimeoutException) return true;
    if (e is SocketException) {
      final msg = e.message.toLowerCase();
      final osMsg = e.osError?.message.toLowerCase() ?? '';
      if (msg.contains('timed out') || osMsg.contains('timed out')) return true;
      if (e.osError?.errorCode == 110) {
        return true; // ETIMEDOUT on Android/Linux
      }
    }
    return false;
  }

  Future<PeerEndpoint?> _tryTcpConnect(String ip, int port) async {
    if (_leavingForMainMenu) return null;
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
      if (_leavingForMainMenu) return null;
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
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'Socket Connection Failed',
        details: '$ip:$port ${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] TCP probe exception:\n$st');
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
      if (_leavingForMainMenu) return null;
      await ConnectionLogger.instance.log(
        'Socket Connection Success',
        details: 'gateway $gateway:$port',
      );
      return PeerEndpoint(ip: gateway, port: port);
    } catch (_) {
      return null;
    }
  }

  Future<PeerEndpoint?> _probeHttpHealth(String ip, int port) async {
    if (_leavingForMainMenu) return null;
    final uri = Uri(scheme: 'http', host: ip, port: port, path: '/health');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      await HandshakeTrace.run<void>(
        'HTTP health probe (guest → hub)',
        () async {
          final request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 6));
          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          await response.drain<void>().timeout(const Duration(seconds: 3));
          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'Health endpoint returned HTTP ${response.statusCode}',
              uri: uri,
            );
          }
        },
        extra: uri.toString(),
        hardTimeout: const Duration(seconds: 10),
      );
      if (_leavingForMainMenu) return null;
      await ConnectionLogger.instance.log(
        'HTTP Health Success',
        details: uri.toString(),
      );
      return PeerEndpoint(ip: ip, port: port);
    } on TimeoutException catch (e) {
      await ConnectionLogger.instance.log(
        'HTTP Health Timeout',
        details: '$uri $e',
      );
    } on SocketException catch (e) {
      await ConnectionLogger.instance.log(
        _looksLikeTcpTimeout(e)
            ? 'HTTP Health Timeout (socket)'
            : 'HTTP Health Failed',
        details: '$uri $e',
      );
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'HTTP Health Failed',
        details: '$uri ${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] HTTP health probe exception:\n$st');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  void _pauseDiscoverySideEffects() {
    _pulseTimer?.cancel();
    _pulseTimer = null;
  }

  /// Tier 2: join host hotspot (Android WifiNetworkSpecifier only).
  Future<void> _joinHostHotspotAp(HandshakePayload payload) async {
    if (!_supportsHotspotGuestJoin() || !payload.hasHotspot) return;

    if (Platform.isAndroid) {
      await WifiTierPrerequisites.ensureReadyForWifiTier(context: context);
      if (!mounted) throw StateError('unmounted');

      final locationGranted =
          await WifiTierPrerequisites.ensureFineLocationPermission(
            context: context,
          );
      if (!locationGranted) {
        throw StateError(
          'Location permission is required to join the host Wi‑Fi network',
        );
      }
      if (!mounted) throw StateError('unmounted');
    }

    await ConnectionLogger.instance.log(
      'Connection | Tier 2 hotspot',
      details:
          'platform=${Platform.operatingSystem} ssid_len=${payload.hotspotSsid.length}',
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

  Future<PeerEndpoint?> _probeHubAfterHotspot(
    HandshakePayload payload,
    int port,
  ) async {
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

  bool _looksLikeAndroidHotspotIp(String ip) {
    return ip.trim().startsWith('192.168.43.');
  }

  List<({String ip, String source})> _manualHotspotCandidateIps(
    HandshakePayload payload,
  ) {
    final seen = <String>{};
    final candidates = <({String ip, String source})>[];

    void add(String ip, String source) {
      final trimmed = ip.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) return;
      candidates.add((ip: trimmed, source: source));
    }

    final rawHotspotHubIp = payload.rawHotspotHubIp.trim();
    if (rawHotspotHubIp.isNotEmpty) {
      add(rawHotspotHubIp, 'handshake.hotspot_hub_ip');
    }

    if (_looksLikeAndroidHotspotIp(payload.lanIp)) {
      add(payload.lanIp, 'handshake.lan_ip');
    }

    if (rawHotspotHubIp.isEmpty && payload.hotspotHubIp.isNotEmpty) {
      add(payload.hotspotHubIp, 'handshake.hubIp');
    }

    if (payload.p2pIp.isNotEmpty) {
      add(payload.p2pIp, 'handshake.p2p_ip');
    }

    add('192.168.43.1', 'fallback.android_hotspot_gateway');
    add('192.168.49.1', 'fallback.android_p2p_gateway');
    add('192.168.137.1', 'fallback.windows_hotspot_gateway');

    return candidates;
  }

  Future<PeerEndpoint?> _probeManualHotspotJoin(
    HandshakePayload payload,
    int port,
  ) async {
    final probeGeneration = _manualProbeGeneration;
    final candidates = _manualHotspotCandidateIps(payload);
    await _logNetworkInterfaces();
    await ConnectionLogger.instance.log(
      'Connection | Manual hotspot retry probe',
      details:
          'raw_lan_ip=${payload.lanIp} raw_hotspot_hub_ip=${payload.rawHotspotHubIp} '
          'resolved_hotspot_hub_ip=${payload.hotspotHubIp} '
          'candidates=${candidates.map((c) => "${c.source}:${c.ip}").join(",")} '
          'hub_port=$port',
    );
    try {
      for (final candidate in candidates) {
        if (_leavingForMainMenu || probeGeneration != _manualProbeGeneration) {
          await ConnectionLogger.instance.log(
            'Connection | Manual hotspot retry abandoned',
            details: 'navigation changed before ${candidate.ip}:$port',
          );
          return null;
        }
        await ConnectionLogger.instance.log(
          'Connection | Manual hotspot candidate probe',
          details: '${candidate.source} ${candidate.ip}:$port via=/health',
        );
        final endpoint = await _probeHttpHealth(candidate.ip, port);
        if (_leavingForMainMenu || probeGeneration != _manualProbeGeneration) {
          await ConnectionLogger.instance.log(
            'Connection | Manual hotspot retry abandoned',
            details: 'navigation changed after ${candidate.ip}:$port',
          );
          return null;
        }
        if (endpoint != null) {
          await ConnectionLogger.instance.log(
            'Connection | Manual hotspot retry success',
            details: '${candidate.source} ${endpoint.ip}:${endpoint.port}',
          );
          return endpoint;
        }
        await ConnectionLogger.instance.log(
          'Connection | Manual hotspot candidate failed',
          details: '${candidate.source} ${candidate.ip}:$port',
        );
      }
      await ConnectionLogger.instance.log(
        'Connection | Manual hotspot retry failed',
        details:
            'no hub on candidates=${candidates.map((c) => "${c.source}:${c.ip}").join(",")} '
            'hub_port=$port',
      );
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'Connection | Manual hotspot retry error',
        details: '${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] Manual hotspot retry exception:\n$st');
    }
    return null;
  }

  Future<void> _returnToMainMenuFromManualHotspot(
    BuildContext dialogContext,
  ) async {
    if (_leavingForMainMenu) return;
    _leavingForMainMenu = true;
    _manualProbeGeneration++;
    await ConnectionLogger.instance.log(
      'Connection | Manual hotspot flow cancelled',
      details: 'user requested return to main menu',
    );
    _seenPeers.clear();
    _peers.clear();
    if (mounted) {
      setState(() {
        _phase = _GuestDiscoveryPhase.scanning;
        _status = 'Peer Discovery via BLE';
      });
    }
    await _stopDiscovery(userNavigation: true);
    GuestConnectionGuard.reset();

    if (dialogContext.mounted) {
      Navigator.of(dialogContext, rootNavigator: true).pop(null);
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await ConnectionLogger.instance.log(
      'Navigation | Return to main menu completed',
      details: 'from=manual_hotspot_join',
    );
  }

  Future<PeerEndpoint> _showIosManualHotspotJoinDialog(
    HandshakePayload payload,
    int port,
  ) async {
    final candidates = _manualHotspotCandidateIps(payload);
    await ConnectionLogger.instance.log(
      'Connection | Manual hotspot join shown',
      details:
          'ssid=${payload.hotspotSsid} raw_lan_ip=${payload.lanIp} '
          'raw_hotspot_hub_ip=${payload.rawHotspotHubIp} '
          'resolved_hotspot_hub_ip=${payload.hotspotHubIp} '
          'candidates=${candidates.map((c) => "${c.source}:${c.ip}").join(",")} '
          'hub_port=$port',
    );
    if (!mounted) throw StateError('unmounted');

    final endpoint = await showDialog<PeerEndpoint>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        var retrying = false;
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> retry() async {
              setDialogState(() {
                retrying = true;
                errorText = null;
              });
              final endpoint = await _probeManualHotspotJoin(payload, port);
              if (!context.mounted) return;
              if (endpoint != null) {
                Navigator.of(context).pop(endpoint);
                return;
              }
              if (_leavingForMainMenu || !context.mounted) return;
              setDialogState(() {
                retrying = false;
                errorText =
                    'Could not reach the sender. Join the hotspot in System Settings, '
                    'return to AirShare, then try again.';
              });
            }

            return PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Text('Join sender hotspot'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This sender is not reachable on your current Wi‑Fi. '
                        'Join its hotspot manually, return to AirShare, then retry.',
                      ),
                      const SizedBox(height: 16),
                      SelectableText('SSID: ${payload.hotspotSsid}'),
                      const SizedBox(height: 8),
                      SelectableText('Password: ${payload.hotspotPass}'),
                      const SizedBox(height: 8),
                      Text(
                        'AirShare will try ${candidates.first.ip}:$port first, then gateway fallbacks.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          errorText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor:
                          const Color(0xFF0A2463).withValues(alpha: 0.55),
                    ),
                    onPressed: () =>
                        _returnToMainMenuFromManualHotspot(context),
                    child: const Text('Cancel and Try Again'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF0A2463),
                    ),
                    onPressed: retrying
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: payload.hotspotPass),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Hotspot password copied'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                    child: const Text('Copy Password'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF0A2463),
                    ),
                    onPressed: retrying
                        ? null
                        : () async {
                            await ConnectionLogger.instance.log(
                              'Connection | Manual hotspot open Wi-Fi settings',
                              details: 'ssid=${payload.hotspotSsid}',
                            );
                            try {
                              await WlanLinkManager.instance
                                  .openWirelessSettings();
                            } catch (e) {
                              await ConnectionLogger.instance.log(
                                'Connection | Manual hotspot open settings failed',
                                details: '$e',
                              );
                            }
                          },
                    child: const Text('Open Wi‑Fi Settings'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: retrying ? null : retry,
                    child: retrying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('I joined, retry'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (endpoint == null) {
      throw const _ManualHotspotFlowCancelled();
    }
    return endpoint;
  }

  Future<PeerEndpoint?> _tryTier1Lan({
    required HandshakePayload payload,
    required int port,
    required bool skipWifiProbe,
  }) async {
    if (!payload.hasLan) {
      if (Platform.isIOS) {
        await ConnectionLogger.instance.log(
          'Connection | Tier 1 LAN missing',
          details:
              'handshake has no lan_ip — same-Wi-Fi path unavailable on iOS receiver',
        );
      }
      return null;
    }

    final onSameLan = await ConnectionTier.guestOnSameLanAs(
      payload.lanIp,
      skipWifiProbe: skipWifiProbe,
    );
    if (!onSameLan) {
      await ConnectionLogger.instance.log(
        'Connection | Tier 1 subnet check',
        details:
            'guest subnet mismatch for ${payload.lanIp}; BLE-delivered lan_ip trusted, probing TCP anyway',
      );
    }

    if (!mounted) throw StateError('unmounted');
    _setPhase(
      _GuestDiscoveryPhase.connecting,
      'Tier 1: Connecting over same Wi‑Fi…',
    );
    await ConnectionLogger.instance.log(
      'Connection | Tier 1 LAN',
      details: 'tier=LAN lan_ip=${payload.lanIp} hub_port=$port',
    );
    try {
      final lanEndpoint = await _tryTcpConnect(payload.lanIp, port);
      if (lanEndpoint != null) return lanEndpoint;
      await ConnectionLogger.instance.log(
        'Connection | Tier 1 failed',
        details:
            'tier=LAN lan_ip=${payload.lanIp} hub_port=$port reason=TCP probe failed (no reachable hub)',
      );
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'Connection | Tier 1 failed',
        details:
            'tier=LAN lan_ip=${payload.lanIp} hub_port=$port reason=${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] Tier 1 LAN exception:\n$st');
    }
    return null;
  }

  Future<void> _logTierStrategyExhausted({
    required HandshakePayload payload,
    required bool tier1Attempted,
    required bool tier2AndroidAttempted,
    required bool tier2ManualEligible,
    required bool tier3Attempted,
  }) async {
    await ConnectionLogger.instance.log(
      'Connection | Tier strategy exhausted',
      details:
          'platform=${Platform.operatingSystem} ${payload.describeForLog()} '
          'hasLan=${payload.hasLan} hasHotspot=${payload.hasHotspot} hasP2p=${payload.hasP2p} '
          'raw_hotspot_hub_ip=${payload.rawHotspotHubIp} legacy_hub_ip=${payload.legacyHubIp} '
          'tier1_attempted=$tier1Attempted tier2_android=$tier2AndroidAttempted '
          'tier2_manual_eligible=$tier2ManualEligible tier3_attempted=$tier3Attempted',
    );
    debugPrint(
      '[Discovery] All tiers failed on ${Platform.operatingSystem}: '
      '${payload.describeForLog()}',
    );
  }

  Future<PeerEndpoint> _connectViaTierStrategy(HandshakePayload payload) async {
    final port = payload.hubPort;
    final skipWifiProbe = GuestConnectionGuard.isActive;
    var tier1Attempted = false;
    var tier2AndroidAttempted = false;
    final tier2ManualEligible =
        _usesManualHotspotJoinUi() && payload.hasHotspot;
    var tier3Attempted = false;

    try {
      // Tier 1 — same LAN first (Android sender → iOS/Android/macOS guest on home Wi‑Fi).
      tier1Attempted = payload.hasLan;
      final lanEndpoint = await _tryTier1Lan(
        payload: payload,
        port: port,
        skipWifiProbe: skipWifiProbe,
      );
      if (lanEndpoint != null) return lanEndpoint;

      // Tier 2 — offline hotspot join (Android automatic; iOS/macOS manual settings flow).
      if (_supportsHotspotGuestJoin() && payload.hasHotspot) {
        tier2AndroidAttempted = true;
        if (!mounted) throw StateError('unmounted');
        try {
          await _joinHostHotspotAp(payload);
          final hotspotEndpoint = await _probeHubAfterHotspot(payload, port);
          if (hotspotEndpoint != null) return hotspotEndpoint;
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 TCP failed after hotspot join',
            details:
                'tier=hotspot lan_ip=${payload.lanIp} hub_port=$port reason=no hub on candidate IPs',
          );
        } on PlatformException catch (e) {
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 hotspot failed',
            details:
                'tier=hotspot lan_ip=${payload.lanIp} hub_port=$port reason=${e.code}: ${e.message}',
          );
        } catch (e) {
          await ConnectionLogger.instance.log(
            'Connection | Tier 2 hotspot failed',
            details:
                'tier=hotspot lan_ip=${payload.lanIp} hub_port=$port reason=$e',
          );
        }
      } else if (_usesManualHotspotJoinUi() && payload.hasHotspot) {
        _setPhase(
          _GuestDiscoveryPhase.connecting,
          'Join sender hotspot manually…',
        );
        return _showIosManualHotspotJoinDialog(payload, port);
      } else if (payload.hasHotspot && !_supportsHotspotGuestJoin()) {
        await ConnectionLogger.instance.log(
          'Connection | Tier 2 manual hotspot skipped',
          details:
              'platform=${Platform.operatingSystem} hasHotspot=true '
              'manual_ui=${_usesManualHotspotJoinUi()}',
        );
      }

      // Tier 3 — Wi‑Fi Direct (last-resort fallback).
      if (Platform.isAndroid && payload.hasP2p) {
        tier3Attempted = true;
        if (!mounted) throw StateError('unmounted');
        await WifiTierPrerequisites.ensureReadyForWifiTier(context: context);
        if (!mounted) throw StateError('unmounted');
        _setPhase(
          _GuestDiscoveryPhase.connecting,
          'Tier 3: Joining Wi‑Fi Direct group…',
        );
        await ConnectionLogger.instance.log(
          'Connection | Tier 3 P2P',
          details: 'mac=${payload.p2pMac}',
        );
        try {
          final ownerIp = await HandshakeTrace.run<String>(
            'WLAN connect (guest → hub P2P group)',
            () => WlanLinkManager.instance.connectToWifiDirectPeer(
              payload.p2pMac,
            ),
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
          final busy =
              reason.contains('reason=2') ||
              e.message?.contains('reason=2') == true;
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

      await _logTierStrategyExhausted(
        payload: payload,
        tier1Attempted: tier1Attempted,
        tier2AndroidAttempted: tier2AndroidAttempted,
        tier2ManualEligible: tier2ManualEligible,
        tier3Attempted: tier3Attempted,
      );
      throw Exception('All connection tiers failed (LAN → Hotspot → P2P)');
    } on _ManualHotspotFlowCancelled {
      rethrow;
    } on TimeoutException catch (e) {
      await ConnectionLogger.instance.log(
        'Connection | Tier strategy timeout',
        details: 'hub_port=$port $e',
      );
      throw Exception('Connection timed out. Please retry.');
    } on SocketException catch (e) {
      await ConnectionLogger.instance.log(
        'Connection | Tier strategy socket failure',
        details: 'hub_port=$port $e',
      );
      throw Exception('Could not reach the sender. Please retry.');
    } catch (e, st) {
      await ConnectionLogger.instance.log(
        'Connection | Tier strategy failed safely',
        details: '${e.runtimeType}: $e',
      );
      debugPrint('[Discovery] Tier strategy exception:\n$st');
      rethrow;
    }
  }

  @override
  void initState() {
    super.initState();
    _startPulseAnimation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_leavingForMainMenu) {
        _startDiscovery();
      }
    });
  }

  @override
  void dispose() {
    _leavingForMainMenu = true;
    _manualProbeGeneration++;
    GuestConnectionGuard.reset();
    unawaited(_stopDiscovery(userNavigation: true));
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
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0A2463).withValues(alpha: 0.55),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Continue anyway'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
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
    if (_leavingForMainMenu) return;
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
      if (!mounted || _leavingForMainMenu) return;

      await _logNetworkInterfaces();
      await ConnectionLogger.instance.log('BLE Scan Start');
      await BlePeerFilter.ensureInitialized();
      await BleTransport.instance.startScanning();
      if (!mounted || _leavingForMainMenu) return;
      _scanSubscription?.cancel();
      _seenPeers.clear();
      _scanSubscription = BleTransport.instance.scanPeers().listen(
        (peers) async {
          if (GuestConnectionGuard.isActive || _connectionUiLocked) return;
          final filtered = await BlePeerFilter.filterPeers(peers);
          for (final peer in filtered) {
            if (_seenPeers.add(peer.id)) {
              await ConnectionLogger.instance.log(
                'BLE Scan Peer Found',
                details: '${peer.friendlyName} (${peer.id})',
              );
            }
          }
          if (!mounted ||
              GuestConnectionGuard.isActive ||
              _connectionUiLocked) {
            return;
          }
          setState(() {
            _peers
              ..clear()
              ..addAll(filtered);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Peer discovery error: $e'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _stopDiscovery({bool userNavigation = false}) async {
    if (userNavigation) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
    }
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await BleTransport.instance.stopScanning();
      if (userNavigation) {
        await ConnectionLogger.instance.log(
          'Discovery | Stopped by user navigation',
        );
      }
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Discovery | Stop scanning failed',
        details: '$e',
      );
    }

    if (mounted &&
        !userNavigation &&
        !GuestConnectionGuard.isActive &&
        !_connectionUiLocked &&
        _phase == _GuestDiscoveryPhase.scanning) {
      _setPhase(_GuestDiscoveryPhase.scanning, _status);
    }
  }

  // ── AP-Isolation help dialog ─────────────────────────────────────────────

  void _showApIsolationHelp() {
    if (!mounted) return;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    // Inline bullet builder — avoids a separate private widget class.
    Widget bullet(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0A2463))),
              Expanded(child: Text(text)),
            ],
          ),
        );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trouble Connecting?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Public Wi-Fi networks (campus, café, hotel) often block '
              'direct connections between devices — this is called '
              'AP Isolation.',
            ),
            const SizedBox(height: 12),
            const Text(
              'How to fix it:',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0A2463)),
            ),
            const SizedBox(height: 8),
            if (isMobile) ...[
              bullet(
                  'Ask the Host to enable their Mobile Hotspot in Settings.'),
              bullet('Connect this device to that hotspot.'),
              bullet('Return to AirShare and try joining again.'),
            ] else ...[
              bullet(
                  'Ask the Host (or any nearby phone) to enable their Mobile Hotspot.'),
              bullet(
                  'Connect this computer to that hotspot via Wi-Fi settings.'),
              bullet('Return to AirShare and try joining again.'),
            ],
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor:
                  const Color(0xFF0A2463).withValues(alpha: 0.55),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
          if (isMobile)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  await WlanLinkManager.instance.openWirelessSettings();
                } catch (_) {}
              },
              child: const Text('Open Wi-Fi Settings'),
            ),
        ],
      ),
    );
  }

  Future<void> _lockUiForConnection() async {
    _pauseDiscoverySideEffects();
    _setPhase(
      _GuestDiscoveryPhase.connecting,
      _kHotspotConnectingOverlayMessage,
    );
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await BleTransport.instance.stopScanning();
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Discovery | Stop scanning failed',
        details: '$e',
      );
    }
  }

  Future<void> _selectPeer(BlePeer peer) async {
    GuestConnectionGuard.enter();
    _pauseDiscoverySideEffects();
    try {
      // Set the connecting peer name and handshaking phase in one setState so
      // the overlay renders with a name the moment it appears.
      if (mounted) {
        setState(() {
          _connectingPeerName = _cleanDisplayName(peer.friendlyName);
          _phase = _GuestDiscoveryPhase.handshaking;
          _status = 'Connecting…';
        });
      }

      await ConnectionLogger.instance.log(
        'BLE | Handshake sequence start',
        details: 'peer=$_connectingPeerName (${peer.id})',
      );
      final handshakePayload = await BleTransport.instance
          .establishSecureHandshake(peer);
      await ConnectionLogger.instance.log(
        'HS | ServerHello payload (BLE JSON, log-safe)',
        details: handshakePayload.describeForLog(),
      );
      // If the GATT payload carries a better name (full custom name from
      // Settings), update both the overlay label and the peer list entry.
      if (handshakePayload.friendlyName.isNotEmpty && mounted) {
        final resolvedName = handshakePayload.friendlyName;
        if (resolvedName != peer.friendlyName) {
          await ConnectionLogger.instance.log(
            'HS | Resolved sender name from payload',
            details:
                'ble="${peer.friendlyName}" payload="$resolvedName"',
          );
        }
        setState(() {
          _connectingPeerName = resolvedName;
          final idx = _peers.indexWhere((p) => p.id == peer.id);
          if (idx != -1) {
            _peers[idx] = BlePeer(
              id: peer.id,
              friendlyName: resolvedName,
              serviceUuid: peer.serviceUuid,
            );
          }
        });
      }

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
      // Gap 5 fix: reset to scanning when the user manually backs out of
      // FileListScreen. Guard with isCurrent so we do NOT restart scanning if
      // FileListScreen used popUntil() to pop this page too (e.g. host decline
      // sends the guest all the way back to home), which would otherwise cause
      // a brief ghost BLE scan and a potential reconnect loop.
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        _setPhase(_GuestDiscoveryPhase.scanning, 'Peer Discovery via BLE');
        await _startDiscovery();
      }
    } catch (e, st) {
      if (e is _ManualHotspotFlowCancelled || _leavingForMainMenu) {
        await ConnectionLogger.instance.log(
          'Connection | Manual hotspot flow ended',
          details: 'returned to main menu',
        );
        return;
      }
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
      if (!mounted) return;
      if (!wasHandshaking) {
        // BLE handshake succeeded but TCP failed — a successful handshake
        // proves the Host exists, so a TCP failure almost always means AP
        // Isolation. Show the targeted help dialog instead of a raw error.
        _showApIsolationHelp();
      } else {
        final message = e is PlatformException
            ? '${e.code}: ${e.message ?? e.details ?? "unknown"}'
            : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Secure handshake failed: $message'),
            backgroundColor: const Color(0xFFDC2626),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } finally {
      if (!_leavingForMainMenu &&
          mounted &&
          _phase == _GuestDiscoveryPhase.handshaking) {
        GuestConnectionGuard.exit();
        _setPhase(_GuestDiscoveryPhase.scanning, 'Peer Discovery via BLE');
        await _startDiscovery();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_connectionUiLocked) {
      final tt = Theme.of(context).textTheme;
      final cs = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 32),
                  if (_connectingPeerName.isNotEmpty) ...[
                    Text(
                      _connectingPeerName,
                      textAlign: TextAlign.center,
                      style: tt.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: tt.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
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
            Text(
              _kOfflineTransferPlatformNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
                            child: const Icon(
                              Icons.bluetooth_searching,
                              size: 42,
                            ),
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
                          title: Text(_cleanDisplayName(peer.friendlyName)),
                          subtitle: Text(
                            peer.serviceUuid.toLowerCase() ==
                                    kAirShareBleServiceUuid.toLowerCase()
                                ? 'AirShare Hub  ·  tap to connect'
                                : peer.serviceUuid,
                          ),
                          onTap: _connectionUiLocked
                              ? null
                              : () => _selectPeer(peer),
                        );
                      },
                    ),
            ),
            // Proactive help footer — always visible, zero false positives.
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: _showApIsolationHelp,
                icon: const Icon(Icons.wifi_off_outlined, size: 15),
                label: const Text('On public Wi-Fi? Tap for help'),
                style: TextButton.styleFrom(
                  foregroundColor:
                      const Color(0xFF0A2463).withValues(alpha: 0.55),
                  textStyle: const TextStyle(fontSize: 12),
                ),
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
