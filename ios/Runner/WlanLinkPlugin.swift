import Flutter
import NetworkExtension

/// iOS `air_share/wlan_link` — guest join to host hotspot via NEHotspotConfiguration.
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
        connectToHubWlan(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func connectToHubWlan(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let ssid = (args["ssid"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !ssid.isEmpty,
          let password = args["password"] as? String,
          !password.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_wlan_credentials",
          message: "SSID and password are required.",
          details: nil
        )
      )
      return
    }

    let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
    configuration.joinOnce = true

    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      if let error {
        let nsError = error as NSError
        if nsError.domain == NEHotspotConfigurationErrorDomain,
           nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
        {
          result(nil)
          return
        }
        result(
          FlutterError(
            code: "wlan_join_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }
      result(nil)
    }
  }
}
