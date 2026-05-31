import 'dart:io';

/// Central platform gates for native-only APIs (BLE radio, WLAN tiers).
///
/// Use these instead of scattering [Platform.is*] checks so Windows never
/// invokes mobile-only method channels by mistake.
abstract final class PlatformGuards {
  static bool get isAndroid => Platform.isAndroid;
  static bool get isIos => Platform.isIOS;
  static bool get isWindows => Platform.isWindows;

  /// Desktop targets with multiple NICs (Ethernet, Wi‑Fi, virtual adapters).
  static bool get isDesktop =>
      isWindows || Platform.isLinux || Platform.isMacOS;

  /// Mobile OS builds that use native BLE + WLAN method channels.
  static bool get isMobileNative => isAndroid || isIos;

  /// Desktop / mobile targets with a Dart BLE transport implementation.
  static bool get supportsBleTransport =>
      isAndroid || isIos || isWindows;

  /// Android-only Wi‑Fi Direct, LocalOnlyHotspot, and related APIs.
  static bool get supportsAndroidWlan => isAndroid;

  /// Android or iOS guest join to a hub SSID via system UI.
  static bool get supportsGuestWlanJoin => isAndroid || isIos;

  /// Windows-hosted temporary hotspot (hosted network profile).
  static bool get supportsWindowsHotspot => isWindows;
}
