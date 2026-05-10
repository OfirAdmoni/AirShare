package com.example.air_share

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.UUID

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    private val bleMethodChannelName = "air_share/ble_transport"
    private val bleScanEventChannelName = "air_share/ble_scan_events"
    private val wlanMethodChannelName = "air_share/wlan_link"
    private val bleUiChannelName = "air_share/ble_ui"

    private val serviceUuid: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private val handshakeCharacteristicUuid: UUID = UUID.fromString("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private val endpointCharacteristicUuid: UUID = UUID.fromString("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private val clientConfigDescriptorUuid: UUID =
        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var bleMethodChannel: MethodChannel? = null
    private var wlanMethodChannel: MethodChannel? = null
    private var bleUiChannel: MethodChannel? = null
    private var bleScanEventSink: EventChannel.EventSink? = null

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var bleScanner: BluetoothLeScanner? = null
    private var bleAdvertiser: BluetoothLeAdvertiser? = null

    private var gattServer: BluetoothGattServer? = null
    private var handshakeCharacteristic: BluetoothGattCharacteristic? = null
    private var endpointCharacteristic: BluetoothGattCharacteristic? = null
    private var activeGattClient: BluetoothGatt? = null
    private var isScanning = false
    private var isAdvertising = false
    private var pendingAdvertiseSettings: AdvertiseSettings? = null
    private var pendingAdvertiseData: AdvertiseData? = null
    private var pendingScanResponseData: AdvertiseData? = null
    private var pendingAdvertiseResult: MethodChannel.Result? = null

    private var pendingReadDevice: BluetoothDevice? = null
    private var pendingReadRequestId: Int? = null
    private var pendingReadOffset: Int = 0

    private val approvalTimeoutHandler = Handler(Looper.getMainLooper())
    private var approvalTimeoutRunnable: Runnable? = null

    private var pendingHotspotSsid: String? = null
    private var pendingHotspotPassword: String? = null
    private var pendingHubIp: String? = null
    private var pendingHubPort: Int = 8080
    private var advertisedEndpoint: String = ""

    private var activeHotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var localHotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var connectivityCallback: ConnectivityManager.NetworkCallback? = null

    private val discoveredPeersById = linkedMapOf<String, Map<String, String>>()

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionAction: (() -> Unit)? = null

    private val bleScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val serviceData = result.scanRecord?.serviceUuids ?: emptyList()
            val hasService = serviceData.any { it.uuid == serviceUuid }
            if (!hasService) return

            val friendlyName = result.scanRecord?.deviceName
                ?: device.name
                ?: "Unknown Peer"
            val peerMap = mapOf(
                "id" to device.address,
                "friendlyName" to friendlyName,
                "serviceUuid" to serviceUuid.toString(),
            )
            discoveredPeersById[device.address] = peerMap
            bleScanEventSink?.success(discoveredPeersById.values.toList())
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e("AirShareNative", "BLE scan failed: code=$errorCode")
            bleScanEventSink?.error("ble_scan_failed", "BLE scan failed code=$errorCode", null)
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            Log.i("AirShareNative", "BLE advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            Log.e("AirShareNative", "BLE advertising failed: code=$errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.i("AirShareNative", "Peer connected for secure handshake: ${device.address}")
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == endpointCharacteristicUuid) {
                val payload = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    payload,
                )
                return
            }
            if (characteristic.uuid != handshakeCharacteristicUuid) return
            if (pendingReadDevice != null) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_FAILURE,
                    offset,
                    null,
                )
                return
            }

            pendingReadDevice = device
            pendingReadRequestId = requestId
            pendingReadOffset = offset
            scheduleApprovalTimeout(device)
            Log.i(
                "AirShareNative",
                "Peer Handshake Blocked - Waiting for UI Approval (${device.address})",
            )

            val friendlyName = device.name ?: "Unknown Peer"
            runOnUiThread {
                bleUiChannel?.invokeMethod(
                    "notifyConnectionRequest",
                    mapOf(
                        "friendlyName" to friendlyName,
                        "deviceAddress" to device.address,
                    ),
                )
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid == handshakeCharacteristicUuid) {
                Log.w("AirShareNative", "Handshake characteristic write rejected from ${device.address}")
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_WRITE_NOT_PERMITTED,
                        offset,
                        null,
                    )
                }
                return
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_FAILURE,
                    offset,
                    null,
                )
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (descriptor.uuid == clientConfigDescriptorUuid) {
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        value,
                    )
                }
                return
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_FAILURE,
                    offset,
                    null,
                )
            }
        }

        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (service.uuid != serviceUuid) return
            val result = pendingAdvertiseResult ?: return
            val advertiser = bleAdvertiser
            val settings = pendingAdvertiseSettings
            val advertiseData = pendingAdvertiseData
            val scanResponse = pendingScanResponseData

            pendingAdvertiseResult = null
            pendingAdvertiseSettings = null
            pendingAdvertiseData = null
            pendingScanResponseData = null

            if (status != BluetoothGatt.GATT_SUCCESS ||
                advertiser == null ||
                settings == null ||
                advertiseData == null ||
                scanResponse == null
            ) {
                isAdvertising = false
                Log.e("AirShareNative", "Failed to add GATT service before advertising. status=$status")
                result.error("gatt_service_add_failed", "Failed to add GATT service.", null)
                return
            }

            try {
                isAdvertising = true
                advertiser.startAdvertising(settings, advertiseData, scanResponse, advertiseCallback)
                Log.i("AirShareNative", "Hub BLE advertising active with UUID: $serviceUuid")
                result.success(null)
            } catch (e: Exception) {
                isAdvertising = false
                Log.e("AirShareNative", "Unable to start BLE advertising after service add: ${e.message}")
                result.error("ble_advertise_failed", e.message, null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter
        bleScanner = bluetoothAdapter?.bluetoothLeScanner
        bleAdvertiser = bluetoothAdapter?.bluetoothLeAdvertiser

        bleMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            bleMethodChannelName,
        ).also { it.setMethodCallHandler(this) }

        wlanMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            wlanMethodChannelName,
        ).also { it.setMethodCallHandler(this) }

        bleUiChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            bleUiChannelName,
        )

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            bleScanEventChannelName,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                bleScanEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                bleScanEventSink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScanning" -> ensurePermissionsThenExecute(result) { startScanning(result) }
            "stopScanning" -> stopScanning(result)
            "startHubAdvertising" -> ensurePermissionsThenExecute(result) { startHubAdvertising(call, result) }
            "stopHubAdvertising" -> stopHubAdvertising(result)
            "establishSecureHandshake" -> ensurePermissionsThenExecute(result) { establishSecureHandshake(call, result) }
            "readPeerEndpoint" -> ensurePermissionsThenExecute(result) { readPeerEndpoint(call, result) }
            "updateHubEndpoint" -> updateHubEndpoint(call, result)
            "approveConnection" -> approveConnection(call, result)
            "startTemporaryHotspot" -> ensurePermissionsThenExecute(result) { startTemporaryHotspot(call, result) }
            "connectToHubWlan" -> ensurePermissionsThenExecute(result) { connectToHubWlan(call, result) }
            "stopInternalLink" -> stopInternalLink(result)
            else -> result.notImplemented()
        }
    }

    private fun approveConnection(call: MethodCall, result: MethodChannel.Result) {
        val approved = call.argument<Boolean>("approved") ?: false
        if (!approved) {
            val device = pendingReadDevice
            val requestId = pendingReadRequestId
            if (device != null && requestId != null) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_FAILURE,
                    pendingReadOffset,
                    null,
                )
                gattServer?.cancelConnection(device)
            }
            clearPendingRead()
            Log.i("AirShareNative", "Peer Handshake Blocked: connection declined by operator")
            result.success(null)
            return
        }

        cancelApprovalTimeout()

        val payload = buildHandshakePayloadOrNull()
        if (payload == null) {
            result.error("handshake_not_ready", "WLAN credentials are not available yet.", null)
            return
        }

        val characteristic = handshakeCharacteristic
        characteristic?.value = payload

        val device = pendingReadDevice
        val requestId = pendingReadRequestId
        if (device != null && requestId != null && characteristic != null) {
            val notified = gattServer?.notifyCharacteristicChanged(device, characteristic, false) == true
            if (!notified) {
                Log.w("AirShareNative", "Handshake notify not sent immediately after approval update.")
            } else {
                Log.i("AirShareNative", "Handshake notify sent immediately after approval update.")
            }
            gattServer?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                pendingReadOffset,
                payload,
            )
            Log.i("AirShareNative", "Peer Handshake Released for ${device.address}")
        } else {
            Log.w("AirShareNative", "Peer Handshake Released but no pending device/read request was available.")
        }

        clearPendingRead()
        result.success(null)
    }

    private fun updateHubEndpoint(call: MethodCall, result: MethodChannel.Result) {
        val ip = call.argument<String>("ip")?.trim().orEmpty()
        val port = call.argument<Int>("port") ?: 8080
        if (ip.isEmpty()) {
            result.error("invalid_endpoint", "ip is required", null)
            return
        }
        pendingHubIp = ip
        pendingHubPort = port
        advertisedEndpoint = "$ip:$port"
        endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
        result.success(null)
    }

    private fun scheduleApprovalTimeout(device: BluetoothDevice) {
        cancelApprovalTimeout()
        approvalTimeoutRunnable = Runnable {
            if (pendingReadDevice?.address != device.address) return@Runnable
            Log.w("AirShareNative", "Peer Handshake Blocked: approval timeout for ${device.address}")
            val requestId = pendingReadRequestId
            if (requestId != null) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_FAILURE,
                    pendingReadOffset,
                    null,
                )
            }
            gattServer?.cancelConnection(device)
            clearPendingRead()
        }
        approvalTimeoutHandler.postDelayed(approvalTimeoutRunnable!!, 30_000)
    }

    private fun cancelApprovalTimeout() {
        approvalTimeoutRunnable?.let { approvalTimeoutHandler.removeCallbacks(it) }
        approvalTimeoutRunnable = null
    }

    private fun clearPendingRead() {
        pendingReadDevice = null
        pendingReadRequestId = null
        pendingReadOffset = 0
        cancelApprovalTimeout()
    }

    private fun buildHandshakePayloadOrNull(): ByteArray? {
        val ssid = pendingHotspotSsid
        val password = pendingHotspotPassword
        val hubIp = pendingHubIp
        if (ssid.isNullOrBlank() || password.isNullOrBlank() || hubIp.isNullOrBlank()) {
            return null
        }
        return JSONObject().apply {
            put("ssid", ssid)
            put("password", password)
            put("hubIp", hubIp)
            put("hubPort", pendingHubPort)
        }.toString().toByteArray(StandardCharsets.UTF_8)
    }

    private fun requiredPermissions(): Array<String> {
        val perms = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            perms += Manifest.permission.BLUETOOTH_SCAN
            perms += Manifest.permission.BLUETOOTH_ADVERTISE
            perms += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            perms += Manifest.permission.BLUETOOTH
            perms += Manifest.permission.BLUETOOTH_ADMIN
        }
        perms += Manifest.permission.ACCESS_FINE_LOCATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms += Manifest.permission.NEARBY_WIFI_DEVICES
        }
        return perms.toTypedArray()
    }

    private fun ensurePermissionsThenExecute(
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        val missing = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            action()
            return
        }
        pendingPermissionResult = result
        pendingPermissionAction = action
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), 9201)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 9201) return
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED }
        if (granted) {
            pendingPermissionAction?.invoke()
        } else {
            pendingPermissionResult?.error(
                "permission_denied",
                "Required Bluetooth/Wi-Fi permissions were not granted.",
                null,
            )
        }
        pendingPermissionResult = null
        pendingPermissionAction = null
    }

    private fun startScanning(result: MethodChannel.Result) {
        val scanner = bleScanner ?: run {
            result.error("ble_unavailable", "Bluetooth LE scanner is unavailable.", null)
            return
        }
        if (isScanning) {
            result.success(null)
            return
        }
        val scanFilter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(serviceUuid))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        discoveredPeersById.clear()
        scanner.startScan(listOf(scanFilter), settings, bleScanCallback)
        isScanning = true
        Log.i("AirShareNative", "Peer Discovery via BLE started")
        result.success(null)
    }

    private fun stopScanning(result: MethodChannel.Result) {
        bleScanner?.stopScan(bleScanCallback)
        isScanning = false
        result.success(null)
    }

    private fun startHubAdvertising(call: MethodCall, result: MethodChannel.Result) {
        val advertiser = bleAdvertiser ?: run {
            result.error("ble_unavailable", "Bluetooth LE advertiser is unavailable.", null)
            return
        }
        if (isAdvertising || pendingAdvertiseResult != null) {
            Log.w("AirShareNative", "BLE advertising already active or starting; start request ignored")
            result.success(null)
            return
        }
        val fromFlutter = call.argument<String>("friendlyName")?.trim().orEmpty()
        val modelFallback = Build.MODEL.trim().ifBlank {
            Build.PRODUCT.trim().ifBlank { "Android" }
        }
        val baseName = if (fromFlutter.isNotEmpty()) fromFlutter else modelFallback
        if (pendingHubIp != null && pendingHubIp!!.isNotBlank()) {
            advertisedEndpoint = "${pendingHubIp}:${pendingHubPort}"
        }
        var broadcastLabel = baseName.take(10).trim()
        if (broadcastLabel.isEmpty()) {
            broadcastLabel = modelFallback.take(10).trim().ifEmpty { "?" }
        }
        while (broadcastLabel.toByteArray(StandardCharsets.UTF_8).size > 29) {
            broadcastLabel = broadcastLabel.dropLast(1)
        }

        val primaryAdEstimate = 3 + 18
        val scanAdEstimate =
            if (broadcastLabel.isEmpty()) {
                0
            } else {
                2 + broadcastLabel.toByteArray(StandardCharsets.UTF_8).size
            }
        if (primaryAdEstimate > 31) {
            Log.e(
                "AirShareNative",
                "BLE primary advertisement estimate $primaryAdEstimate bytes > 31; refusing startAdvertising",
            )
            result.error("ble_adv_oversize", "Primary BLE advertisement too large.", null)
            return
        }
        if (scanAdEstimate > 31) {
            Log.e(
                "AirShareNative",
                "BLE scan response estimate $scanAdEstimate bytes > 31; refusing startAdvertising",
            )
            result.error("ble_adv_oversize", "BLE scan response too large.", null)
            return
        }

        try {
            bluetoothAdapter?.name = broadcastLabel
        } catch (e: SecurityException) {
            Log.w("AirShareNative", "Could not set Bluetooth adapter name for scan response: ${e.message}")
        }

        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val characteristic = BluetoothGattCharacteristic(
            handshakeCharacteristicUuid,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        val endpoint = BluetoothGattCharacteristic(
            endpointCharacteristicUuid,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val cccd = BluetoothGattDescriptor(
            clientConfigDescriptorUuid,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
        )
        characteristic.addDescriptor(cccd)
        service.addCharacteristic(characteristic)
        service.addCharacteristic(endpoint)

        gattServer?.close()
        gattServer = bluetoothManager?.openGattServer(this, gattServerCallback)
        if (gattServer == null) {
            result.error("gatt_server_error", "Unable to open GATT server.", null)
            return
        }
        handshakeCharacteristic = characteristic
        endpointCharacteristic = endpoint
        handshakeCharacteristic?.value = null
        endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)

        val advertiseSettings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val advertiseData = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

        Log.i(
            "AirShareNative",
            "Hub BLE adv: primary≈${primaryAdEstimate}b (flags+UUID only), scan≈${scanAdEstimate}b (name='$broadcastLabel'), service=$serviceUuid",
        )
        pendingAdvertiseSettings = advertiseSettings
        pendingAdvertiseData = advertiseData
        pendingScanResponseData = scanResponse
        pendingAdvertiseResult = result

        val added = gattServer?.addService(service) == true
        if (!added) {
            pendingAdvertiseSettings = null
            pendingAdvertiseData = null
            pendingScanResponseData = null
            pendingAdvertiseResult = null
            isAdvertising = false
            result.error("gatt_service_add_failed", "Unable to register GATT service.", null)
            return
        }
        Log.i("AirShareNative", "Waiting for GATT service registration before advertising")
    }

    private fun stopHubAdvertising(result: MethodChannel.Result) {
        bleAdvertiser?.stopAdvertising(advertiseCallback)
        isAdvertising = false
        pendingAdvertiseSettings = null
        pendingAdvertiseData = null
        pendingScanResponseData = null
        pendingAdvertiseResult = null
        clearPendingRead()
        gattServer?.close()
        gattServer = null
        handshakeCharacteristic = null
        endpointCharacteristic = null
        result.success(null)
    }

    private fun establishSecureHandshake(call: MethodCall, result: MethodChannel.Result) {
        val peerId = call.argument<String>("peerId")
        if (peerId.isNullOrBlank()) {
            result.error("invalid_peer", "Peer id is required.", null)
            return
        }
        val device = bluetoothAdapter?.getRemoteDevice(peerId)
        if (device == null) {
            result.error("peer_not_found", "Unable to resolve peer device.", null)
            return
        }

        activeGattClient?.close()
        activeGattClient = device.connectGatt(this, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        result.error("handshake_disconnect", "Disconnected during handshake.", null)
                    }
                    gatt.close()
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    result.error("service_discovery_failed", "Unable to discover handshake service.", null)
                    gatt.close()
                    return
                }
                val service = gatt.getService(serviceUuid)
                val characteristic = service?.getCharacteristic(handshakeCharacteristicUuid)
                if (characteristic == null) {
                    result.error("characteristic_missing", "Handshake characteristic missing.", null)
                    gatt.close()
                    return
                }
                val initiated = gatt.readCharacteristic(characteristic)
                if (!initiated) {
                    result.error("handshake_read_failed", "Failed to start handshake read.", null)
                    gatt.close()
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                if (characteristic.uuid != handshakeCharacteristicUuid) return
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    result.error("handshake_failed", "Secure handshake read failed.", null)
                    gatt.close()
                    return
                }
                val payloadString = String(value, StandardCharsets.UTF_8)
                val payload = JSONObject(payloadString)
                Log.i("AirShareNative", "Peer Handshake Success for peer=$peerId")
                result.success(
                    mapOf(
                        "ssid" to payload.optString("ssid", ""),
                        "password" to payload.optString("password", ""),
                        "hubIp" to payload.optString("hubIp", ""),
                        "hubPort" to payload.optInt("hubPort", 8080),
                    ),
                )
                gatt.close()
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                onCharacteristicRead(
                    gatt,
                    characteristic,
                    characteristic.value ?: ByteArray(0),
                    status,
                )
            }
        })
    }

    private fun readPeerEndpoint(call: MethodCall, result: MethodChannel.Result) {
        val peerId = call.argument<String>("peerId")
        if (peerId.isNullOrBlank()) {
            result.error("invalid_peer", "Peer id is required.", null)
            return
        }
        val device = bluetoothAdapter?.getRemoteDevice(peerId)
        if (device == null) {
            result.error("peer_not_found", "Unable to resolve peer device.", null)
            return
        }

        activeGattClient?.close()
        activeGattClient = device.connectGatt(this, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        result.error("endpoint_disconnect", "Disconnected while reading endpoint.", null)
                    }
                    gatt.close()
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    result.error("service_discovery_failed", "Unable to discover endpoint service.", null)
                    gatt.close()
                    return
                }
                val service = gatt.getService(serviceUuid)
                val characteristic = service?.getCharacteristic(endpointCharacteristicUuid)
                if (characteristic == null) {
                    result.error("endpoint_characteristic_missing", "Endpoint characteristic missing.", null)
                    gatt.close()
                    return
                }
                if (!gatt.readCharacteristic(characteristic)) {
                    result.error("endpoint_read_start_failed", "Failed to start endpoint read.", null)
                    gatt.close()
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                if (characteristic.uuid != endpointCharacteristicUuid) return
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    result.error("endpoint_read_failed", "Endpoint read failed.", null)
                    gatt.close()
                    return
                }
                val endpoint = String(value, StandardCharsets.UTF_8).trim()
                val parts = endpoint.split(":")
                if (parts.size < 2) {
                    result.error("invalid_endpoint_payload", "Endpoint payload malformed: $endpoint", null)
                    gatt.close()
                    return
                }
                val ip = parts[0].trim()
                val port = parts[1].trim().toIntOrNull()
                if (ip.isEmpty() || port == null) {
                    result.error("invalid_endpoint_payload", "Endpoint payload malformed: $endpoint", null)
                    gatt.close()
                    return
                }
                result.success(mapOf("ip" to ip, "port" to port))
                gatt.close()
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                onCharacteristicRead(gatt, characteristic, characteristic.value ?: ByteArray(0), status)
            }
        })
    }

    private fun startTemporaryHotspot(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "LocalOnlyHotspot requires Android 8.0+.", null)
            return
        }
        if (activeHotspotReservation != null) {
            Log.w("AirShareNative", "LocalOnlyHotspot already active; ignoring duplicate start request")
            val ssid = pendingHotspotSsid ?: call.argument<String>("ssid") ?: "AirShareLink"
            val password = pendingHotspotPassword ?: call.argument<String>("password") ?: "AirShare@2026"
            val hubIp = pendingHubIp ?: resolveLocalIpv4Address()
            result.success(mapOf("ssid" to ssid, "password" to password, "hubIp" to hubIp))
            return
        }
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        try {
            wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                    activeHotspotReservation?.close()
                    localHotspotReservation = reservation
                    activeHotspotReservation = reservation
                    handshakeCharacteristic?.value = null
                    val wifiConfig = reservation.wifiConfiguration
                    val ssid = call.argument<String>("ssid") ?: wifiConfig?.SSID ?: "AirShareLink"
                    val password = call.argument<String>("password")
                        ?: wifiConfig?.preSharedKey
                        ?: "AirShare@2026"
                    val hubIp = resolveLocalIpv4Address()
                    pendingHotspotSsid = ssid
                    pendingHotspotPassword = password
                    pendingHubIp = hubIp
                    pendingHubPort = call.argument<Int>("hubPort") ?: 8080
                    advertisedEndpoint = "$hubIp:$pendingHubPort"
                    endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
                    Log.i("AirShareNative", "Internal Link Established: hotspot active")
                    result.success(
                        mapOf("ssid" to ssid, "password" to password, "hubIp" to hubIp),
                    )
                }

                override fun onFailed(reason: Int) {
                    activeHotspotReservation = null
                    localHotspotReservation = null
                    result.error("hotspot_failed", "Hotspot failed with reason=$reason", null)
                }
            }, null)
        } catch (se: SecurityException) {
            result.error("hotspot_permission", "Missing hotspot permission: ${se.message}", null)
        }
    }

    private fun connectToHubWlan(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "WLAN specifier requires Android 10+.", null)
            return
        }
        val ssid = call.argument<String>("ssid")
        val password = call.argument<String>("password")
        if (ssid.isNullOrBlank() || password.isNullOrBlank()) {
            result.error("invalid_wlan_credentials", "SSID and password are required.", null)
            return
        }

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .setNetworkSpecifier(specifier)
            .build()
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityCallback?.let { connectivityManager.unregisterNetworkCallback(it) }
        connectivityCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivityManager.bindProcessToNetwork(network)
                Log.i("AirShareNative", "Internal Link Established: connected to $ssid")
                result.success(null)
            }

            override fun onUnavailable() {
                result.error("wlan_unavailable", "Unable to connect to internal WLAN link.", null)
            }
        }
        connectivityManager.requestNetwork(request, connectivityCallback!!)
    }

    private fun stopInternalLink(result: MethodChannel.Result) {
        stopScanning(MethodChannelResultProxy())
        bleAdvertiser?.stopAdvertising(advertiseCallback)
        isAdvertising = false
        pendingAdvertiseSettings = null
        pendingAdvertiseData = null
        pendingScanResponseData = null
        pendingAdvertiseResult = null
        gattServer?.close()
        gattServer = null
        handshakeCharacteristic = null
        endpointCharacteristic = null
        clearPendingRead()
        pendingHotspotSsid = null
        pendingHotspotPassword = null
        pendingHubIp = null
        activeGattClient?.close()
        activeGattClient = null
        activeHotspotReservation?.close()
        activeHotspotReservation = null
        localHotspotReservation?.close()
        localHotspotReservation = null
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivityCallback?.let {
            connectivityManager.unregisterNetworkCallback(it)
        }
        connectivityCallback = null
        connectivityManager.bindProcessToNetwork(null)
        result.success(null)
    }

    private fun resolveLocalIpv4Address(): String {
        return try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (address in Collections.list(iface.inetAddresses)) {
                    if (address is Inet4Address && !address.isLoopbackAddress) {
                        return address.hostAddress ?: "192.168.43.1"
                    }
                }
            }
            "192.168.43.1"
        } catch (_: Exception) {
            "192.168.43.1"
        }
    }

    override fun onDestroy() {
        stopInternalLink(MethodChannelResultProxy())
        super.onDestroy()
    }

    private class MethodChannelResultProxy : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() {}
    }
}
