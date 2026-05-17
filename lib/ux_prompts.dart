import 'dart:io';

import 'package:flutter/material.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/wlan_link_manager.dart';

/// User-facing reminders for Bluetooth and manual hotspot setup.
class UxPrompts {
  UxPrompts._();

  /// On Android, prompts to enable Bluetooth when it is off at app launch.
  static Future<void> promptBluetoothOnLaunch(BuildContext context) async {
    if (!Platform.isAndroid) return;

    bool enabled = false;
    try {
      enabled = await BleTransport.instance.isBluetoothEnabled();
    } catch (_) {
      return;
    }
    if (!context.mounted || enabled) return;

    final shouldEnable = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn on Bluetooth'),
        content: const Text(
          'Please turn on Bluetooth to discover nearby devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );

    if (shouldEnable == true && context.mounted) {
      try {
        await BleTransport.instance.requestEnableBluetooth();
      } catch (_) {}
    }
  }

  /// Shown when automatic LocalOnlyHotspot fails on the sender.
  static Future<void> showManualHotspotFallback(BuildContext context) async {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enable hotspot manually'),
        content: const Text(
          'Automatic hotspot creation failed due to system restrictions. '
          'Please enable your phone\'s Hotspot manually from Settings to continue sharing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (Platform.isAndroid) {
                try {
                  await WlanLinkManager.instance.openWirelessSettings();
                } catch (_) {}
              }
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }
}
