import CoreBluetooth
import Flutter
import UIKit

/// iOS BLE transport — mirrors Android `air_share/ble_transport` + `air_share/ble_scan_events` + `air_share/ble_ui`.
final class BleTransportPlugin: NSObject {
  private static let methodChannelName = "air_share/ble_transport"
  private static let scanEventChannelName = "air_share/ble_scan_events"
  private static let uiChannelName = "air_share/ble_ui"

  private static let serviceUuid = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
  private static let handshakeCharacteristicUuid = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
  private static let endpointCharacteristicUuid = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
  private static let clientConfigDescriptorUuid = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")

  private let methodChannel: FlutterMethodChannel
  private let uiChannel: FlutterMethodChannel
  private let scanEventChannel: FlutterEventChannel

  private var centralManager: CBCentralManager!
  private var peripheralManager: CBPeripheralManager!

  private var scanEventSink: FlutterEventSink?
  private var isScanning = false
  private var isAdvertising = false
  private var discoveredPeers: [String: [String: String]] = [:]
  private var discoveredPeripherals: [String: CBPeripheral] = [:]

  // Host GATT state
  private var handshakeCharacteristic: CBMutableCharacteristic?
  private var endpointCharacteristic: CBMutableCharacteristic?
  private var handshakePayload = Data()
  private var advertisedEndpoint = ""
  private var pendingLanIp = ""
  private var pendingP2pIp = ""
  private var pendingP2pMac = ""
  private var pendingHotspotSsid = ""
  private var pendingHotspotPass = ""
  private var pendingHotspotHubIp = ""
  private var pendingHubIp: String?
  private var pendingHubPort = 8080
  private var hotspotActive = false
  private var pendingApprovalCentralId: String?
  private var approvalTimeoutWorkItem: DispatchWorkItem?

  // Guest handshake state
  private var activeGuestPeripheral: CBPeripheral?
  private var handshakeDeliveryResult: FlutterResult?
  private var handshakeDelivered = false
  private var handshakeWaitWorkItem: DispatchWorkItem?
  private var guestHandshakeCharacteristic: CBCharacteristic?

  private var pendingStartScanResult: FlutterResult?
  private var pendingAdvertiseResult: FlutterResult?
  private var pendingAdvertiseFriendlyName: String?

  private var pendingEndpointReadPeripheral: CBPeripheral?
  private var pendingEndpointReadResult: FlutterResult?
  private var endpointReadCompleted = false

