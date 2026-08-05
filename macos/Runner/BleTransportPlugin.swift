import AppKit
import CoreBluetooth
import FlutterMacOS

/// macOS BLE transport — mirrors `air_share/ble_transport` + `air_share/ble_scan_events`.
/// Guest central: scan + secure handshake (notify/read ServerHello JSON).
/// Host GATT advertising is not implemented on macOS yet.
final class BleTransportPlugin: NSObject {
  private static let methodChannelName = "air_share/ble_transport"
  private static let scanEventChannelName = "air_share/ble_scan_events"

  private static let serviceUuid = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
  private static let handshakeCharacteristicUuid = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
  private static let endpointCharacteristicUuid = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

  private let methodChannel: FlutterMethodChannel
  private let scanEventChannel: FlutterEventChannel

  private var centralManager: CBCentralManager!
  private var scanEventSink: FlutterEventSink?
  private var isScanning = false
  private var discoveredPeers: [String: [String: String]] = [:]
  private var discoveredPeripherals: [String: CBPeripheral] = [:]
  private var pendingStartScanResult: FlutterResult?

  private var localBlePeerId = ""
  private var localAdvertisingName = ""
  private var localHostName = Host.current().localizedName ?? ""

  // Guest handshake state
  private var activeGuestPeripheral: CBPeripheral?
  private var handshakeDeliveryResult: FlutterResult?
  private var handshakeDelivered = false
  private var handshakeWaitWorkItem: DispatchWorkItem?
  private var guestHandshakeCharacteristic: CBCharacteristic?
  private var pendingGuestClientHelloData: Data?

