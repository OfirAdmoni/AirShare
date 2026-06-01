import AppKit
import FlutterMacOS

/// macOS `air_share/wlan_link` — open Wi‑Fi / Network settings for manual hotspot join.
final class WlanLinkPlugin {
  private static let channelName = "air_share/wlan_link"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openWirelessSettings":
        openWirelessSettings(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSLog("AirShareWLANmacOS: plugin registered on %@", channelName)
  }

  private static func openWirelessSettings(result: @escaping FlutterResult) {
    let candidates = [
      "x-apple.systempreferences:com.apple.Network-Settings.extension",
      "x-apple.systempreferences:com.apple.preference.network",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
        NSLog("AirShareWLANmacOS: opened wireless settings via %@", candidate)
        result(nil)
        return
      }
    }
    result(
      FlutterError(
        code: "settings_unavailable",
        message: "Could not open Network settings.",
        details: nil
      )
    )
  }
}
