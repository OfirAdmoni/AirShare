import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:air_share/wlan_link_manager.dart';

/// Location + native checks required for offline Tier 2 (hotspot) / Tier 3 (P2P).
class WifiTierPrerequisites {
  WifiTierPrerequisites._();

  /// Desktop and non-Android targets use LAN/TCP only — no mobile Wi‑Fi tier APIs.
  static bool get _skipMobileWifiPrerequisites =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Runtime [ACCESS_FINE_LOCATION] prompt (required for WifiNetworkSpecifier dialog).
  static Future<bool> ensureFineLocationPermission({BuildContext? context}) async {
    if (_skipMobileWifiPrerequisites || !Platform.isAndroid) return true;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (context != null && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Location permission required'),
            content: const Text(
              'Android requires Location permission to show the Wi‑Fi connection '
              'dialog when joining the host hotspot. Enable it in app settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await Geolocator.openAppSettings();
                },
                child: const Text('Open settings'),
              ),
            ],
          ),
        );
      }
      return false;
    }

    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Throws if GPS/location permission is not ready for Wi‑Fi P2P on Android.
  static Future<void> ensureReadyForWifiTier({BuildContext? context}) async {
    if (_skipMobileWifiPrerequisites || !Platform.isAndroid) return;

    final granted = await ensureFineLocationPermission(context: context);
    if (!granted) {
      throw StateError(
        'Location permission is required for offline Wi‑Fi connection',
      );
    }

    var servicesEnabled = await Geolocator.isLocationServiceEnabled();
    if (!servicesEnabled && context != null && context.mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Turn on Location'),
          content: const Text(
            'Android requires Location (GPS) to be on for Wi‑Fi Direct and '
            'hotspot discovery in offline mode.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
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
      servicesEnabled = await Geolocator.isLocationServiceEnabled();
    }
    if (!servicesEnabled) {
      throw StateError('Location services (GPS) must be enabled for offline Wi‑Fi tiers');
    }

    await WlanLinkManager.instance.ensureLocationForWifiTier();
  }
}
