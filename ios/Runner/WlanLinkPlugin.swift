import Flutter
import UIKit

/// iOS `air_share/wlan_link` — manual Wi-Fi settings bridge only.
final class WlanLinkPlugin {
  private static let channelName = "air_share/wlan_link"

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "WlanLinkPlugin") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "connectToHubWlan":
        result(
          FlutterError(
            code: "unsupported",
            message: "Automatic hotspot join is not supported on iOS.",
            details: nil
          )
        )
      case "openWirelessSettings":
        openWirelessSettings(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func openWirelessSettings(result: @escaping FlutterResult) {
    guard let wifiUrl = URL(string: "App-Prefs:root=WIFI") else {
      result(nil)
      return
    }

    UIApplication.shared.open(wifiUrl, options: [:]) { success in
      if success {
        result(nil)
        return
      }

      guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
        result(nil)
        return
      }
      UIApplication.shared.open(settingsUrl, options: [:]) { _ in
        result(nil)
      }
    }
  }
}
