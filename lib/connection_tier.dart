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
          return sameIpv4Subnet(wifiIp, hostLanIp);
        }
      }
      for (final iface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        final name = iface.name.toLowerCase();
        if (!name.contains('wlan') && !name.contains('wifi')) continue;
        for (final addr in iface.addresses) {
          if (sameIpv4Subnet(addr.address, hostLanIp)) return true;
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