  private static var retained: BleTransportPlugin?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
    uiChannel = FlutterMethodChannel(name: Self.uiChannelName, binaryMessenger: messenger)
    scanEventChannel = FlutterEventChannel(name: Self.scanEventChannelName, binaryMessenger: messenger)
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: nil)
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    methodChannel.setMethodCallHandler(handleMethodCall)
    scanEventChannel.setStreamHandler(self)
  }

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "BleTransportPlugin") else {
      return
    }
    retained = BleTransportPlugin(messenger: registrar.messenger())
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startScanning":
      startScanning(result: result)
    case "stopScanning":
      stopScanning(result: result)
    case "startHubAdvertising":
      startHubAdvertising(call: call, result: result)
    case "stopHubAdvertising":
      stopHubAdvertising(result: result)
    case "establishSecureHandshake":
      establishSecureHandshake(call: call, result: result)
    case "readPeerEndpoint":
      readPeerEndpoint(call: call, result: result)
    case "updateHubEndpoint":
      updateHubEndpoint(call: call, result: result)
    case "updateConnectionEndpoints":
      updateConnectionEndpoints(call: call, result: result)
    case "approveConnection":
      approveConnection(call: call, result: result)
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
    case "shareLogs":
      result(
        FlutterError(
          code: "unsupported",
          message: "Share logs is only supported on Android",
          details: nil
        )
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Scan

  private func startScanning(result: @escaping FlutterResult) {
    guard centralManager.state == .poweredOn else {
      if centralManager.state == .unknown || centralManager.state == .resetting {
        pendingStartScanResult = result
        return
      }
      result(
        FlutterError(
          code: "ble_unavailable",
          message: "Bluetooth is not powered on.",
          details: nil
        )
      )
      return
    }
    if isScanning {
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
    result(nil)
  }

  private func stopScanning(result: @escaping FlutterResult) {
    if isScanning {
      centralManager.stopScan()
      isScanning = false
    }
    result(nil)
  }

  private func emitScanPeers() {
    guard let sink = scanEventSink else { return }
    let peers = Array(discoveredPeers.values)
    sink(peers)
  }

  // MARK: - Host advertising / GATT server

  private func startHubAdvertising(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let friendlyName = (call.arguments as? [String: Any])?["friendlyName"] as? String
    let label = (friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? UIDevice.current.name

    guard peripheralManager.state == .poweredOn else {
      if peripheralManager.state == .unknown || peripheralManager.state == .resetting {
        pendingAdvertiseResult = result
        pendingAdvertiseFriendlyName = label
        return
      }
      result(
        FlutterError(
          code: "ble_unavailable",
          message: "Bluetooth peripheral manager is not powered on.",
          details: nil
        )
      )
      return
    }
    if isAdvertising {
      result(nil)
      return
    }

    if let hubIp = pendingHubIp, !hubIp.isEmpty {
      advertisedEndpoint = "\(hubIp):\(pendingHubPort)"
    }
    handshakePayload = Data()
    hotspotActive = false

    let handshakeChar = CBMutableCharacteristic(
      type: Self.handshakeCharacteristicUuid,
      properties: [.read, .notify],
      value: nil,
      permissions: [.readable]
    )
    // Cached values require read-only properties; serve endpoint bytes in didReceiveRead.
    let endpointChar = CBMutableCharacteristic(
      type: Self.endpointCharacteristicUuid,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )
    let cccd = CBMutableDescriptor(
      type: Self.clientConfigDescriptorUuid,
      value: Data()
    )
    handshakeChar.descriptors = [cccd]

    let service = CBMutableService(type: Self.serviceUuid, primary: true)
    service.characteristics = [handshakeChar, endpointChar]

    handshakeCharacteristic = handshakeChar
    endpointCharacteristic = endpointChar

    peripheralManager.removeAllServices()
    peripheralManager.add(service)

    var advertisement: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [Self.serviceUuid],
      CBAdvertisementDataLocalNameKey: String(label.prefix(10)),
    ]
    peripheralManager.startAdvertising(advertisement)
    isAdvertising = true
    result(nil)
  }

  private func stopHubAdvertising(result: @escaping FlutterResult) {
    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()
    isAdvertising = false
    handshakeCharacteristic = nil
    endpointCharacteristic = nil
    handshakePayload = Data()
    clearPendingApproval()
    result(nil)
  }

  private func updateHubEndpoint(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let ip = (args["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !ip.isEmpty
    else {
      result(FlutterError(code: "invalid_endpoint", message: "ip is required", details: nil))
      return
    }
    let port = args["port"] as? Int ?? 8080
    pendingHubIp = ip
    pendingHubPort = port
    advertisedEndpoint = "\(ip):\(port)"
    result(nil)
  }

  private func updateConnectionEndpoints(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(nil)
      return
    }
    pendingLanIp = (args["lanIp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pendingP2pIp = (args["p2pIp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pendingP2pMac = (args["p2pMac"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pendingHotspotSsid = (args["hotspotSsid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pendingHotspotPass = (args["hotspotPass"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pendingHotspotHubIp = (args["hotspotHubIp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pendingHubPort = args["hubPort"] as? Int ?? 8080
    hotspotActive = !pendingHotspotSsid.isEmpty && !pendingHotspotPass.isEmpty
    if hotspotActive, pendingHotspotHubIp.isEmpty, let hub = pendingHubIp {
      pendingHotspotHubIp = hub
    }
    result(nil)
  }

  private func approveConnection(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let approved = (call.arguments as? [String: Any])?["approved"] as? Bool ?? false
    if !approved {
      handshakePayload = Data()
      handshakeCharacteristic?.value = nil
      clearPendingApproval()
      result(nil)
      return
    }

    guard let payload = buildHandshakePayloadData() else {
      result(
        FlutterError(
          code: "handshake_not_ready",
          message: "WLAN credentials are not available yet.",
          details: nil
        )
      )
      return
    }

    handshakePayload = payload
    handshakeCharacteristic?.value = payload
    if let char = handshakeCharacteristic {
      _ = peripheralManager.updateValue(payload, for: char, onSubscribedCentrals: nil)
    }
    clearPendingApproval()
    result(nil)
  }

  // MARK: - Guest handshake

  private func establishSecureHandshake(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let peerId = (args["peerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !peerId.isEmpty,
          let peripheral = discoveredPeripherals[peerId]
    else {
      result(FlutterError(code: "peer_not_found", message: "Unable to resolve peer device.", details: nil))
      return
    }

    cancelHandshakeWait()
    handshakeDelivered = false
    handshakeDeliveryResult = result
    guestHandshakeCharacteristic = nil

    if let active = activeGuestPeripheral, active != peripheral {
      centralManager.cancelPeripheralConnection(active)
    }
    activeGuestPeripheral = peripheral
    peripheral.delegate = self
    centralManager.connect(peripheral, options: nil)
    scheduleHandshakeWait(for: peripheral)
  }

  private func readPeerEndpoint(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let peerId = (args["peerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !peerId.isEmpty,
          let peripheral = discoveredPeripherals[peerId]
    else {
      result(FlutterError(code: "peer_not_found", message: "Unable to resolve peer device.", details: nil))
      return
    }

    endpointReadCompleted = false
    pendingEndpointReadPeripheral = peripheral
    pendingEndpointReadResult = result
    peripheral.delegate = self
    centralManager.connect(peripheral, options: nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self, !self.endpointReadCompleted else { return }
      self.endpointReadCompleted = true
      self.pendingEndpointReadResult?(
        FlutterError(code: "endpoint_read_timeout", message: "Timed out reading peer endpoint.", details: nil)
      )
      if let peripheral = self.pendingEndpointReadPeripheral {
        self.centralManager.cancelPeripheralConnection(peripheral)
      }
      self.pendingEndpointReadPeripheral = nil
      self.pendingEndpointReadResult = nil
    }
  }

  private func completeEndpointRead(_ value: [String: Any]?) {
    guard !endpointReadCompleted else { return }
    endpointReadCompleted = true
    if let value {
      pendingEndpointReadResult?(value)
    } else {
      pendingEndpointReadResult?(
        FlutterError(code: "endpoint_read_failed", message: "Failed to read endpoint.", details: nil)
      )
    }
    if let peripheral = pendingEndpointReadPeripheral {
      centralManager.cancelPeripheralConnection(peripheral)
    }
    pendingEndpointReadPeripheral = nil
    pendingEndpointReadResult = nil
  }

  private func openBluetoothSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(nil)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      result(nil)
    }
  }

  private func getLocalPeerId(result: @escaping FlutterResult) {
    let key = "air_share_ios_ble_peer_id"
    let defaults = UserDefaults.standard
    var peerId = defaults.string(forKey: key)
    if peerId == nil || peerId!.isEmpty {
      peerId = UUID().uuidString
      defaults.set(peerId, forKey: key)
    }
    result(["peerId": peerId!])
  }

  // MARK: - Handshake helpers

  private func buildHandshakePayloadData() -> Data? {
    let lan = pendingLanIp
    let p2p = pendingP2pIp
    let ssid = hotspotActive ? pendingHotspotSsid : ""
    let password = hotspotActive ? pendingHotspotPass : ""
    let p2pMac = pendingP2pMac
    let hotspotHub = hotspotActive ? pendingHotspotHubIp : ""
    if lan.isEmpty && p2p.isEmpty && ssid.isEmpty {
      return nil
    }
    var json: [String: Any] = ["hub_port": pendingHubPort]
    if !lan.isEmpty { json["lan_ip"] = lan }
    if !p2p.isEmpty { json["p2p_ip"] = p2p }
    if !p2pMac.isEmpty { json["p2p_mac"] = p2pMac }
    if !ssid.isEmpty {
      json["hotspot_ssid"] = ssid
      json["hotspot_pass"] = password
      json["ssid"] = ssid
      json["password"] = password
    }
    if !hotspotHub.isEmpty { json["hotspot_hub_ip"] = hotspotHub }
    let primaryLegacy: String
    if !lan.isEmpty {
      primaryLegacy = lan
    } else if !p2p.isEmpty {
      primaryLegacy = p2p
    } else if !hotspotHub.isEmpty {
      primaryLegacy = hotspotHub
    } else {
      primaryLegacy = pendingHubIp ?? ""
    }
    if !primaryLegacy.isEmpty {
      json["hubIp"] = primaryLegacy
      json["hubPort"] = pendingHubPort
    }
    if !p2pMac.isEmpty { json["p2pMac"] = p2pMac }
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
    return data
  }

  private func parseHandshakeMap(_ data: Data) -> [String: Any]? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if !handshakePayloadIsReady(json) { return nil }
    let port = json["hub_port"] as? Int ?? json["hubPort"] as? Int ?? 8080
    return [
      "lan_ip": (json["lan_ip"] as? String) ?? (json["hubIp"] as? String) ?? "",
      "p2p_ip": json["p2p_ip"] as? String ?? "",
      "p2p_mac": (json["p2p_mac"] as? String) ?? (json["p2pMac"] as? String) ?? "",
      "hotspot_ssid": (json["hotspot_ssid"] as? String) ?? (json["ssid"] as? String) ?? "",
      "hotspot_pass": (json["hotspot_pass"] as? String) ?? (json["password"] as? String) ?? "",
      "hotspot_hub_ip": json["hotspot_hub_ip"] as? String ?? "",
      "hub_port": port,
    ]
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
    guard let result = handshakeDeliveryResult else { return }
    handshakeDeliveryResult = nil
    if let peripheral = activeGuestPeripheral {
      centralManager.cancelPeripheralConnection(peripheral)
      activeGuestPeripheral = nil
    }
    result(map)
  }

  private func scheduleHandshakeWait(for peripheral: CBPeripheral) {
    cancelHandshakeWait()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.handshakeDelivered else { return }
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
    }
    handshakeWaitWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
  }

  private func cancelHandshakeWait() {
    handshakeWaitWorkItem?.cancel()
    handshakeWaitWorkItem = nil
  }

  private func scheduleApprovalTimeout() {
    cancelApprovalTimeout()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.handshakePayload = Data()
      self.handshakeCharacteristic?.value = nil
      self.clearPendingApproval()
    }
    approvalTimeoutWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
  }

  private func cancelApprovalTimeout() {
    approvalTimeoutWorkItem?.cancel()
    approvalTimeoutWorkItem = nil
  }

  private func clearPendingApproval() {
    pendingApprovalCentralId = nil
    cancelApprovalTimeout()
  }

  private func notifyConnectionRequest(centralId: String, friendlyName: String) {
    DispatchQueue.main.async { [weak self] in
      self?.uiChannel.invokeMethod(
        "notifyConnectionRequest",
        arguments: [
          "friendlyName": friendlyName,
          "deviceAddress": centralId,
        ]
      )
    }
  }
}

// MARK: - FlutterStreamHandler

extension BleTransportPlugin: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    scanEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    scanEventSink = nil
    return nil
  }
}

// MARK: - CBCentralManagerDelegate

extension BleTransportPlugin: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
          details: nil
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
      ?? "Unknown Peer"
    discoveredPeers[peerId] = [
      "id": peerId,
      "friendlyName": friendlyName,
      "serviceUuid": Self.serviceUuid.uuidString,
    ]
    emitScanPeers()
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    if peripheral === pendingEndpointReadPeripheral {
      peripheral.discoverServices([Self.serviceUuid])
      return
    }
    if peripheral === activeGuestPeripheral {
      peripheral.discoverServices([Self.serviceUuid])
    }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if peripheral === activeGuestPeripheral, !handshakeDelivered {
      handshakeDeliveryResult?(
        FlutterError(
          code: "handshake_connect_failed",
          message: error?.localizedDescription ?? "Failed to connect.",
          details: nil
        )
      )
      handshakeDeliveryResult = nil
      cancelHandshakeWait()
      activeGuestPeripheral = nil
    }
    if peripheral === pendingEndpointReadPeripheral {
      completeEndpointRead(nil)
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    if peripheral === activeGuestPeripheral, !handshakeDelivered, handshakeDeliveryResult != nil {
      handshakeDeliveryResult?(
        FlutterError(
          code: "handshake_disconnect",
          message: "Disconnected during handshake.",
          details: nil
        )
      )
      handshakeDeliveryResult = nil
      cancelHandshakeWait()
      activeGuestPeripheral = nil
    }
  }
}

// MARK: - CBPeripheralDelegate (guest central)

extension BleTransportPlugin: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      if peripheral === activeGuestPeripheral {
        handshakeDeliveryResult?(
          FlutterError(code: "service_discovery_failed", message: error.localizedDescription, details: nil)
        )
        handshakeDeliveryResult = nil
        cancelHandshakeWait()
      } else if peripheral === pendingEndpointReadPeripheral {
        completeEndpointRead(nil)
      }
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUuid }) else {
      if peripheral === activeGuestPeripheral {
        handshakeDeliveryResult?(
          FlutterError(code: "service_discovery_failed", message: "Handshake service missing.", details: nil)
        )
        handshakeDeliveryResult = nil
      } else if peripheral === pendingEndpointReadPeripheral {
        completeEndpointRead(nil)
      }
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
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
    if let error {
      if peripheral === pendingEndpointReadPeripheral {
        completeEndpointRead(nil)
      } else if peripheral === activeGuestPeripheral {
        handshakeDeliveryResult?(
          FlutterError(code: "characteristic_missing", message: error.localizedDescription, details: nil)
        )
        handshakeDeliveryResult = nil
        cancelHandshakeWait()
      }
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }

    if peripheral === pendingEndpointReadPeripheral {
      guard let endpointChar = service.characteristics?.first(where: {
        $0.uuid == Self.endpointCharacteristicUuid
      }) else {
        completeEndpointRead(nil)
        return
      }
      peripheral.readValue(for: endpointChar)
      return
    }

    guard peripheral === activeGuestPeripheral,
          let handshakeChar = service.characteristics?.first(where: {
            $0.uuid == Self.handshakeCharacteristicUuid
          })
    else {
      handshakeDeliveryResult?(
        FlutterError(code: "characteristic_missing", message: "Handshake characteristic missing.", details: nil)
      )
      handshakeDeliveryResult = nil
      cancelHandshakeWait()
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }

    guestHandshakeCharacteristic = handshakeChar
    peripheral.setNotifyValue(true, for: handshakeChar)
    peripheral.readValue(for: handshakeChar)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      if peripheral === activeGuestPeripheral, characteristic.uuid == Self.handshakeCharacteristicUuid {
        handshakeDeliveryResult?(
          FlutterError(code: "handshake_failed", message: error.localizedDescription, details: nil)
        )
        handshakeDeliveryResult = nil
        cancelHandshakeWait()
      } else if peripheral === pendingEndpointReadPeripheral {
        completeEndpointRead(nil)
      }
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }

    guard let data = characteristic.value, !data.isEmpty else { return }

    if characteristic.uuid == Self.handshakeCharacteristicUuid, peripheral === activeGuestPeripheral {
      deliverGuestHandshake(data, source: "read/notify")
      return
    }

    if characteristic.uuid == Self.endpointCharacteristicUuid, peripheral === pendingEndpointReadPeripheral {
      guard let text = String(data: data, encoding: .utf8) else {
        completeEndpointRead(nil)
        return
      }
      let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
      let ip = parts.first ?? ""
      let port = parts.count > 1 ? Int(parts[1]) ?? 8080 : 8080
      completeEndpointRead(["ip": ip, "port": port])
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if peripheral === activeGuestPeripheral,
       characteristic.uuid == Self.handshakeCharacteristicUuid,
       characteristic.isNotifying {
      peripheral.readValue(for: characteristic)
    }
  }
}

// MARK: - CBPeripheralManagerDelegate (host)

extension BleTransportPlugin: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral.state == .poweredOn else { return }
    if let pending = pendingAdvertiseResult {
      let name = pendingAdvertiseFriendlyName
      pendingAdvertiseResult = nil
      pendingAdvertiseFriendlyName = nil
      if let name {
        startHubAdvertising(
          call: FlutterMethodCall(methodName: "startHubAdvertising", arguments: ["friendlyName": name]),
          result: pending
        )
      } else {
        pending(nil)
      }
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    if request.characteristic.uuid == Self.endpointCharacteristicUuid {
      request.value = advertisedEndpoint.data(using: .utf8)
      peripheral.respond(to: request, withResult: .success)
      return
    }

    guard request.characteristic.uuid == Self.handshakeCharacteristicUuid else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }

    if !handshakePayload.isEmpty {
      request.value = handshakePayload
      peripheral.respond(to: request, withResult: .success)
      return
    }

    if pendingApprovalCentralId == nil {
      pendingApprovalCentralId = request.central.identifier.uuidString
      scheduleApprovalTimeout()
      notifyConnectionRequest(
        centralId: request.central.identifier.uuidString,
        friendlyName: "Unknown Peer"
      )
    }

    request.value = Data()
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      if request.characteristic.uuid == Self.handshakeCharacteristicUuid {
        peripheral.respond(to: request, withResult: .writeNotPermitted)
      } else {
        peripheral.respond(to: request, withResult: .success)
      }
    }
  }
}
