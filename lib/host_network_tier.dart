import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

/// Sender-side network plan: Tier 1 LAN when already on Wi‑Fi or a manual hotspot
/// (`wlan0` / `ap0`), otherwise automated Tier 2/3 on Android.
class HostSenderNetworkPlan {
  const HostSenderNetworkPlan({
    required this.tier1LanIp,
    required this.useTier1Only,
    required this.pickedInterface,
    this.wifiIpFromPlugin,
  });

  /// Best private IPv4 to advertise as [lan_ip] over BLE (may be on `ap0`/`ap1`).
  final String? tier1LanIp;

  /// When true, do not start LocalOnlyHotspot or Wi‑Fi Direct on the sender.
  final bool useTier1Only;

  final String? pickedInterface;
  final String? wifiIpFromPlugin;

  bool get hasTier1 => tier1LanIp != null && tier1LanIp!.isNotEmpty;
}

/// Host interface + tier selection helpers (sender staging).
class HostNetworkTier {
  HostNetworkTier._();

  static final RegExp _apInterface = RegExp(r'^ap\d+$', caseSensitive: false);

  /// Manual / system hotspot access point (`ap0`, `ap1`, …).
  static bool isHotspotAccessPointInterface(String ifaceName) {
    final l = ifaceName.trim().toLowerCase();
    if (l == 'ap0' || l == 'ap1') return true;
    if (_apInterface.hasMatch(l)) return true;
    return l.contains('softap');
  }

  /// Station-mode Wi‑Fi (`wlan0`, Windows Wi‑Fi adapters, …).
  static bool isWlanStationInterface(String ifaceName) {
    final l = ifaceName.trim().toLowerCase();
    if (Platform.isWindows) {
      return l.contains('wi-fi') ||
          l.contains('wifi') ||
          l.contains('wlan') ||
          l.contains('ethernet') ||
          l.startsWith('eth');
    }
    return l.contains('wlan') || l.contains('wifi');
  }

  /// Interfaces that may host Tier 1 when already connected (shared Wi‑Fi or manual hotspot).
  static bool isPreConnectedHostInterface(String ifaceName) {
    return isWlanStationInterface(ifaceName) ||
        isHotspotAccessPointInterface(ifaceName);
  }

  /// Never advertise hub IP from these (cellular, VPN, P2P group, USB tether, …).
  static bool isExcludedVirtualInterface(String ifaceName) {
    final l = ifaceName.trim().toLowerCase();
    if (l.contains('p2p')) return true;
    if (l.contains('rndis') || l.contains('usb')) return true;
    if (l.contains('swlan')) return true;
    if (isLikelyCellularOrWan(ifaceName)) return true;
    return false;
  }

  static bool isLikelyCellularOrWan(String name) {
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

  static bool isRealAdvertisablePrivateIp(String ip) {
    final candidate = ip.trim();
    if (candidate.isEmpty || candidate == '127.0.0.1') return false;
    if (!isPrivateOrLinkLocalIpv4(candidate)) return false;
    const knownVirtualRanges = <String>[
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

  static bool isPrivateOrLinkLocalIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
    final a = octets[0]!;
    final b = octets[1]!;
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  static int _preferenceScore(String ifaceName, String ip) {
    final l = ifaceName.toLowerCase();
    var score = 0;
    if (l == 'wlan0' || l.endsWith('wlan0')) score += 60;
    if (l.contains('wlan')) score += 40;
    if (l.contains('wifi') || l.contains('wi-fi')) score += 35;
    if (isHotspotAccessPointInterface(ifaceName)) score += 30;
    if (l.contains('ethernet') || l.startsWith('eth')) score += 15;
    final parts = ip.split('.');
    if (parts.length == 4 && parts[3] == '1') score += 4;
    return score;
  }

  /// Scans local interfaces for a Tier 1 [lan_ip] and whether Tier 2/3 can be skipped.
  static Future<HostSenderNetworkPlan> planSenderStartup() async {
    final wifiRaw = (await NetworkInfo().getWifiIP())?.trim();
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    final ipsOnCellular = <String>{};
    for (final iface in interfaces) {
      if (!isLikelyCellularOrWan(iface.name)) continue;
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          ipsOnCellular.add(addr.address);
        }
      }
    }

    var wifiIp = wifiRaw;
    if (wifiIp != null &&
        wifiIp.isNotEmpty &&
        ipsOnCellular.contains(wifiIp)) {
      wifiIp = null;
    }

    final scored = <({String name, String ip, int score})>[];

    void considerInterface(NetworkInterface iface) {
      if (isExcludedVirtualInterface(iface.name)) return;
      if (!isPreConnectedHostInterface(iface.name)) return;
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        final ip = addr.address;
        if (!isRealAdvertisablePrivateIp(ip)) continue;
        scored.add((
          name: iface.name,
          ip: ip,
          score: _preferenceScore(iface.name, ip),
        ));
      }
    }

    for (final iface in interfaces) {
      considerInterface(iface);
    }

    if (scored.isEmpty && Platform.isWindows) {
      for (final iface in interfaces) {
        if (isExcludedVirtualInterface(iface.name)) continue;
        if (isHotspotAccessPointInterface(iface.name)) continue;
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final ip = addr.address;
          if (!isRealAdvertisablePrivateIp(ip)) continue;
          scored.add((name: iface.name, ip: ip, score: 10));
        }
      }
    }

    if (wifiIp != null &&
        wifiIp.isNotEmpty &&
        isRealAdvertisablePrivateIp(wifiIp)) {
      final onPreConnected = scored.any((c) => c.ip == wifiIp);
      if (!onPreConnected) {
        scored.add((name: 'network_info_plus', ip: wifiIp, score: 25));
      }
    }

    if (scored.isEmpty) {
      return HostSenderNetworkPlan(
        tier1LanIp: null,
        useTier1Only: false,
        pickedInterface: null,
        wifiIpFromPlugin: wifiRaw,
      );
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final best = scored.first;
    return HostSenderNetworkPlan(
      tier1LanIp: best.ip,
      useTier1Only: true,
      pickedInterface: best.name,
      wifiIpFromPlugin: wifiRaw,
    );
  }
}
