import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/wlan_link_manager.dart';

/// User-facing reminders for Bluetooth and manual hotspot setup.
class UxPrompts {
  UxPrompts._();

  /// Advisory Bluetooth prompt shown once on app launch.
  ///
  /// Android ≤ 12 (API < 33): shows the existing "Turn on" dialog that
  /// triggers [BluetoothAdapter.ACTION_REQUEST_ENABLE] — behaviour unchanged.
  /// Android 13+ and Windows: shows an advisory dialog with "Not now" and
  /// "Open Bluetooth Settings". The user can dismiss without acting.
  static Future<void> promptBluetoothOnLaunch(BuildContext context) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;

    bool enabled = false;
    try {
      enabled = await BleTransport.instance.isBluetoothEnabled();
    } catch (_) {
      return;
    }
    if (!context.mounted || enabled) return;

    if (Platform.isAndroid) {
      int sdkInt = 33; // default to API 33+ path if detection fails
      try {
        sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      } catch (_) {}

      if (!context.mounted) return;

      if (sdkInt < 33) {
        // ─── Android ≤ 12: existing auto-enable flow — UNCHANGED ───────────
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
        // ────────────────────────────────────────────────────────────────────
      } else {
        // Android 13+: open settings manually, advisory only
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Turn on Bluetooth'),
            content: const Text(
              'Please turn on Bluetooth to discover nearby devices.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  try {
                    await BleTransport.instance.openBluetoothSettings();
                  } catch (_) {}
                },
                child: const Text('Open Bluetooth Settings'),
              ),
            ],
          ),
        );
      }
    } else {
      // Windows: open ms-settings:bluetooth, advisory only
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Turn on Bluetooth'),
          content: const Text(
            'Please turn on Bluetooth to discover nearby devices.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  await BleTransport.instance.openBluetoothSettings();
                } catch (_) {}
              },
              child: const Text('Open Bluetooth Settings'),
            ),
          ],
        ),
      );
    }
  }

  /// Blocking Bluetooth check for Send / Receive entry points.
  ///
  /// Returns true if Bluetooth is on — caller may proceed to navigate.
  /// Returns false if Bluetooth is off — shows a blocking dialog with a single
  /// "Open Bluetooth Settings" button and no dismiss option. The caller must
  /// NOT navigate when this returns false; the user must re-tap Send/Receive
  /// after enabling Bluetooth.
  static Future<bool> promptBluetoothRequiredForTransfer(
      BuildContext context) async {
    if (!Platform.isAndroid && !Platform.isWindows) return true;

    bool enabled = false;
    try {
      enabled = await BleTransport.instance.isBluetoothEnabled();
    } catch (_) {
      return true; // don't block if the check itself fails
    }
    if (enabled) return true;
    if (!context.mounted) return false;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Bluetooth required'),
        content: const Text(
          'Bluetooth is required to share files. '
          'Please turn it on to continue.',
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await BleTransport.instance.openBluetoothSettings();
              } catch (_) {}
            },
            child: const Text('Open Bluetooth Settings'),
          ),
        ],
      ),
    );
    return false;
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
