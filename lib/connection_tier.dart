import 'dart:io';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/platform_guards.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// Standard gateway IPs for offline Tier 2 (local-only / personal hotspot).
abstract final class HotspotGateway {
  /// Android [WifiManager.LocalOnlyHotspot] default gateway.
  static const String android = '192.168.43.1';

  /// iOS Personal Hotspot default gateway.
  static const String ios = '172.20.10.1';

  static String forHostPlatform() {
    if (Platform.isIOS) return ios;
    if (Platform.isAndroid) return android;
    return android;
  }

  /// Parses optional `platform` / `host_platform` from BLE handshake JSON.
  static String? hostPlatformFromMap(Map<dynamic, dynamic> map) {
    final raw = (map['host_platform'] ?? map['platform'] ?? '').toString().trim();
    if (raw.isEmpty) return null;
    return raw.toLowerCase();
  }

  static bool isStandardGateway(String ip) {
    final t = ip.trim();
    return t == android || t == ios;
  }

  static bool isCellularOrWanInterfaceName(String name) {
    final lower = name.toLowerCase();
    return lower.contains('ccmni') ||
        lower.contains('rmnet') ||
        lower.contains('pdp') ||
        lower.contains('cell') ||
        lower.contains('wwan') ||
        lower.contains('mobile') ||
        lower.contains('epdg') ||
        lower.contains('v4-rmnet') ||
        lower.contains('clat');
  }

  /// Carrier/NAT IPv4 that must never be published as Tier 2 `lan_ip` / `hub_ip`.
  static bool isLikelyCarrierWanIp(String ip) {
    final t = ip.trim();
    if (t.isEmpty) return false;
    if (isStandardGateway(t)) return false;
    if (t.startsWith('10.')) return true;
    if (t.startsWith('100.')) return true;
    return false;
  }

  /// True when [ip] must not be used as a hotspot-routable hub target on the guest.
  static bool isUnusableForTier2Hub(String ip) {
    final t = ip.trim();
    if (t.isEmpty) return true;
    if (isStandardGateway(t)) return false;
    if (isLikelyCarrierWanIp(t)) return true;
    return false;
  }

  /// Infers which standard gateway the host hotspot uses.
  static String inferHostGateway(HandshakePayload payload) {
    final platform = payload.hostPlatform.toLowerCase();
    if (platform.contains('ios')) return ios;
    if (platform.contains('android')) return android;
    if (payload.hotspotHubIp == ios || payload.lanIp == ios) return ios;
    if (payload.lanIp.startsWith('172.20.10.') ||
        payload.hotspotHubIp.startsWith('172.20.10.')) {
      return ios;
    }
    return android;
  }

  /// BLE `lan_ip` + `hotspot_hub_ip` when Tier 2 hotspot is the active host path.
  static ({String lanIp, String hotspotHubIp}) bleEndpointsForHotspotHost({
    String? hostPlatform,
  }) {
    final platform = (hostPlatform ?? '').toLowerCase();
    final gateway = platform == 'ios' ? ios : android;
    return (lanIp: gateway, hotspotHubIp: gateway);
  }

  /// Ordered hub IPs to probe after joining the host AP (guest Tier 2).
  static List<String> tier2ProbeCandidates(HandshakePayload payload) {
    final gateway = inferHostGateway(payload);
    final out = <String>[gateway];
    void add(String ip) {
      final t = ip.trim();
      if (t.isEmpty || isUnusableForTier2Hub(t)) return;
      if (!out.contains(t)) out.add(t);
    }

    add(payload.hotspotHubIp);
    if (!isUnusableForTier2Hub(payload.lanIp)) add(payload.lanIp);
    add(payload.p2pIp);
    if (Platform.isAndroid) add(android);
    if (Platform.isIOS) add(ios);
    return out;
  }
}

/// Helpers for LAN → hotspot → Wi‑Fi Direct tier selection.
class ConnectionTier {
  ConnectionTier._();

  /// Same IPv4 /24 subnet (255.255.255.0) — first three octets must match.
  static bool sameIpv4Subnet(String guestIp, String hostLanIp) {
    final pa = guestIp.trim().split('.');
    final pb = hostLanIp.trim().split('.');
    if (pa.length != 4 || pb.length != 4) return false;
    return pa[0] == pb[0] && pa[1] == pb[1] && pa[2] == pb[2];
  }

  /// True when ANY local non-loopback IPv4 is on the same /24 as [hostLanIp].
  ///
  /// On desktop (Windows/macOS/Linux) every active NIC is considered so a
  /// VirtualBox adapter on 192.168.56.x does not hide Wi‑Fi on 192.168.1.x.
  ///
  /// Set [skipWifiProbe] while joining a hotspot so [NetworkInfo.getWifiIP] does
  /// not trigger a background Wi‑Fi scan that steals focus from the system dialog.
  static Future<bool> guestOnSameLanAs(
    String hostLanIp, {
    bool skipWifiProbe = false,
  }) async {
    final host = hostLanIp.trim();
    if (host.isEmpty) return false;

    try {
      if (!skipWifiProbe) {
        final wifiIp = (await NetworkInfo().getWifiIP())?.trim();
        if (wifiIp != null &&
            wifiIp.isNotEmpty &&
            sameIpv4Subnet(wifiIp, host)) {
          return true;
        }
        // A non-matching getWifiIP() must not short-circuit — check all NICs.
      }

      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        if (_skipInterfaceForGuestLanCheck(iface)) continue;
        for (final addr in iface.addresses) {
          if (sameIpv4Subnet(addr.address, host)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  /// Cellular/WWAN only on mobile; Android station-mode filter; desktop checks all NICs.
  static bool _skipInterfaceForGuestLanCheck(NetworkInterface iface) {
    if (HotspotGateway.isCellularOrWanInterfaceName(iface.name)) {
      return true;
    }
    final name = iface.name.toLowerCase();
    if (name.contains('pdp') ||
        name.contains('rmnet') ||
        name.contains('wwan') ||
        name.contains('cellular')) {
      return true;
    }
    if (PlatformGuards.isDesktop) {
      return false;
    }
    if (Platform.isAndroid &&
        !name.contains('wlan') &&
        !name.contains('wifi')) {
      return true;
    }
    return false;
  }

  /// Loopback or unspecified addresses — never valid guest hub targets.
  static bool isLoopbackAddress(String host) {
    final trimmed = host.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'localhost') return true;
    try {
      return InternetAddress(trimmed).isLoopback;
    } catch (_) {
      return false;
    }
  }

  /// All IPv4 addresses assigned to this device (including loopback).
  static Future<Set<String>> enumerateLocalIpv4Addresses() async {
    final out = <String>{'127.0.0.1'};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          out.add(addr.address);
        }
      }
    } catch (_) {}
    return out;
  }

  /// True when [host] is this device's own interface (loopback ghost).
  static Future<bool> isOwnInterfaceAddress(String host) async {
    final h = host.trim();
    if (isLoopbackAddress(h)) return true;
    final locals = await enumerateLocalIpv4Addresses();
    return locals.contains(h);
  }

  /// Non-null when a guest/receiver must not connect to [host].
  static Future<String?> guestHubTargetRejectionReason(String host) async {
    final h = host.trim();
    if (h.isEmpty) return 'empty host';
    if (isLoopbackAddress(h)) return 'loopback address';
    if (await isOwnInterfaceAddress(h)) {
      return 'target is a local interface address';
    }
    return null;
  }

  /// Guest hub targets must come from BLE and must not match local NICs.
  static Future<bool> isAllowedGuestHubTarget(String host) async {
    return (await guestHubTargetRejectionReason(host)) == null;
  }
}
