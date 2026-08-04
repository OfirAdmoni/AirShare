import 'dart:io';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/session_context.dart';
import 'package:air_share/wlan_link_manager.dart';

/// Unified teardown sequences for sender and receiver flows.
///
/// Every step is best-effort — a failure in one step does not prevent
/// subsequent steps from running. Callers are responsible for holding
/// their own idempotency guard (_teardownRan) before invoking.
class SessionTeardown {
  SessionTeardown._();

  /// Full sender teardown in the approved order:
  /// BLE advertising → HTTP server → Hotspot → P2P → State.
  ///
  /// [hotspotStartInFlight] logs a diagnostic when teardown races a hotspot
  /// start that is still in progress (Risk C from the audit).
  static Future<void> runSenderTeardown({
    bool hotspotStartInFlight = false,
  }) async {
    if (hotspotStartInFlight) {
      await ConnectionLogger.instance.log(
        'Teardown | Hotspot release called while start in progress',
      );
    }

    try {
      await BleTransport.instance.stopHubAdvertising();
      await ConnectionLogger.instance.log('Teardown | BLE advertising stopped');
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Teardown | BLE advertising stop failed',
        details: '$e',
      );
    }

    final sharedDirPath = LocalHubRuntime.instance.sharedDirPath;

    try {
      await LocalHubRuntime.instance.stop();
      await ConnectionLogger.instance.log('Teardown | HTTP server closed');
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Teardown | HTTP server close failed',
        details: '$e',
      );
    }

    if (sharedDirPath != null) {
      try {
        await _cleanSharedDirectory(sharedDirPath);
        await ConnectionLogger.instance.log('Teardown | Shared directory cleared');
      } catch (e) {
        await ConnectionLogger.instance.log(
          'Teardown | Shared directory cleanup failed',
          details: '$e',
        );
      }
    }

    if (Platform.isAndroid) {
      try {
        await WlanLinkManager.instance.stopNativeHotspot();
        await ConnectionLogger.instance.log('Teardown | Hotspot released');
      } catch (e) {
        await ConnectionLogger.instance.log(
          'Teardown | Hotspot release failed',
          details: '$e',
        );
      }

      try {
        await WlanLinkManager.instance.stopWifiDirectGroup();
        await ConnectionLogger.instance.log('Teardown | P2P group released');
      } catch (e) {
        await ConnectionLogger.instance.log(
          'Teardown | P2P release failed',
          details: '$e',
        );
      }
    }

    try {
      HubEndpointState.instance.clear();
      await SessionContext.wipeHostAuthState(reason: 'sender_teardown');
      await SessionContext.wipeGuestSide(reason: 'sender_teardown');
      await ConnectionLogger.instance.log('Teardown | State reset complete');
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Teardown | State reset failed',
        details: '$e',
      );
    }
  }

  static Future<void> _cleanSharedDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      stdout.writeln('CLEANUP: Directory not found — nothing to delete: $dirPath');
      return;
    }
    var deleted = 0;
    var failed = 0;
    await for (final entity in dir.list()) {
      try {
        await entity.delete(recursive: true);
        deleted++;
        stdout.writeln('CLEANUP: Deleted ${entity.path}');
      } catch (e) {
        failed++;
        stdout.writeln('CLEANUP ERROR: Could not delete ${entity.path}: $e');
      }
    }
    stdout.writeln(
      'CLEANUP SUCCESS: Deleted $deleted file(s) from $dirPath'
      '${failed > 0 ? " — $failed could not be deleted" : ""}',
    );
  }

  /// Receiver-side teardown: BLE scanner → connection guard → guest crypto state.
  static Future<void> runReceiverTeardown() async {
    try {
      await BleTransport.instance.stopScanning();
      await ConnectionLogger.instance.log('Teardown | BLE scanning stopped');
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Teardown | BLE scan stop failed',
        details: '$e',
      );
    }

    try {
      await SessionContext.wipeGuestSide(reason: 'receiver_teardown');
      await ConnectionLogger.instance.log('Teardown | State reset complete');
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Teardown | State reset failed',
        details: '$e',
      );
    }
  }
}
