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
  private var handshakeInfrastructurePayload = Data()
  private var hostSessionPublicKey = ""
  /// guest_public_key → host_public_key after Approve.
  private var approvedPeerHostKeys: [String: String] = [:]
  private var guestPublicKeyByCentralId: [String: String] = [:]
  private var centralIdByGuestPublicKey: [String: String] = [:]
  private var pendingApprovalSessionKeys = Set<String>()
  private var advertisedEndpoint = ""
  private var pendingLanIp = ""
  private var pendingP2pIp = ""
  private var pendingP2pMac = ""
  private var pendingHotspotSsid = ""
  private var pendingHotspotPass = ""
  private var pendingHotspotHubIp = ""
  private var pendingHubIp: String?
  private var pendingHubPort = 8080
  private var pendingTlsCertSha256 = ""
  private var hotspotActive = false
  private var pendingApprovalCentralId: String?
  private var approvalTimeoutWorkItem: DispatchWorkItem?
  private var subscribedCentrals: [String: CBCentral] = [:]

  // Guest handshake state
  private var activeGuestPeripheral: CBPeripheral?
  private var handshakeDeliveryResult: FlutterResult?
  private var handshakeDelivered = false
  private var handshakeWaitWorkItem: DispatchWorkItem?
  private var guestHandshakeCharacteristic: CBCharacteristic?
  private var guestPublicKeyWritePending = false
  private var pendingGuestPublicKey = ""

  private var pendingStartScanResult: FlutterResult?
  private var pendingAdvertiseResult: FlutterResult?
  private var pendingAdvertiseFriendlyName: String?
  private var gattServicePublished = false
  private var pendingGattAdvertiseLabel: String?

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

  private func logBle(_ message: String) {
    NSLog("AirShareBLE: %@", message)
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
    case "resetHostHandshakeState":
      resetHostHandshakeState(result: result)
    case "resetGuestHandshakeState":
      resetGuestHandshakeState(result: result)
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
    performGuestHandshakeReset()
    if isScanning {
      centralManager.stopScan()
      isScanning = false
    }
    result(nil)
  }

  private func resetHostHandshakeState(result: @escaping FlutterResult) {
    approvedPeerHostKeys.removeAll()
    guestPublicKeyByCentralId.removeAll()
    centralIdByGuestPublicKey.removeAll()
    pendingApprovalSessionKeys.removeAll()
    subscribedCentrals.removeAll()
    clearPendingApproval()
    cancelApprovalTimeout()
    logBle("Host handshake state reset")
    result(nil)
  }

  private func resetGuestHandshakeState(result: @escaping FlutterResult) {
    performGuestHandshakeReset()
    result(nil)
  }

  private func performGuestHandshakeReset() {
    cancelHandshakeWait()
    if let delivery = handshakeDeliveryResult {
      delivery(
        FlutterError(
          code: "handshake_reset",
          message: "Guest BLE handshake reset during teardown",
          details: nil
        )
      )
    }
    handshakeDeliveryResult = nil
    handshakeDelivered = false
    guestHandshakeCharacteristic = nil
    if let peripheral = activeGuestPeripheral {
      centralManager.cancelPeripheralConnection(peripheral)
      activeGuestPeripheral = nil
    }
    logBle("Guest handshake state reset")
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
    if isAdvertising && gattServicePublished {
      logBle("startHubAdvertising: already advertising with GATT published")
      result(nil)
      return
    }

    if let hubIp = pendingHubIp, !hubIp.isEmpty {
      advertisedEndpoint = "\(hubIp):\(pendingHubPort)"
    }
    hotspotActive = false
    refreshHostHandshakePayloadCache()

    pendingAdvertiseResult = result
    pendingGattAdvertiseLabel = label
    publishHostGattService()
  }

  /// Builds handshake + endpoint characteristics and adds the primary service (Android parity).
  private func publishHostGattService() {
    logBle(
      "publishHostGattService: service=\(Self.serviceUuid.uuidString) " +
        "handshake=\(Self.handshakeCharacteristicUuid.uuidString) " +
        "endpoint=\(Self.endpointCharacteristicUuid.uuidString)"
    )

    // Do not attach a manual CCCD (00002902): CoreBluetooth manages notify subscriptions on iOS
    // peripheral mode via didSubscribeTo. A manual CBMutableDescriptor with value: nil crashes at add().
    let handshakeChar = CBMutableCharacteristic(
      type: Self.handshakeCharacteristicUuid,
      properties: [.read, .notify, .write],
      value: nil,
      permissions: [.readable, .writeable]
    )
    logBle("added handshake characteristic (read+notify, value=nil, no manual CCCD)")

    // Match Android: endpoint is read+write with no cached value (served in didReceiveRead).
    let endpointChar = CBMutableCharacteristic(
      type: Self.endpointCharacteristicUuid,
      properties: [.read, .write],
      value: nil,
      permissions: [.readable, .writeable]
    )
    logBle("added endpoint characteristic (read+write, value=nil)")

    let service = CBMutableService(type: Self.serviceUuid, primary: true)
    service.characteristics = [handshakeChar, endpointChar]

    handshakeCharacteristic = handshakeChar
    endpointCharacteristic = endpointChar
    gattServicePublished = false

    peripheralManager.stopAdvertising()
    isAdvertising = false
    peripheralManager.removeAllServices()
    peripheralManager.add(service)
    logBle("peripheralManager.add(service) requested — waiting for didAdd before advertise")
  }

  private func startBleAdvertisingIfReady() {
    guard peripheralManager.state == .poweredOn, gattServicePublished else { return }
    guard let label = pendingGattAdvertiseLabel else { return }
    let advertisement: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [Self.serviceUuid],
      CBAdvertisementDataLocalNameKey: String(label.prefix(10)),
    ]
    peripheralManager.startAdvertising(advertisement)
    isAdvertising = true
    logBle("BLE peripheral advertising started localName=\(String(label.prefix(10)))")
    if let pending = pendingAdvertiseResult {
      pendingAdvertiseResult = nil
      pendingGattAdvertiseLabel = nil
      pending(nil)
    }
  }

  private func stopHubAdvertising(result: @escaping FlutterResult) {
    logBle("stopHubAdvertising")
    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()
    isAdvertising = false
    gattServicePublished = false
    handshakeCharacteristic = nil
    endpointCharacteristic = nil
    approvedPeerHostKeys.removeAll()
    guestPublicKeyByCentralId.removeAll()
    centralIdByGuestPublicKey.removeAll()
    pendingApprovalSessionKeys.removeAll()
    subscribedCentrals.removeAll()
    handshakeInfrastructurePayload = Data()
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
    let incomingHostPk = (args["hostPublicKey"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !incomingHostPk.isEmpty {
      hostSessionPublicKey = incomingHostPk
    }
    pendingTlsCertSha256 = (args["tlsCertSha256"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // iOS same-Wi-Fi sender: never host offline hotspot.
    hotspotActive = false
    pendingHotspotSsid = ""
    pendingHotspotPass = ""
    pendingHotspotHubIp = ""
    refreshHostHandshakePayloadCache()
    result(nil)
  }

  private func approveConnection(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let approved = args?["approved"] as? Bool ?? false
    let sessionKeyArg = (
      (args?["sessionKey"] as? String) ?? (args?["peerId"] as? String)
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hostPkArg = (args?["hostPublicKey"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !hostPkArg.isEmpty {
      hostSessionPublicKey = hostPkArg
    }
    let sessionKey = sessionKeyArg.isEmpty
      ? (pendingApprovalCentralId.flatMap { guestPublicKeyByCentralId[$0] } ?? "")
      : sessionKeyArg

    if !approved {
      if !sessionKey.isEmpty {
        approvedPeerHostKeys.removeValue(forKey: sessionKey)
        pendingApprovalSessionKeys.remove(sessionKey)
      }
      clearPendingApproval()
      result(nil)
      return
    }

    if sessionKey.isEmpty {
      result(FlutterError(code: "invalid_peer", message: "sessionKey (guest public key) is required for approval.", details: nil))
      return
    }
    if hostSessionPublicKey.isEmpty {
      result(FlutterError(code: "handshake_not_ready", message: "Host session public key is not available.", details: nil))
      return
    }

    approvedPeerHostKeys[sessionKey] = hostSessionPublicKey
    pendingApprovalSessionKeys.remove(sessionKey)

    guard let payload = buildHandshakePayloadForSession(sessionKey: sessionKey) else {
      result(
        FlutterError(
          code: "handshake_not_ready",
          message: "WLAN credentials are not available yet.",
          details: nil
        )
      )
      return
    }

    if let json = String(data: payload, encoding: .utf8) {
      logBle("approveConnection: session=\(sessionKey) JSON \(json)")
    }
    broadcastHandshakeNotifications()
    clearPendingApproval()
    result(nil)
  }

  // MARK: - Guest handshake

  private func establishSecureHandshake(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let peerId = (args["peerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !peerId.isEmpty,
          let guestPublicKey = (args["guestPublicKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !guestPublicKey.isEmpty,
          let peripheral = discoveredPeripherals[peerId]
    else {
      result(FlutterError(code: "peer_not_found", message: "Unable to resolve peer device.", details: nil))
      return
    }

    cancelHandshakeWait()
    handshakeDelivered = false
    handshakeDeliveryResult = result
    guestHandshakeCharacteristic = nil
    pendingGuestPublicKey = guestPublicKey
    guestPublicKeyWritePending = true

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

  private func refreshHostHandshakePayloadCache() {
    if let data = buildHandshakeInfrastructurePayloadData() {
      handshakeInfrastructurePayload = data
      handshakeCharacteristic?.value = data
      if let json = String(data: data, encoding: .utf8) {
        logBle("handshake infrastructure cached: \(json)")
      }
    } else {
      handshakeInfrastructurePayload = Data()
      handshakeCharacteristic?.value = nil
      logBle("handshake JSON cache cleared (endpoints not ready)")
    }
  }

  private func handshakeSessionIsReleased(_ data: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    return handshakeSessionIsReleased(json)
  }

  private func normalizeSessionKey(_ guestPk: String) -> String {
    guestPk.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func parseGuestPublicKey(from data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let pk = (json["guest_public_key"] as? String)?
         .trimmingCharacters(in: .whitespacesAndNewlines),
       !pk.isEmpty {
      return pk
    }
    if let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.contains("{"), text.count >= 32 {
      return text
    }
    return nil
  }

  private func registerGuestSession(centralId: String, guestPk: String) {
    let sessionKey = normalizeSessionKey(guestPk)
    guard !sessionKey.isEmpty, !centralId.isEmpty else { return }
    guestPublicKeyByCentralId[centralId] = sessionKey
    centralIdByGuestPublicKey[sessionKey] = centralId
  }

  private func promptHandshakeApprovalIfNeeded(centralId: String, friendlyName: String) {
    guard let sessionKey = guestPublicKeyByCentralId[centralId] else { return }
    if approvedPeerHostKeys[sessionKey] != nil { return }
    if pendingApprovalSessionKeys.contains(sessionKey) { return }
    pendingApprovalSessionKeys.insert(sessionKey)
    pendingApprovalCentralId = centralId
    scheduleApprovalTimeout()
    notifyConnectionRequest(sessionKey: sessionKey, centralId: centralId, friendlyName: friendlyName)
    logBle("handshake approval prompted session=\(sessionKey) central=\(centralId)")
  }

  private func buildHandshakePayloadForCentral(centralId: String) -> Data? {
    guard let sessionKey = guestPublicKeyByCentralId[centralId] else {
      return buildHandshakeInfrastructurePayloadData()
    }
    return buildHandshakePayloadForSession(sessionKey: sessionKey)
  }

  /// Notifies every central that subscribed to the handshake characteristic (CCCD).
  private func broadcastHandshakeNotifications() {
    guard let char = handshakeCharacteristic else {
      logBle("broadcastHandshakeNotifications: handshake characteristic missing")
      return
    }
    let centrals = Array(subscribedCentrals.values)
    if centrals.isEmpty {
      logBle("broadcastHandshakeNotifications: no active CCCD subscribers")
      return
    }
    logBle("broadcastHandshakeNotifications: \(centrals.count) subscriber(s)")
    for central in centrals {
      let centralId = central.identifier.uuidString
      guard let payload = buildHandshakePayloadForCentral(centralId: centralId),
            !payload.isEmpty
      else { continue }
      handshakeCharacteristic?.value = payload
      let notified = peripheralManager.updateValue(
        payload,
        for: char,
        onSubscribedCentrals: [central]
      )
      let sessionKey = guestPublicKeyByCentralId[centralId] ?? "(unmapped)"
      logBle(
        "notify central=\(centralId) session=\(sessionKey) notified=\(notified) bytes=\(payload.count)"
      )
    }
  }

  private func buildHandshakePayloadForSession(sessionKey: String) -> Data? {
    guard var json = buildHandshakeInfrastructurePayloadData(),
          var dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    else { return nil }
    if let hostPk = approvedPeerHostKeys[sessionKey], !hostPk.isEmpty {
      dict["host_public_key"] = hostPk
      json = (try? JSONSerialization.data(withJSONObject: dict)) ?? json
    }
    return json
  }

  private static let iosHotspotGateway = "172.20.10.1"

  private func isLikelyCarrierWanIp(_ ip: String) -> Bool {
    let t = ip.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false }
    if t == Self.iosHotspotGateway { return false }
    return t.hasPrefix("10.") || t.hasPrefix("100.")
  }

  private func sanitizeHotspotBleIps(lan: String, hotspotHub: String, hotspotActive: Bool) -> (String, String) {
    guard hotspotActive else { return (lan, hotspotHub) }
    let gateway = Self.iosHotspotGateway
    var outLan = lan.trimmingCharacters(in: .whitespacesAndNewlines)
    var outHub = hotspotHub.trimmingCharacters(in: .whitespacesAndNewlines)
    outHub = gateway
    if outLan.isEmpty || isLikelyCarrierWanIp(outLan) {
      outLan = gateway
    }
    return (outLan, outHub)
  }

  private func buildHandshakeInfrastructurePayloadData() -> Data? {
    let ssid = hotspotActive ? pendingHotspotSsid : ""
    let password = hotspotActive ? pendingHotspotPass : ""
    let (lan, hotspotHub) = sanitizeHotspotBleIps(
      lan: pendingLanIp,
      hotspotHub: hotspotActive ? pendingHotspotHubIp : "",
      hotspotActive: hotspotActive && !ssid.isEmpty
    )
    let p2p = pendingP2pIp
    let p2pMac = pendingP2pMac
    if lan.isEmpty && p2p.isEmpty && ssid.isEmpty {
      return nil
    }
    var json: [String: Any] = [
      "hub_port": pendingHubPort,
      "platform": "ios",
      "host_platform": "ios",
      "hasHotspot": false,
    ]
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
    if !pendingTlsCertSha256.isEmpty { json["tls_cert_sha256"] = pendingTlsCertSha256 }
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
      "host_public_key": (json["host_public_key"] as? String) ?? "",
      "tls_cert_sha256": (json["tls_cert_sha256"] as? String) ?? "",
    ]
  }

  private func handshakeSessionIsReleased(_ json: [String: Any]) -> Bool {
    ((json["host_public_key"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty == false)
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
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }
    if !handshakePayloadIsReady(json) { return }
    if !handshakeSessionIsReleased(json) {
      logBle("Handshake infrastructure (\(source)); awaiting Approve for session keys")
      return
    }
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
      self.handshakeInfrastructurePayload = Data()
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

  private func notifyConnectionRequest(sessionKey: String, centralId: String, friendlyName: String) {
    DispatchQueue.main.async { [weak self] in
      self?.uiChannel.invokeMethod(
        "notifyConnectionRequest",
        arguments: [
          "friendlyName": friendlyName,
          "sessionKey": sessionKey,
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
    let guestPkPayload: [String: Any] = ["guest_public_key": pendingGuestPublicKey]
    guard let data = try? JSONSerialization.data(withJSONObject: guestPkPayload) else {
      handshakeDeliveryResult?(
        FlutterError(code: "guest_key_write_failed", message: "Unable to encode guest_public_key.", details: nil)
      )
      handshakeDeliveryResult = nil
      cancelHandshakeWait()
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    guestPublicKeyWritePending = true
    peripheral.writeValue(data, for: handshakeChar, type: .withResponse)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard peripheral === activeGuestPeripheral,
          characteristic.uuid == Self.handshakeCharacteristicUuid,
          guestPublicKeyWritePending
    else { return }
    guestPublicKeyWritePending = false
    if let error {
      handshakeDeliveryResult?(
        FlutterError(code: "guest_key_write_failed", message: error.localizedDescription, details: nil)
      )
      handshakeDeliveryResult = nil
      cancelHandshakeWait()
      centralManager.cancelPeripheralConnection(peripheral)
      return
    }
    guard let handshakeChar = guestHandshakeCharacteristic else { return }
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
    logBle("peripheralManagerDidUpdateState=\(peripheral.state.rawValue)")
    guard peripheral.state == .poweredOn else { return }
    if let pending = pendingAdvertiseResult, let name = pendingAdvertiseFriendlyName {
      pendingAdvertiseFriendlyName = nil
      startHubAdvertising(
        call: FlutterMethodCall(methodName: "startHubAdvertising", arguments: ["friendlyName": name]),
        result: pending
      )
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error {
      gattServicePublished = false
      logBle("didAdd service FAILED: \(error.localizedDescription)")
      if let pending = pendingAdvertiseResult {
        pendingAdvertiseResult = nil
        pendingGattAdvertiseLabel = nil
        pending(
          FlutterError(
            code: "gatt_service_add_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
      return
    }
    gattServicePublished = true
    let charUuids = (service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
    logBle("didAdd service OK uuid=\(service.uuid.uuidString) characteristics=[\(charUuids)]")
    startBleAdvertisingIfReady()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    logBle(
      "central subscribed uuid=\(characteristic.uuid.uuidString) central=\(central.identifier.uuidString)"
    )
    if characteristic.uuid == Self.handshakeCharacteristicUuid {
      subscribedCentrals[central.identifier.uuidString] = central
      logBle(
        "handshake CCCD subscribe central=\(central.identifier.uuidString) " +
          "subscribers=\(subscribedCentrals.count)"
      )
      broadcastHandshakeNotifications()
      let centralId = central.identifier.uuidString
      if let payload = buildHandshakePayloadForCentral(centralId: centralId),
         !handshakeSessionIsReleased(payload) {
        promptHandshakeApprovalIfNeeded(
          centralId: centralId,
          friendlyName: "Unknown Peer"
        )
      }
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    if characteristic.uuid == Self.handshakeCharacteristicUuid {
      subscribedCentrals.removeValue(forKey: central.identifier.uuidString)
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    let charUuid = request.characteristic.uuid.uuidString
    logBle("didReceiveRead uuid=\(charUuid) central=\(request.central.identifier.uuidString)")

    if request.characteristic.uuid == Self.endpointCharacteristicUuid {
      let bytes = advertisedEndpoint.data(using: .utf8) ?? Data()
      request.value = bytes
      peripheral.respond(to: request, withResult: .success)
      logBle("endpoint read response: \(advertisedEndpoint)")
      return
    }

    guard request.characteristic.uuid == Self.handshakeCharacteristicUuid else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }

    let centralId = request.central.identifier.uuidString
    if let payload = buildHandshakePayloadForCentral(centralId: centralId), !payload.isEmpty {
      request.value = payload
      peripheral.respond(to: request, withResult: .success)
      if let json = String(data: payload, encoding: .utf8) {
        logBle("handshake read response (per-peer): \(json)")
      }
      if !handshakeSessionIsReleased(payload) {
        promptHandshakeApprovalIfNeeded(
          centralId: centralId,
          friendlyName: "Unknown Peer"
        )
      }
      return
    }

    if pendingApprovalCentralId == nil {
      pendingApprovalCentralId = request.central.identifier.uuidString
      scheduleApprovalTimeout()
      let centralId = request.central.identifier.uuidString
      if let sessionKey = guestPublicKeyByCentralId[centralId] {
        notifyConnectionRequest(
          sessionKey: sessionKey,
          centralId: centralId,
          friendlyName: "Unknown Peer"
        )
      }
      logBle("handshake read empty — awaiting host UI approval")
    }

    request.value = Data()
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      logBle("didReceiveWrite uuid=\(request.characteristic.uuid.uuidString)")
      if request.characteristic.uuid == Self.handshakeCharacteristicUuid {
        let centralId = request.central.identifier.uuidString
        if let data = request.value, let guestPk = parseGuestPublicKey(from: data) {
          registerGuestSession(centralId: centralId, guestPk: guestPk)
          logBle("guest_public_key registered central=\(centralId)")
          promptHandshakeApprovalIfNeeded(
            centralId: centralId,
            friendlyName: "Unknown Peer"
          )
        }
        peripheral.respond(to: request, withResult: .success)
      } else if request.characteristic.uuid == Self.endpointCharacteristicUuid {
        peripheral.respond(to: request, withResult: .success)
      } else {
        peripheral.respond(to: request, withResult: .success)
      }
    }
  }
}