  private static var retained: BleTransportPlugin?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
    scanEventChannel = FlutterEventChannel(name: Self.scanEventChannelName, binaryMessenger: messenger)
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: nil)
    methodChannel.setMethodCallHandler(handleMethodCall)
    scanEventChannel.setStreamHandler(self)
    logBle("macOS BLE plugin registered (channels: \(Self.methodChannelName), \(Self.scanEventChannelName))")
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    retained = BleTransportPlugin(messenger: registrar.messenger)
  }

  private func logBle(_ message: String) {
    NSLog("AirShareBLEmacOS: %@", message)
  }

  private func centralStateLabel(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "unknown(\(state.rawValue))"
    }
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startScanning":
      startScanning(result: result)
    case "stopScanning":
      stopScanning(result: result)
    case "establishSecureHandshake":
      establishSecureHandshake(call: call, result: result)
    case "isBluetoothEnabled":
      result(centralManager.state == .poweredOn)
    case "requestEnableBluetooth":
      result([
        "enabled": centralManager.state == .poweredOn,
        "prompted": false,
      ])
    case "openBluetoothSettings":
      openBluetoothSettings(result: result)
    case "getLocalPeerId":
      getLocalPeerId(result: result)
    case "syncLocalBleIdentity":
      syncLocalBleIdentity(call: call, result: result)
    case "shareLogs":
      result(
        FlutterError(
          code: "unsupported",
          message: "Share logs is only supported on Android",
          details: nil
        )
      )
    case "startHubAdvertising",
         "stopHubAdvertising",
         "readPeerEndpoint",
         "updateHubEndpoint",
         "updateConnectionEndpoints",
         "approveConnection":
      unsupported(call.method, result: result)
    default:
      logBle("missing/unsupported method: \(call.method)")
      result(FlutterMethodNotImplemented)
    }
  }

  private func unsupported(_ method: String, result: @escaping FlutterResult) {
    logBle("unsupported method: \(method)")
    result(
      FlutterError(
        code: "unsupported",
        message: "macOS BLE transport does not implement \(method) yet.",
        details: method
      )
    )
  }

  // MARK: - Scan

  private func startScanning(result: @escaping FlutterResult) {
    logBle("central manager state=\(centralStateLabel(centralManager.state))")
    guard centralManager.state == .poweredOn else {
      if centralManager.state == .unknown || centralManager.state == .resetting {
        pendingStartScanResult = result
        logBle("startScanning deferred until Bluetooth is ready")
        return
      }
      result(
        FlutterError(
          code: "ble_unavailable",
          message: "Bluetooth is not powered on.",
          details: centralStateLabel(centralManager.state)
        )
      )
      return
    }
    if isScanning {
      logBle("startScanning: already scanning")
      result(nil)
      return
    }
    discoveredPeers.removeAll()
    discoveredPeripherals.removeAll()
    isScanning = true
    centralManager.scanForPeripherals(
      withServices: [Self.serviceUuid],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
    logBle("scanning started service=\(Self.serviceUuid.uuidString)")
    result(nil)
  }

  private func stopScanning(result: @escaping FlutterResult) {
    if isScanning {
      centralManager.stopScan()
      isScanning = false
      logBle("scanning stopped")
    } else {
      logBle("stopScanning: not scanning (no-op success)")
    }
    result(nil)
  }

  private func emitScanPeers() {
    guard let sink = scanEventSink else { return }
    sink(Array(discoveredPeers.values))
  }

  // MARK: - Guest handshake

  private func buildClientHelloData(peerId: String, displayName: String) -> Data {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = name.isEmpty ? "Guest" : name
    let payload: [String: String] = [
      "type": "client_hello",
      "peer_id": peerId.trimmingCharacters(in: .whitespacesAndNewlines),
      "display_name": resolved,
    ]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }

  private func beginGuestHandshakeNotify(
    peripheral: CBPeripheral,
    handshakeChar: CBCharacteristic
  ) {
    guestHandshakeCharacteristic = handshakeChar
    logBle("ClientHello: subscribe notify + initial read on handshake characteristic")
    peripheral.setNotifyValue(true, for: handshakeChar)
    peripheral.readValue(for: handshakeChar)
  }

  private func establishSecureHandshake(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let peerId = (args["peerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !peerId.isEmpty,
          let peripheral = discoveredPeripherals[peerId]
    else {
      logBle("handshake start failed: peer_not_found")
      result(FlutterError(code: "peer_not_found", message: "Unable to resolve peer device.", details: nil))
      return
    }

    let guestPeerId = (args["guestPeerId"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines).flatMap { $0.isEmpty ? nil : $0 } ?? peerId
    let guestDisplayName = (args["guestDisplayName"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let json = (args["clientHelloJson"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !json.isEmpty,
       let data = json.data(using: .utf8) {
      pendingGuestClientHelloData = data
    } else {
      pendingGuestClientHelloData = buildClientHelloData(peerId: guestPeerId, displayName: guestDisplayName)
    }

    logBle(
      "handshake start peerId=\(peerId) name=\(peripheral.name ?? "?") "
        + "expected service=\(Self.serviceUuid.uuidString) "
        + "handshake char=\(Self.handshakeCharacteristicUuid.uuidString)"
    )
    cancelHandshakeWait()
    handshakeDelivered = false
    handshakeDeliveryResult = result
    guestHandshakeCharacteristic = nil

    if let active = activeGuestPeripheral, active != peripheral {
      centralManager.cancelPeripheralConnection(active)
    }
    activeGuestPeripheral = peripheral
    peripheral.delegate = self
    logBle("ClientHello: connect + discover service \(Self.serviceUuid.uuidString)")
    centralManager.connect(peripheral, options: nil)
    scheduleHandshakeWait(for: peripheral)
  }

  private func trimmedString(_ json: [String: Any], _ key: String) -> String {
    (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// Matches Android [parseHandshakePayload]: explicit [lan_ip] only (no hubIp alias into Tier 1 LAN).
  private func parseHubPort(_ json: [String: Any]) -> Int {
    if let port = json["hub_port"] as? Int { return port }
    if let port = json["hub_port"] as? NSNumber { return port.intValue }
    if let port = json["hubPort"] as? Int { return port }
    if let port = json["hubPort"] as? NSNumber { return port.intValue }
    if let raw = json["hub_port"] as? String, let port = Int(raw) { return port }
    if let raw = json["hubPort"] as? String, let port = Int(raw) { return port }
    return 8080
  }

  private func parseHandshakeMap(_ data: Data) -> [String: Any]? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      logBle("ServerHello parse failed: invalid JSON (\(data.count) bytes)")
      return nil
    }
    let rawKeys = json.keys.sorted().joined(separator: ",")
    logBle("ServerHello raw JSON keys=[\(rawKeys)] service=\(Self.serviceUuid.uuidString) handshake=\(Self.handshakeCharacteristicUuid.uuidString)")
    if !handshakePayloadIsReady(json) {
      if let preview = String(data: data, encoding: .utf8) {
        logBle("ServerHello not ready yet (awaiting host approval): \(preview.prefix(200))")
      }
      return nil
    }
    let lanIp = trimmedString(json, "lan_ip")
    let hubIpLegacy = trimmedString(json, "hubIp")
    let hotspotHubIp = trimmedString(json, "hotspot_hub_ip")
    let port = parseHubPort(json)
    let p2pMac = trimmedString(json, "p2p_mac")
    let p2pMacResolved = p2pMac.isEmpty ? trimmedString(json, "p2pMac") : p2pMac
    let hotspotSsid = trimmedString(json, "hotspot_ssid")
    let hotspotSsidResolved = hotspotSsid.isEmpty ? trimmedString(json, "ssid") : hotspotSsid
    let hotspotPass = trimmedString(json, "hotspot_pass")
    let hotspotPassResolved = hotspotPass.isEmpty ? trimmedString(json, "password") : hotspotPass
    let map: [String: Any] = [
      "lan_ip": lanIp,
      "p2p_ip": trimmedString(json, "p2p_ip"),
      "p2p_mac": p2pMacResolved,
      "hotspot_ssid": hotspotSsidResolved,
      "hotspot_pass": hotspotPassResolved,
      "hotspot_hub_ip": hotspotHubIp,
      "hubIp": hubIpLegacy,
      "hub_port": port,
      "friendly_name": trimmedString(json, "friendly_name"),
    ]
    logBle(
      "ServerHello normalized for Flutter: lan_ip=\(lanIp) hubIp=\(hubIpLegacy) "
        + "hotspot_hub_ip=\(hotspotHubIp) p2p_ip=\(map["p2p_ip"] ?? "") "
        + "hotspot_ssid_len=\((map["hotspot_ssid"] as? String)?.count ?? 0) hub_port=\(port)"
    )
    return map
  }

  private func handshakePayloadIsReady(_ json: [String: Any]) -> Bool {
    func nonEmpty(_ key: String) -> Bool {
      (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    return nonEmpty("lan_ip") || nonEmpty("hubIp") || nonEmpty("p2p_ip")
      || nonEmpty("p2p_mac") || nonEmpty("p2pMac") || nonEmpty("hotspot_ssid") || nonEmpty("ssid")
  }

  private func deliverGuestHandshake(_ data: Data, source: String) {
    if handshakeDelivered { return }
    guard let map = parseHandshakeMap(data) else { return }
    handshakeDelivered = true
    cancelHandshakeWait()
    if let json = String(data: data, encoding: .utf8) {
      logBle("ServerHello received via \(source): \(json.prefix(240))")
    } else {
      logBle("ServerHello received via \(source) (\(data.count) bytes)")
    }
    guard let result = handshakeDeliveryResult else { return }
    handshakeDeliveryResult = nil
    if let peripheral = activeGuestPeripheral {
      centralManager.cancelPeripheralConnection(peripheral)
      activeGuestPeripheral = nil
    }
    guestHandshakeCharacteristic = nil
    result(map)
  }

  private func scheduleHandshakeWait(for peripheral: CBPeripheral) {
    cancelHandshakeWait()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.handshakeDelivered else { return }
      self.logBle("handshake timeout: no ServerHello within 45s peer=\(peripheral.identifier.uuidString)")
      self.handshakeDeliveryResult?(
        FlutterError(
          code: "handshake_timeout",
          message: "Timed out waiting for host approval notification.",
          details: nil
        )
      )
      self.handshakeDeliveryResult = nil
      self.centralManager.cancelPeripheralConnection(peripheral)
      self.activeGuestPeripheral = nil
      self.guestHandshakeCharacteristic = nil
    }
    handshakeWaitWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
  }

  private func cancelHandshakeWait() {
    handshakeWaitWorkItem?.cancel()
    handshakeWaitWorkItem = nil
  }

  private func failHandshake(
    code: String,
    message: String,
    peripheral: CBPeripheral?,
    details: String? = nil
  ) {
    if handshakeDelivered { return }
    logBle("handshake failure code=\(code) reason=\(message)\(details.map { " details=\($0)" } ?? "")")
    handshakeDeliveryResult?(
      FlutterError(code: code, message: message, details: details)
    )
    handshakeDeliveryResult = nil
    cancelHandshakeWait()
    if let peripheral {
      centralManager.cancelPeripheralConnection(peripheral)
    }
    if peripheral === activeGuestPeripheral {
      activeGuestPeripheral = nil
    }
    guestHandshakeCharacteristic = nil
  }

  private func openBluetoothSettings(result: @escaping FlutterResult) {
    let candidates = [
      "x-apple.systempreferences:com.apple.BluetoothSettings",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
        logBle("opened Bluetooth settings via \(candidate)")
        result(nil)
        return
      }
    }
    result(
      FlutterError(
        code: "settings_unavailable",
        message: "Could not open Bluetooth settings.",
        details: nil
      )
    )
  }

  private func getLocalPeerId(result: @escaping FlutterResult) {
    let key = "air_share_macos_ble_peer_id"
    let defaults = UserDefaults.standard
    var peerId = defaults.string(forKey: key)
    if peerId == nil || peerId!.isEmpty {
      peerId = UUID().uuidString
      defaults.set(peerId, forKey: key)
    }
    localBlePeerId = peerId!
    result(["peerId": peerId!])
  }

  private func syncLocalBleIdentity(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    localBlePeerId = (args?["peerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? localBlePeerId
    localAdvertisingName = (args?["advertisingName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    localHostName = Host.current().localizedName ?? localHostName
    logBle(
      "syncLocalBleIdentity peerId=\(localBlePeerId) advertisingName=\(localAdvertisingName) hostName=\(localHostName)"
    )
    result(nil)
  }

  private func isLikelySelfPeripheral(peerId: String, friendlyName: String) -> Bool {
    if !localBlePeerId.isEmpty && peerId == localBlePeerId {
      return true
    }
    let peer = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
    if peer.isEmpty { return false }
    let candidates = [localAdvertisingName, localHostName, Host.current().localizedName ?? ""]
    for local in candidates {
      let trimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && peer.caseInsensitiveCompare(trimmed) == .orderedSame {
        return true
      }
    }
    return false
  }
}

// MARK: - FlutterStreamHandler

extension BleTransportPlugin: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    scanEventSink = events
    logBle("scan event stream listening")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    scanEventSink = nil
    logBle("scan event stream cancelled")
    return nil
  }
}

// MARK: - CBCentralManagerDelegate

extension BleTransportPlugin: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    logBle("central manager state=\(centralStateLabel(central.state))")
    if central.state == .poweredOn {
      if let pending = pendingStartScanResult {
        pendingStartScanResult = nil
        startScanning(result: pending)
      }
      return
    }
    if let pending = pendingStartScanResult {
      pendingStartScanResult = nil
      pending(
        FlutterError(
          code: "ble_unavailable",
          message: "Bluetooth is not powered on.",
          details: centralStateLabel(central.state)
        )
      )
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let peerId = peripheral.identifier.uuidString
    discoveredPeripherals[peerId] = peripheral
    let friendlyName =
      (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
      ?? peripheral.name
      ?? Host.current().localizedName
      ?? "Unknown Peer"
    if isLikelySelfPeripheral(peerId: peerId, friendlyName: friendlyName) {
      logBle(
        "ignored self peripheral id=\(peerId) name=\(friendlyName) "
          + "(local_peer_id=\(localBlePeerId) local_name=\(localAdvertisingName))"
      )
      return
    }
    logBle(
      "discovered peripheral id=\(peerId) name=\(friendlyName) rssi=\(RSSI) "
        + "services=\((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? [])"
    )
    discoveredPeers[peerId] = [
      "id": peerId,
      "friendlyName": friendlyName,
      "serviceUuid": Self.serviceUuid.uuidString,
    ]
    emitScanPeers()
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral === activeGuestPeripheral else { return }
    logBle("ClientHello: connected peer=\(peripheral.identifier.uuidString), discovering services")
    peripheral.discoverServices([Self.serviceUuid])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard peripheral === activeGuestPeripheral, !handshakeDelivered else { return }
    failHandshake(
      code: "handshake_connect_failed",
      message: error?.localizedDescription ?? "Failed to connect.",
      peripheral: peripheral
    )
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    guard peripheral === activeGuestPeripheral, !handshakeDelivered, handshakeDeliveryResult != nil else {
      return
    }
    failHandshake(
      code: "handshake_disconnect",
      message: "Disconnected during handshake.",
      peripheral: peripheral,
      details: error?.localizedDescription
    )
  }
}

// MARK: - CBPeripheralDelegate (guest central)

extension BleTransportPlugin: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral === activeGuestPeripheral else { return }
    if let error {
      failHandshake(
        code: "service_discovery_failed",
        message: error.localizedDescription,
        peripheral: peripheral
      )
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUuid }) else {
      failHandshake(
        code: "service_discovery_failed",
        message: "Handshake service missing.",
        peripheral: peripheral
      )
      return
    }
    logBle("ClientHello: service discovered uuid=\(service.uuid.uuidString)")
    peripheral.discoverCharacteristics(
      [Self.handshakeCharacteristicUuid, Self.endpointCharacteristicUuid],
      for: service
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard peripheral === activeGuestPeripheral else { return }
    if let error {
      failHandshake(
        code: "characteristic_missing",
        message: error.localizedDescription,
        peripheral: peripheral
      )
      return
    }

    guard let handshakeChar = service.characteristics?.first(where: {
      $0.uuid == Self.handshakeCharacteristicUuid
    }) else {
      failHandshake(
        code: "characteristic_missing",
        message: "Handshake characteristic missing.",
        peripheral: peripheral
      )
      return
    }

    guestHandshakeCharacteristic = handshakeChar
    if let helloData = pendingGuestClientHelloData, !helloData.isEmpty {
      pendingGuestClientHelloData = nil
      logBle("ClientHello: writing \(helloData.count) bytes before ServerHello read")
      peripheral.writeValue(helloData, for: handshakeChar, type: .withResponse)
    } else {
      beginGuestHandshakeNotify(peripheral: peripheral, handshakeChar: handshakeChar)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard peripheral === activeGuestPeripheral,
          characteristic.uuid == Self.handshakeCharacteristicUuid
    else { return }
    if let error {
      logBle("ClientHello write failed: \(error.localizedDescription); continuing")
    } else {
      logBle("ClientHello write succeeded")
    }
    beginGuestHandshakeNotify(peripheral: peripheral, handshakeChar: characteristic)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard peripheral === activeGuestPeripheral,
          characteristic.uuid == Self.handshakeCharacteristicUuid
    else { return }

    if let error {
      failHandshake(
        code: "handshake_failed",
        message: error.localizedDescription,
        peripheral: peripheral
      )
      return
    }

    guard let data = characteristic.value, !data.isEmpty else { return }
    deliverGuestHandshake(data, source: "read/notify")
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard peripheral === activeGuestPeripheral,
          characteristic.uuid == Self.handshakeCharacteristicUuid
    else { return }

    if let error {
      failHandshake(
        code: "handshake_notify_failed",
        message: error.localizedDescription,
        peripheral: peripheral
      )
      return
    }

    if characteristic.isNotifying {
      logBle("subscribe success: handshake notifications enabled")
      peripheral.readValue(for: characteristic)
    } else {
      logBle("handshake notifications disabled (isNotifying=false)")
    }
  }
}
