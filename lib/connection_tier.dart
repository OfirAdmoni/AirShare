import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

/// Helpers for LAN → hotspot → Wi‑Fi Direct tier selection.
class ConnectionTier {
  ConnectionTier._();

  static bool sameIpv4Subnet(String a, String b) {
    final pa = a.trim().split('.');
    final pb = b.trim().split('.');
    if (pa.length != 4 || pb.length != 4) return false;
    return pa[0] == pb[0] && pa[1] == pb[1] && pa[2] == pb[2];
  }

  /// Conservative fallback when subnet mask details are unavailable:
  /// treat private IPv4 addresses with matching first two octets as likely LAN.
  static bool samePrivatePrefixFallback(String a, String b) {
    final pa = a.trim().split('.');
    final pb = b.trim().split('.');
    if (pa.length != 4 || pb.length != 4) return false;
    final a0 = int.tryParse(pa[0]);
    final a1 = int.tryParse(pa[1]);
    final b0 = int.tryParse(pb[0]);
    final b1 = int.tryParse(pb[1]);
    if (a0 == null || a1 == null || b0 == null || b1 == null) return false;
    final same16 = a0 == b0 && a1 == b1;
    if (!same16) return false;
    final aPrivate = _isPrivateOrLinkLocalIpv4(a0, a1);
    final bPrivate = _isPrivateOrLinkLocalIpv4(b0, b1);
    return aPrivate && bPrivate;
  }

  static bool _isPrivateOrLinkLocalIpv4(int o0, int o1) {
    if (o0 == 10) return true;
    if (o0 == 172 && o1 >= 16 && o1 <= 31) return true;
    if (o0 == 192 && o1 == 168) return true;
    if (o0 == 169 && o1 == 254) return true;
    return false;
  }

  /// True when the device has a Wi‑Fi IPv4 on the same /24 as [hostLanIp].
  ///
  /// Set [skipWifiProbe] while joining a hotspot so [NetworkInfo.getWifiIP] does
  /// not trigger a background Wi‑Fi scan that steals focus from the system dialog.
  static Future<bool> guestOnSameLanAs(
    String hostLanIp, {
    bool skipWifiProbe = false,
  }) async {
    if (hostLanIp.trim().isEmpty) return false;
    try {
      if (!skipWifiProbe) {
        final wifiIp = (await NetworkInfo().getWifiIP())?.trim();
        if (wifiIp != null && wifiIp.isNotEmpty) {
          if (sameIpv4Subnet(wifiIp, hostLanIp) ||
              samePrivatePrefixFallback(wifiIp, hostLanIp)) {
            return true;
          }
        }
      }
      for (final iface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        final name = iface.name.toLowerCase();
        if (name.contains('pdp') ||
            name.contains('rmnet') ||
            name.contains('wwan') ||
            name.contains('cellular')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (sameIpv4Subnet(addr.address, hostLanIp) ||
              samePrivatePrefixFallback(addr.address, hostLanIp)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static String? deriveGatewayIp(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.1';
  }
}
