import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-visible BLE / transfer friendly name (prefs + hardware fallback).
class DeviceBranding {
  DeviceBranding._();

  static const String _prefKey = 'ble_friendly_display_name';

  /// OS-reported model or hostname (no hard-coded product string).
  static Future<String> hardwareDefaultName() async {
    final plugin = DeviceInfoPlugin();
    try {
      if (kIsWeb) {
        return 'Browser';
      }
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await plugin.androidInfo;
          final model = a.model.trim();
          if (model.isNotEmpty) return model;
          final product = a.product.trim();
          if (product.isNotEmpty) return product;
          return 'Android';
        case TargetPlatform.iOS:
          final i = await plugin.iosInfo;
          final machine = i.utsname.machine.trim();
          if (machine.isNotEmpty) return machine;
          final model = i.model.trim();
          if (model.isNotEmpty) return model;
          return 'iOS';
        case TargetPlatform.windows:
          final w = await plugin.windowsInfo;
          final name = w.computerName.trim();
          if (name.isNotEmpty) return name;
          return 'Windows';
        case TargetPlatform.linux:
          final l = await plugin.linuxInfo;
          final name = l.prettyName.trim();
          if (name.isNotEmpty) return name;
          return 'Linux';
        case TargetPlatform.macOS:
          final m = await plugin.macOsInfo;
          final model = m.model.trim();
          if (model.isNotEmpty) return model;
          return 'macOS';
        default:
          return 'Device';
      }
    } catch (_) {
      return 'Device';
    }
  }

  /// Raw saved value (may be empty).
  static Future<String?> savedDisplayNameRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey);
  }

  static Future<void> saveDisplayName(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final t = value.trim();
    if (t.isEmpty) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, t);
    }
  }

  /// Name to pass to native `startHubAdvertising`: custom if set, else [hardwareDefaultName].
  static Future<String> effectiveAdvertisingName() async {
    final saved = await savedDisplayNameRaw();
    if (saved != null && saved.trim().isNotEmpty) {
      return saved.trim();
    }
    return hardwareDefaultName();
  }
}
