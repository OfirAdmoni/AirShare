import AppKit
import CoreBluetooth
import FlutterMacOS

/// macOS BLE transport — guest central + host peripheral (LAN-only sender).
/// Channels: `air_share/ble_transport`, `air_share/ble_scan_events`, `air_share/ble_ui`.
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
  private var discoveredPeers: [String: [String: String]] = [:]
  private var discoveredPeripherals: [String: CBPeripheral] = [:]
  private var pendingStartScanResult: FlutterResult?

  private var localBlePeerId = ""
  private var localAdvertisingName = ""
  private var localHostName = Host.current().localizedName ?? ""

  // Host GATT state (LAN-only sender)
  private var isAdvertising = false
  private var gattServicePublished = false
  private var handshakeCharacteristic: CBMutableCharacteristic?
  private var endpointCharacteristic: CBMutableCharacteristic?
  /// Released to GATT only after Flutter [approveConnection]; until then reads stay empty.
  private var handshakePayload = Data()
  /// Built when endpoints update; not exposed over BLE until host approves.
  private var draftHandshakePayload = Data()
  private var advertisedEndpoint = ""
  private var pendingLanIp = ""
  private var pendingHubIp: String?
  private var pendingHubPort = 8080
  private var pendingFriendlyName = ""
  private var clientHelloByCentralId: [String: (peerId: String, displayName: String)] = [:]
  private var approvalUiEmittedCentrals = Set<String>()
  private var connectionAttemptIdByCentral: [String: String] = [:]
  private var pendingApprovalNotifyWorkItems: [String: DispatchWorkItem] = [:]
  private var pendingGuestClientHelloData: Data?
  private var pendingApprovalCentralId: String?
  private var approvalTimeoutWorkItem: DispatchWorkItem?
  private var pendingAdvertiseResult: FlutterResult?
  private var pendingAdvertiseFriendlyName: String?
  private var pendingGattAdvertiseLabel: String?

  // Guest handshake state
  private var activeGuestPeripheral: CBPeripheral?
  private var handshakeDeliveryResult: FlutterResult?
  private var handshakeDelivered = false
  private var handshakeWaitWorkItem: DispatchWorkItem?
  private var guestHandshakeCharacteristic: CBCharacteristic?

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
    logBle(
      "macOS BLE plugin registered (channels: \(Self.methodChannelName), "
        + "\(Self.scanEventChannelName), \(Self.uiChannelName))"
    )
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

  private func peripheralStateLabel(_ state: CBManagerState) -> String {
    centralStateLabel(state)
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
    default:
      logBle("missing/unsupported method: \(call.method)")
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Scan (guest)

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

  // MARK: - Host advertising / GATT server (LAN-only)

  private func startHubAdvertising(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let friendlyName = (call.arguments as? [String: Any])?["friendlyName"] as? String
    let label = (friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? Host.current().localizedName ?? "AirShare Mac"

    pendingFriendlyName = label
    logBle(
      "startHubAdvertising requested localName=\(label) "
        + "peripheralState=\(peripheralStateLabel(peripheralManager.state))"
    )

    guard peripheralManager.state == .poweredOn else {
      if peripheralManager.state == .unknown || peripheralManager.state == .resetting {
        pendingAdvertiseResult = result
        pendingAdvertiseFriendlyName = label
        logBle("startHubAdvertising deferred until peripheral manager is ready")
        return
      }
      result(
        FlutterError(
          code: "ble_unavailable",
          message: "Bluetooth peripheral manager is not powered on.",
          details: peripheralStateLabel(peripheralManager.state)
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
    } else if !pendingLanIp.isEmpty {
      advertisedEndpoint = "\(pendingLanIp):\(pendingHubPort)"
    }
    clearReleasedHandshakePayload(reason: "startHubAdvertising")
    refreshDraftHandshakePayload(reason: "startHubAdvertising")

    pendingAdvertiseResult = result
    pendingGattAdvertiseLabel = label
    publishHostGattService()
  }

  /// Builds handshake + endpoint characteristics and adds the primary service (iOS/Android parity).
  private func publishHostGattService() {
    logBle(
      "publishHostGattService: service=\(Self.serviceUuid.uuidString) "
        + "handshake=\(Self.handshakeCharacteristicUuid.uuidString) "
        + "endpoint=\(Self.endpointCharacteristicUuid.uuidString)"
    )

    // Do not attach a manual CCCD: CoreBluetooth manages notify subscriptions.
    let handshakeChar = CBMutableCharacteristic(
      type: Self.handshakeCharacteristicUuid,
      properties: [.read, .notify, .write],
      value: nil,
      permissions: [.readable, .writeable]
    )
    logBle("added handshake characteristic (read+notify+write, value=nil, no manual CCCD)")

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
    logBle("advertising started localName=\(String(label.prefix(10))) service=\(Self.serviceUuid.uuidString)")
    if let pending = pendingAdvertiseResult {
      pendingAdvertiseResult = nil
      pendingGattAdvertiseLabel = nil
      pending(nil)
    }
  }

  private func stopHubAdvertising(result: @escaping FlutterResult) {
    logBle("stopHubAdvertising / teardown begin")
    teardownHostGatt(reason: "stopHubAdvertising")
    logBle("teardown completed")
    result(nil)
  }

  private func teardownHostGatt(reason: String) {
    if peripheralManager.isAdvertising || isAdvertising {
      peripheralManager.stopAdvertising()
      logBle("advertising stopped (\(reason))")
    }
    peripheralManager.removeAllServices()
    isAdvertising = false
    gattServicePublished = false
    handshakeCharacteristic = nil
    endpointCharacteristic = nil
    pendingAdvertiseResult = nil
    pendingAdvertiseFriendlyName = nil
    pendingGattAdvertiseLabel = nil
    clearReleasedHandshakePayload(reason: reason)
    draftHandshakePayload = Data()
    clearPendingApproval()
    advertisedEndpoint = ""
    clientHelloByCentralId.removeAll()
    approvalUiEmittedCentrals.removeAll()
    connectionAttemptIdByCentral.removeAll()
    for (_, work) in pendingApprovalNotifyWorkItems { work.cancel() }
    pendingApprovalNotifyWorkItems.removeAll()
    pendingGuestClientHelloData = nil
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
    pendingLanIp = ip
    pendingHubPort = port
    advertisedEndpoint = "\(ip):\(port)"
    logBle("LAN endpoint updated via updateHubEndpoint lan_ip=\(pendingLanIp) hub_port=\(pendingHubPort)")
    refreshDraftHandshakePayload(reason: "updateHubEndpoint")
    clearReleasedHandshakePayload(reason: "updateHubEndpoint")
    result(nil)
  }

  private func updateConnectionEndpoints(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(nil)
      return
    }
    let lanFromDart = (args["lanIp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !lanFromDart.isEmpty {
      pendingLanIp = lanFromDart
      pendingHubIp = lanFromDart
    }
    // macOS host is LAN-only — ignore hotspot / P2P fields from Dart.
    pendingHubPort = args["hubPort"] as? Int ?? pendingHubPort
    if !pendingLanIp.isEmpty {
      advertisedEndpoint = "\(pendingLanIp):\(pendingHubPort)"
    }
    logBle(
      "LAN endpoint updated via updateConnectionEndpoints lan_ip=\(pendingLanIp) "
        + "hub_port=\(pendingHubPort) (hotspot/P2P ignored on macOS host)"
    )
    refreshDraftHandshakePayload(reason: "updateConnectionEndpoints")
    clearReleasedHandshakePayload(reason: "updateConnectionEndpoints")
    result(nil)
  }

  private func approveConnection(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let approved = args?["approved"] as? Bool ?? false
    if let lanOverride = (args?["lanIp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !lanOverride.isEmpty {
      pendingLanIp = lanOverride
      pendingHubIp = lanOverride
      advertisedEndpoint = "\(lanOverride):\(pendingHubPort)"
      refreshDraftHandshakePayload(reason: "approveConnection_lanOverride")
    }

    if !approved {
      logBle("approval denied — ServerHello remains sealed")
      clearReleasedHandshakePayload(reason: "approveConnection_declined")
      clearPendingApproval()
      result(nil)
      return
    }

    guard let payload = buildHandshakePayloadData() else {
      logBle("approval granted but handshake draft not ready (missing lan_ip)")
      result(
        FlutterError(
          code: "handshake_not_ready",
          message: "LAN endpoint is not available yet.",
          details: nil
        )
      )
      return
    }

    handshakePayload = payload
    draftHandshakePayload = payload
    if let json = String(data: payload, encoding: .utf8) {
      logBle("approval granted — ServerHello released \(json.prefix(220))")
    }
    if let char = handshakeCharacteristic {
      let notified = peripheralManager.updateValue(payload, for: char, onSubscribedCentrals: nil)
      logBle("ServerHello notify sent=\(notified) bytes=\(payload.count)")
    }
    clearPendingApproval()
    result(nil)
  }

  // MARK: - Host handshake helpers

  private func refreshDraftHandshakePayload(reason: String) {
    if let data = buildHandshakePayloadData() {
      draftHandshakePayload = data
      if let json = String(data: data, encoding: .utf8) {
        logBle("handshake draft prepared (\(reason)): \(json.prefix(180))")
      }
    } else {
      draftHandshakePayload = Data()
      logBle("handshake draft cleared (\(reason)) — LAN endpoint not ready")
    }
  }

  private func clearReleasedHandshakePayload(reason: String) {
    handshakePayload = Data()
    handshakeCharacteristic?.value = nil
    logBle("handshake released payload cleared (\(reason))")
  }

  private func buildHandshakePayloadData() -> Data? {
    var lan = pendingLanIp.trimmingCharacters(in: .whitespacesAndNewlines)
    if lan.isEmpty,
       let hubFallback = pendingHubIp?.trimmingCharacters(in: .whitespacesAndNewlines),
       !hubFallback.isEmpty {
      lan = hubFallback
    }
    if lan.isEmpty {
      return nil
    }
    var json: [String: Any] = [
      "lan_ip": lan,
      "hubIp": lan,
      "hub_port": pendingHubPort,
      "hubPort": pendingHubPort,
      "platform": "macos",
      "hasHotspot": false,
    ]
    let name = pendingFriendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty {
      json["friendly_name"] = name
    }
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
    return data
  }

  private func scheduleApprovalTimeout() {
    cancelApprovalTimeout()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.logBle("approval timeout — sealing ServerHello")
      self.clearReleasedHandshakePayload(reason: "approval_timeout")
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


  private func parseClientHello(_ data: Data) -> (peerId: String, displayName: String)? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["type"] as? String) == "client_hello"
    else { return nil }
    let displayName = (json["display_name"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !displayName.isEmpty else { return nil }
    let peerId = (json["peer_id"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (peerId: peerId, displayName: displayName)
  }

  private func cancelPendingApprovalNotify(centralId: String) {
    pendingApprovalNotifyWorkItems.removeValue(forKey: centralId)?.cancel()
  }

  private func emitConnectionRequestOnce(centralId: String, friendlyName: String, reason: String) {
    if approvalUiEmittedCentrals.contains(centralId) {
      logBle(
        "Approval | Duplicate approval suppressed | source=BLE reason=\(reason) "
          + "central=\(centralId) displayName=\(friendlyName)"
      )
      logBle(
        "Approval | Approved entry metadata updated without new UI event "
          + "central=\(centralId) displayName=\(friendlyName)"
      )
      return
    }
    approvalUiEmittedCentrals.insert(centralId)
    logBle(
      "Approval | Entry created | source=BLE central=\(centralId) "
        + "displayName=\(friendlyName) reason=\(reason)"
    )
    notifyConnectionRequest(centralId: centralId, friendlyName: friendlyName)
  }

  private func stableConnectionAttemptId(for centralId: String) -> String {
    if let existing = connectionAttemptIdByCentral[centralId], !existing.isEmpty {
      return existing
    }
    let attemptId = "ble-\(Int(Date().timeIntervalSince1970 * 1000))"
    connectionAttemptIdByCentral[centralId] = attemptId
    logBle(
      "Approval | New connectionAttemptId created reason=ble_first_notify "
        + "central=\(centralId) connectionAttemptId=\(attemptId)"
    )
    return attemptId
  }

  private func notifyConnectionRequest(centralId: String, friendlyName: String) {
    let attemptId = stableConnectionAttemptId(for: centralId)
    logBle(
      "approval requested central=\(centralId) friendlyName=\(friendlyName) "
        + "connectionAttemptId=\(attemptId)"
    )
    DispatchQueue.main.async { [weak self] in
      self?.logBle("approval dialog invoke notifyConnectionRequest central=\(centralId)")
      self?.uiChannel.invokeMethod(
        "notifyConnectionRequest",
        arguments: [
          "friendlyName": friendlyName,
          "deviceAddress": centralId,
          "connectionAttemptId": attemptId,
        ]
      )
    }
  }

  // MARK: - Guest handshake

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

    let guestPeerId = (args["guestPeerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? peerId
    let guestDisplayName = (args["guestDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let clientHelloJson = (args["clientHelloJson"] as? String) ?? ""
    if let data = clientHelloJson.data(using: .utf8), !clientHelloJson.isEmpty {
      pendingGuestClientHelloData = data
    } else {
      let payload: [String: String] = [
        "type": "client_hello",
        "peer_id": guestPeerId,
        "display_name": guestDisplayName.isEmpty ? "Guest" : guestDisplayName,
      ]
      pendingGuestClientHelloData = try? JSONSerialization.data(withJSONObject: payload)
    }
    logBle(
      "ClientHello guestPeerId=\(guestPeerId) displayName=\(guestDisplayName) "
        + "handshake start peerId=\(peerId) name=\(peripheral.name ?? "?")"
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
    logBle(
      "ServerHello raw JSON keys=[\(rawKeys)] service=\(Self.serviceUuid.uuidString) "
        + "handshake=\(Self.handshakeCharacteristicUuid.uuidString)"
    )
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
      "platform": "macos",
    ]
    emitScanPeers()
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    if peripheral === activeGuestPeripheral {
      logBle("ClientHello: connected peer=\(peripheral.identifier.uuidString), discovering services")
      peripheral.discoverServices([Self.serviceUuid])
      return
    }
    if peripheral === pendingEndpointReadPeripheral {
      logBle("endpoint read: connected peer=\(peripheral.identifier.uuidString), discovering services")
      peripheral.discoverServices([Self.serviceUuid])
    }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if peripheral === pendingEndpointReadPeripheral, !endpointReadCompleted {
      completeEndpointRead(nil)
      return
    }
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
    if peripheral === pendingEndpointReadPeripheral, !endpointReadCompleted {
      completeEndpointRead(nil)
      return
    }
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
    if peripheral === pendingEndpointReadPeripheral {
      if let error {
        logBle("endpoint read service discovery failed: \(error.localizedDescription)")
        completeEndpointRead(nil)
        return
      }
      guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUuid }) else {
        completeEndpointRead(nil)
        return
      }
      peripheral.discoverCharacteristics([Self.endpointCharacteristicUuid], for: service)
      return
    }

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
    if peripheral === pendingEndpointReadPeripheral {
      if let error {
        completeEndpointRead(nil)
        logBle("endpoint characteristic discovery failed: \(error.localizedDescription)")
        return
      }
      guard let endpointChar = service.characteristics?.first(where: {
        $0.uuid == Self.endpointCharacteristicUuid
      }) else {
        completeEndpointRead(nil)
        return
      }
      peripheral.readValue(for: endpointChar)
      return
    }

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
    logBle(
      "handshake characteristic discovered uuid=\(handshakeChar.uuid.uuidString) "
        + "properties=\(handshakeChar.properties.rawValue)"
    )
    if let hello = pendingGuestClientHelloData {
      pendingGuestClientHelloData = nil
      logBle("ClientHello: writing identity payload (\(hello.count) bytes)")
      peripheral.writeValue(hello, for: handshakeChar, type: .withResponse)
    } else {
      logBle("ClientHello: subscribe notify + initial read on handshake characteristic")
      peripheral.setNotifyValue(true, for: handshakeChar)
      peripheral.readValue(for: handshakeChar)
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
      logBle("ClientHello write failed: \(error.localizedDescription); continuing handshake")
    } else {
      logBle("ClientHello written successfully")
    }
    logBle("ClientHello: subscribe notify + initial read on handshake characteristic")
    peripheral.setNotifyValue(true, for: characteristic)
    peripheral.readValue(for: characteristic)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if peripheral === pendingEndpointReadPeripheral,
       characteristic.uuid == Self.endpointCharacteristicUuid {
      if let error {
        logBle("endpoint read failed: \(error.localizedDescription)")
        completeEndpointRead(nil)
        return
      }
      let raw = String(data: characteristic.value ?? Data(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let parts = raw.split(separator: ":")
      let ip = parts.first.map(String.init) ?? ""
      let port = parts.count > 1 ? Int(parts[1]) ?? 8080 : 8080
      completeEndpointRead(["ip": ip, "port": port])
      return
    }

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

// MARK: - CBPeripheralManagerDelegate (host)

extension BleTransportPlugin: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    logBle("peripheral manager state=\(peripheralStateLabel(peripheral.state))")
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
    logBle("service created uuid=\(service.uuid.uuidString) characteristics=[\(charUuids)]")
    startBleAdvertisingIfReady()
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      isAdvertising = false
      logBle("advertising start FAILED: \(error.localizedDescription)")
      return
    }
    logBle("advertising started (didStartAdvertising callback)")
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
      if handshakePayload.isEmpty {
        logBle(
          "handshake subscribe before approval central=\(central.identifier.uuidString) "
            + "— no ServerHello pushed"
        )
      } else if let char = handshakeCharacteristic {
        let notified = peripheralManager.updateValue(
          handshakePayload,
          for: char,
          onSubscribedCentrals: [central]
        )
        logBle(
          "handshake subscribe after approval central=\(central.identifier.uuidString) "
            + "notify_sent=\(notified) bytes=\(handshakePayload.count)"
        )
      }
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    logBle(
      "central unsubscribed uuid=\(characteristic.uuid.uuidString) central=\(central.identifier.uuidString)"
    )
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

    if !handshakePayload.isEmpty {
      request.value = handshakePayload
      peripheral.respond(to: request, withResult: .success)
      if let json = String(data: handshakePayload, encoding: .utf8) {
        logBle("handshake read response (approved ServerHello): \(json.prefix(180))")
      }
      return
    }

    // Protected: empty until host approves. First empty read triggers Flutter approval UI.
    let centralId = request.central.identifier.uuidString
    if pendingApprovalCentralId == nil {
      pendingApprovalCentralId = centralId
      scheduleApprovalTimeout()
    }
    if let hello = clientHelloByCentralId[centralId] {
      emitConnectionRequestOnce(
        centralId: centralId,
        friendlyName: hello.displayName,
        reason: "empty_read_with_client_hello"
      )
    } else if !approvalUiEmittedCentrals.contains(centralId) {
      cancelPendingApprovalNotify(centralId: centralId)
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.pendingApprovalNotifyWorkItems.removeValue(forKey: centralId)
        // Prefer ClientHello name when available; otherwise emit a reliable
        // fallback so the host still gets exactly one approval request.
        let name = self.clientHelloByCentralId[centralId]?.displayName ?? "Unknown Peer"
        self.emitConnectionRequestOnce(
          centralId: centralId,
          friendlyName: name,
          reason: name == "Unknown Peer" ? "empty_read_fallback" : "empty_read_after_client_hello"
        )
      }
      pendingApprovalNotifyWorkItems[centralId] = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
      logBle("Approval | Deferring UI until ClientHello central=\(centralId)")
    } else {
      logBle("handshake read empty — approval UI already emitted central=\(centralId)")
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
        if let data = request.value, let hello = parseClientHello(data) {
          let centralId = request.central.identifier.uuidString
          clientHelloByCentralId[centralId] = hello
          logBle(
            "ClientHello displayName=\(hello.displayName) guestPeerId=\(hello.peerId) "
              + "central=\(centralId)"
          )
          if pendingApprovalCentralId == nil {
            pendingApprovalCentralId = centralId
            scheduleApprovalTimeout()
          }
          cancelPendingApprovalNotify(centralId: centralId)
          emitConnectionRequestOnce(
            centralId: centralId,
            friendlyName: hello.displayName,
            reason: "client_hello_write"
          )
          peripheral.respond(to: request, withResult: .success)
        } else {
          peripheral.respond(to: request, withResult: .writeNotPermitted)
        }
      } else if request.characteristic.uuid == Self.endpointCharacteristicUuid {
        peripheral.respond(to: request, withResult: .success)
      } else {
        peripheral.respond(to: request, withResult: .success)
      }
    }
  }
}
