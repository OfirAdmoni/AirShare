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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.WpsInfo
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
import java.util.Locale
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
    private var handshakePayload: ByteArray = ByteArray(0)

    private val approvalTimeoutHandler = Handler(Looper.getMainLooper())
    private var approvalTimeoutRunnable: Runnable? = null

    private var pendingHotspotSsid: String? = null
    private var pendingHotspotPassword: String? = null
    private var pendingHubIp: String? = null
    private var pendingHubPort: Int = 8080
    private var advertisedEndpoint: String = ""
    private var pendingLanIp: String = ""
    private var pendingP2pIp: String = ""
    private var pendingHotspotHubIp: String = ""
    private var pendingFriendlyName: String = ""
    /// True only after LocalOnlyHotspotCallback.onStarted — gates BLE hotspot fields.
    private var hotspotActive = false

    private var handshakeDeliveryResult: MethodChannel.Result? = null
    private val hubWlanRequestHandler = Handler(Looper.getMainLooper())
    private var hubWlanRequestTimeoutRunnable: Runnable? = null
    private var handshakeDeliveryGatt: BluetoothGatt? = null
    private var handshakeDelivered = false
    private val handshakeWaitHandler = Handler(Looper.getMainLooper())
    private var handshakeWaitRunnable: Runnable? = null

    private var activeHotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var localHotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var connectivityCallback: ConnectivityManager.NetworkCallback? = null
    private var connectivityCallbackRegistered = false

    private var wifiP2pManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null
    private var pendingP2pMac: String = ""

    // Guest-side P2P connection state
    private var guestP2pManager: WifiP2pManager? = null
    private var guestP2pChannel: WifiP2pManager.Channel? = null
    private var guestP2pReceiver: BroadcastReceiver? = null
    private val guestP2pTimeoutHandler = Handler(Looper.getMainLooper())
    private var guestP2pTimeoutRunnable: Runnable? = null

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
            Log.i(
                "AirShareNative",
                "Android | GATT | Read Request received for UUID: ${characteristic.uuid}",
            )
            if (characteristic.uuid == endpointCharacteristicUuid) {
                val payload = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
                val sent = gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    payload,
                ) == true
                Log.i(
                    "AirShareNative",
                    "Android | GATT | Sending Response: ${String(payload, StandardCharsets.UTF_8)} (Length: ${payload.size})",
                )
                if (!sent) {
                    Log.w("AirShareNative", "Android | GATT | sendResponse failed for endpoint payload")
                }
                return
            }
            if (characteristic.uuid != handshakeCharacteristicUuid) return
            if (handshakePayload.isNotEmpty()) {
                val sent = gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    handshakePayload,
                ) == true
                val payloadText = String(handshakePayload, StandardCharsets.UTF_8)
                Log.i(
                    "AirShareNative",
                    "Android | GATT | Sending Response: $payloadText (Length: ${handshakePayload.size})",
                )
                if (!sent) {
                    Log.w("AirShareNative", "Android | GATT | sendResponse failed for approved payload")
                }
                return
            }
            if (pendingReadDevice != null) {
                val emptyPayload = ByteArray(0)
                val sent = gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    emptyPayload,
                ) == true
                Log.i(
                    "AirShareNative",
                    "Android | GATT | Sending Response:  (Length: 0)",
                )
                if (!sent) {
                    Log.w("AirShareNative", "Android | GATT | sendResponse failed for empty pending payload")
                }
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
            val emptyPayload = ByteArray(0)
            val sent = gattServer?.sendResponse(
                device,
                requestId,
                BluetoothGatt.GATT_SUCCESS,
                offset,
                emptyPayload,
            ) == true
            Log.i(
                "AirShareNative",
                "Android | GATT | Sending Response:  (Length: 0)",
            )
            if (!sent) {
                Log.w("AirShareNative", "Android | GATT | sendResponse failed for initial empty payload")
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

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.i(
                "AirShareNative",
                "Host BLE MTU changed for ${device.address}: $mtu (max ATT payload ≈ ${mtu - 3})",
            )
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
                val enableNotify = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                val enableIndicate = value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                descriptor.value = when {
                    enableNotify || enableIndicate -> value
                    else -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                }
                Log.i(
                    "AirShareNative",
                    "CCCD write from ${device.address}: notify=$enableNotify indicate=$enableIndicate responseNeeded=$responseNeeded",
                )
                val sent = gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    0,
                    null,
                ) == true
                if (!sent) {
                    Log.w("AirShareNative", "CCCD sendResponse failed for ${device.address}")
                }
                return
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_FAILURE,
                    0,
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
        Log.i(
            "AirShareNative",
            "Android | UUID Verify | Service: $serviceUuid | Characteristic: $handshakeCharacteristicUuid",
        )
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
            "updateConnectionEndpoints" -> updateConnectionEndpoints(call, result)
            "approveConnection" -> approveConnection(call, result)
            "ensureLocationForWifiTier" -> ensurePermissionsThenExecute(result) { ensureLocationForWifiTier(result) }
            "startTemporaryHotspot" -> ensurePermissionsThenExecute(result) {
                ensureLocationReadyForWifiTier(result) { startTemporaryHotspot(call, result) }
            }
            "connectToHubWlan" -> ensureWlanPermissionsThenExecute(result) { connectToHubWlan(call, result) }
            "startWifiDirectGroup" -> ensurePermissionsThenExecute(result) {
                ensureLocationReadyForWifiTier(result) { startWifiDirectGroupInternal(result) }
            }
            "teardownP2pBeforeHotspot" -> teardownP2pBeforeHotspot(result)
            "stopNativeHotspot" -> stopNativeHotspot(result)
            "stopWifiDirectGroup" -> stopWifiDirectGroup(result)
            "connectToWifiDirectPeer" -> ensurePermissionsThenExecute(result) {
                ensureLocationReadyForWifiTier(result) { connectToWifiDirectPeerInternal(call, result) }
            }
            "stopInternalLink" -> stopInternalLink(result)
            "isBluetoothEnabled" -> ensurePermissionsThenExecute(result) { isBluetoothEnabled(result) }
            "requestEnableBluetooth" -> ensurePermissionsThenExecute(result) { requestEnableBluetooth(result) }
            "openWirelessSettings" -> openWirelessSettings(result)
            "openBluetoothSettings" -> openBluetoothSettings(result)
            "shareLogs" -> shareLogs(call, result)
            "getLocalPeerId" -> ensurePermissionsThenExecute(result) { getLocalPeerId(result) }
            else -> result.notImplemented()
        }
    }

    private fun resolveBluetoothAdapter(): BluetoothAdapter? {
        if (bluetoothAdapter == null) {
            bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            bluetoothAdapter = bluetoothManager?.adapter
        }
        return bluetoothAdapter
    }

    private fun isBluetoothEnabled(result: MethodChannel.Result) {
        val adapter = resolveBluetoothAdapter()
        if (adapter == null) {
            result.success(false)
            return
        }
        result.success(adapter.isEnabled)
    }

    private fun requestEnableBluetooth(result: MethodChannel.Result) {
        val adapter = resolveBluetoothAdapter()
        if (adapter == null) {
            result.error("ble_unavailable", "Bluetooth is not available on this device.", null)
            return
        }
        if (adapter.isEnabled) {
            result.success(mapOf("enabled" to true, "prompted" to false))
            return
        }
        try {
            @Suppress("DEPRECATION")
            startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
            Log.i("AirShareNative", "Launched ACTION_REQUEST_ENABLE for Bluetooth")
            result.success(mapOf("enabled" to false, "prompted" to true))
        } catch (e: Exception) {
            result.error("bluetooth_enable_failed", e.message, null)
        }
    }

    private fun openWirelessSettings(result: MethodChannel.Result) {
        try {
            startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
            result.success(null)
        } catch (e: Exception) {
            result.error("settings_intent_failed", e.message, null)
        }
    }

    private fun openBluetoothSettings(result: MethodChannel.Result) {
        try {
            startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
            result.success(null)
        } catch (e: Exception) {
            result.error("settings_intent_failed", e.message, null)
        }
    }

    private fun isUsableBtAddress(address: String?): Boolean {
        if (address.isNullOrBlank()) return false
        return address.uppercase() != "02:00:00:00:00:00"
    }

    private fun getLocalPeerId(result: MethodChannel.Result) {
        val prefs = getSharedPreferences("air_share", Context.MODE_PRIVATE)
        val adapter = resolveBluetoothAdapter()
        val btAddr = adapter?.address?.trim()
        if (isUsableBtAddress(btAddr)) {
            prefs.edit().putString("local_peer_id", btAddr).apply()
            result.success(mapOf("peerId" to btAddr))
            return
        }
        var id = prefs.getString("local_peer_id", null)?.trim()
        if (id.isNullOrEmpty()) {
            id = java.util.UUID.randomUUID().toString()
            prefs.edit().putString("local_peer_id", id).apply()
        }
        result.success(mapOf("peerId" to id))
    }

    private fun shareLogs(call: MethodCall, result: MethodChannel.Result) {
        val logText = call.argument<String>("text")?.trim().orEmpty()
        if (logText.isEmpty()) {
            result.error("empty_logs", "No log text to share.", null)
            return
        }
        try {
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                action = Intent.ACTION_SEND
                putExtra(Intent.EXTRA_TEXT, logText)
                type = "text/plain"
            }
            startActivity(Intent.createChooser(sendIntent, "Share Connection Logs"))
            result.success(null)
        } catch (e: Exception) {
            Log.e("AirShareNative", "shareLogs failed: ${e.message}")
            result.error("share_failed", e.message, null)
        }
    }

    /** RFC1918 / link-local — includes shared Wi‑Fi subnets like 10.252.x.x (never carrier-only). */
    private fun isPrivateLanIpv4(ip: String): Boolean {
        val parts = ip.trim().split('.')
        if (parts.size != 4) return false
        val octets = parts.mapNotNull { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it !in 0..255 }) return false
        return when (octets[0]) {
            10 -> true
            172 -> octets[1] in 16..31
            192 -> octets[1] == 168
            169 -> octets[1] == 254
            else -> false
        }
    }

    private fun applyLanIpFromDart(raw: String, reason: String) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return
        if (!isPrivateLanIpv4(trimmed)) {
            Log.w(
                "AirShareNative",
                "applyLanIpFromDart($reason): ignored non-private ip=$trimmed",
            )
            return
        }
        if (trimmed == "127.0.0.1") return
        pendingLanIp = trimmed
        Log.i("AirShareNative", "applyLanIpFromDart($reason): pendingLanIp=$pendingLanIp")
    }

    private fun refreshCachedHandshakePayload(reason: String) {
        val built = buildHandshakePayloadOrNull()
        if (built != null) {
            handshakePayload = built
            handshakeCharacteristic?.value = built
            Log.i(
                "AirShareNative",
                "refreshCachedHandshakePayload($reason): ${String(built, StandardCharsets.UTF_8).take(220)}",
            )
        }
    }

    private fun approveConnection(call: MethodCall, result: MethodChannel.Result) {
        val approved = call.argument<Boolean>("approved") ?: false
        call.argument<String>("lanIp")?.let { applyLanIpFromDart(it, "approveConnection") }
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
            handshakePayload = ByteArray(0)
            handshakeCharacteristic?.value = null
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
        handshakePayload = payload.copyOf()
        Log.i(
            "AirShareNative",
            "Android | approveConnection | handshakePayload length=${handshakePayload.size} body=${String(handshakePayload, StandardCharsets.UTF_8).take(200)}",
        )

        val characteristic = handshakeCharacteristic
        characteristic?.value = handshakePayload

        val device = pendingReadDevice
        val requestId = pendingReadRequestId
        if (device != null && characteristic != null) {
            val notified = gattServer?.notifyCharacteristicChanged(device, characteristic, false) == true
            Log.i(
                "AirShareNative",
                "notifyCharacteristicChanged() returned $notified for ${device.address} " +
                    "(payloadBytes=${handshakePayload.size})",
            )
            if (!notified) {
                Log.w(
                    "AirShareNative",
                    "Handshake notify failed — client may not have subscribed (CCCD) or MTU too small.",
                )
            }
            if (requestId != null) {
                val readResponseSent = gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    pendingReadOffset,
                    handshakePayload,
                ) == true
                Log.i(
                    "AirShareNative",
                    "Handshake read response sent=$readResponseSent for ${device.address}",
                )
            }
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
        applyLanIpFromDart(ip, "updateHubEndpoint")
        pendingHubIp = ip
        pendingHubPort = port
        advertisedEndpoint = "$ip:$port"
        endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
        Log.i(
            "AirShareNative",
            "updateHubEndpoint: pendingLanIp=$pendingLanIp endpoint=$advertisedEndpoint",
        )
        refreshCachedHandshakePayload("updateHubEndpoint")
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
            handshakePayload = ByteArray(0)
            handshakeCharacteristic?.value = null
            clearPendingRead()
        }
        approvalTimeoutHandler.postDelayed(approvalTimeoutRunnable!!, 45_000)
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

    private fun handshakePayloadIsReady(json: JSONObject): Boolean {
        if (json.optString("lan_ip").isNotBlank()) return true
        if (json.optString("hubIp").isNotBlank()) return true
        if (json.optString("p2p_ip").isNotBlank()) return true
        if (json.optString("p2p_mac").isNotBlank() || json.optString("p2pMac").isNotBlank()) return true
        if (json.optString("hotspot_ssid").isNotBlank() || json.optString("ssid").isNotBlank()) return true
        return false
    }

    private fun parseHandshakePayload(json: JSONObject): Map<String, Any> {
        return mapOf(
            "lan_ip" to json.optString("lan_ip", json.optString("hubIp", "")),
            "p2p_ip" to json.optString("p2p_ip", ""),
            "p2p_mac" to json.optString("p2p_mac", json.optString("p2pMac", "")),
            "hotspot_ssid" to json.optString("hotspot_ssid", json.optString("ssid", "")),
            "hotspot_pass" to json.optString("hotspot_pass", json.optString("password", "")),
            "hotspot_hub_ip" to json.optString("hotspot_hub_ip", ""),
            "hub_port" to json.optInt("hub_port", json.optInt("hubPort", 8080)),
            "friendly_name" to json.optString("friendly_name", ""),
        )
    }

    private fun cancelHandshakeWait() {
        handshakeWaitRunnable?.let { handshakeWaitHandler.removeCallbacks(it) }
        handshakeWaitRunnable = null
    }

    private fun deliverGuestHandshake(gatt: BluetoothGatt, value: ByteArray, source: String) {
        if (handshakeDelivered) return
        if (value.isEmpty()) return
        val payloadString = String(value, StandardCharsets.UTF_8).trim()
        if (payloadString.isEmpty()) return
        val payload = try {
            JSONObject(payloadString)
        } catch (e: Exception) {
            Log.w("AirShareNative", "Invalid handshake JSON ($source): ${e.message}")
            return
        }
        if (!handshakePayloadIsReady(payload)) return

        handshakeDelivered = true
        cancelHandshakeWait()
        val result = handshakeDeliveryResult ?: return
        handshakeDeliveryResult = null
        handshakeDeliveryGatt = null
        Log.i("AirShareNative", "Peer Handshake Success via $source")
        result.success(parseHandshakePayload(payload))
        gatt.close()
        activeGattClient = null
    }

    private fun scheduleHandshakeWait(gatt: BluetoothGatt) {
        cancelHandshakeWait()
        handshakeWaitRunnable = Runnable {
            if (handshakeDelivered) return@Runnable
            val result = handshakeDeliveryResult
            handshakeDeliveryResult = null
            handshakeDeliveryGatt = null
            result?.error(
                "handshake_timeout",
                "Timed out waiting for host approval notification.",
                null,
            )
            gatt.close()
            activeGattClient = null
        }
        handshakeWaitHandler.postDelayed(handshakeWaitRunnable!!, 45_000)
    }

    private fun buildHandshakePayloadOrNull(): ByteArray? {
        var lan = pendingLanIp.trim()
        if (lan.isNotEmpty() && !isPrivateLanIpv4(lan)) {
            Log.w(
                "AirShareNative",
                "buildHandshakePayloadOrNull: dropping invalid pendingLanIp=$lan",
            )
            lan = ""
        }
        val p2p = pendingP2pIp.trim()
        val ssid = if (hotspotActive) pendingHotspotSsid?.trim().orEmpty() else ""
        val password = if (hotspotActive) pendingHotspotPassword?.trim().orEmpty() else ""
        val p2pMac = pendingP2pMac.trim()
        val hotspotHub = if (hotspotActive) pendingHotspotHubIp.trim() else ""
        if (lan.isBlank()) {
            val hubFallback = pendingHubIp?.trim().orEmpty()
            if (hubFallback.isNotEmpty() && isPrivateLanIpv4(hubFallback) && ssid.isBlank()) {
                lan = hubFallback
            }
        }
        if (lan.isBlank() && p2p.isBlank() && ssid.isBlank()) {
            Log.w("AirShareNative", "Android | Handshake build skipped: no tier endpoints")
            return null
        }
        val primaryLegacy = when {
            lan.isNotBlank() -> lan
            p2p.isNotBlank() -> p2p
            hotspotHub.isNotBlank() -> hotspotHub
            else -> pendingHubIp?.trim().orEmpty()
        }
        val json = JSONObject().apply {
            if (lan.isNotBlank()) put("lan_ip", lan)
            if (p2p.isNotBlank()) put("p2p_ip", p2p)
            if (p2pMac.isNotBlank()) put("p2p_mac", p2pMac)
            if (ssid.isNotBlank()) put("hotspot_ssid", ssid)
            if (password.isNotBlank()) put("hotspot_pass", password)
            if (hotspotHub.isNotBlank()) put("hotspot_hub_ip", hotspotHub)
            put("hub_port", pendingHubPort)
            if (primaryLegacy.isNotBlank()) {
                put("hubIp", primaryLegacy)
                put("hubPort", pendingHubPort)
            }
            if (ssid.isNotBlank()) {
                put("ssid", ssid)
                put("password", password)
            }
            if (p2pMac.isNotBlank()) put("p2pMac", p2pMac)
            if (pendingFriendlyName.isNotBlank()) put("friendly_name", pendingFriendlyName)
        }.toString()
        Log.i(
            "AirShareNative",
            "Android | Handshake JSON built | lan_ip=$lan hotspot_hub_ip=$hotspotHub p2p_ip=$p2p hotspot_ssid_len=${ssid.length} port=$pendingHubPort",
        )
        return json.toByteArray(StandardCharsets.UTF_8)
    }

    private fun updateConnectionEndpoints(call: MethodCall, result: MethodChannel.Result) {
        applyLanIpFromDart(
            call.argument<String>("lanIp")?.trim().orEmpty(),
            "updateConnectionEndpoints",
        )
        val p2pFromDart = call.argument<String>("p2pIp")?.trim().orEmpty()
        if (p2pFromDart.isNotEmpty()) {
            pendingP2pIp = p2pFromDart
        }
        val hubFromDart = call.argument<String>("hotspotHubIp")?.trim().orEmpty()
        Log.i(
            "AirShareNative",
            "updateConnectionEndpoints: requested lan_ip=$pendingLanIp hotspot_hub_ip=$hubFromDart p2p_ip=$pendingP2pIp",
        )
        logAllIpv4Interfaces("updateConnectionEndpoints")
        val incomingP2pMac = call.argument<String>("p2pMac")?.trim().orEmpty()
        when {
            isUsableP2pMac(incomingP2pMac) -> pendingP2pMac = incomingP2pMac
            incomingP2pMac.isEmpty() && isUsableP2pMac(pendingP2pMac) -> {
                Log.i(
                    "AirShareNative",
                    "updateConnectionEndpoints: keeping native P2P MAC $pendingP2pMac",
                )
            }
            incomingP2pMac.isNotEmpty() -> {
                Log.w(
                    "AirShareNative",
                    "updateConnectionEndpoints: ignoring unusable p2pMac from Flutter: $incomingP2pMac",
                )
            }
        }
        val ssid = call.argument<String>("hotspotSsid")?.trim().orEmpty()
        val pass = call.argument<String>("hotspotPass")?.trim().orEmpty()
        if (ssid.isNotEmpty() && pass.isNotEmpty() && hotspotActive) {
            pendingHotspotSsid = ssid
            pendingHotspotPassword = pass
        }
        if (hubFromDart.isNotEmpty() && hotspotActive) {
            pendingHotspotHubIp = hubFromDart
        }
        pendingHubPort = call.argument<Int>("hubPort") ?: pendingHubPort

        val primary = when {
            pendingLanIp.isNotBlank() -> pendingLanIp
            pendingP2pIp.isNotBlank() -> pendingP2pIp
            pendingHotspotHubIp.isNotBlank() -> pendingHotspotHubIp
            else -> ""
        }
        if (primary.isNotBlank()) {
            pendingHubIp = primary
            advertisedEndpoint = "$primary:$pendingHubPort"
            endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
        }
        refreshCachedHandshakePayload("updateConnectionEndpoints")
        result.success(null)
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

    private fun requiredWlanPermissions(): Array<String> =
        (requiredPermissions().toList() + listOf(
            Manifest.permission.CHANGE_NETWORK_STATE,
            Manifest.permission.CHANGE_WIFI_STATE,
        )).distinct().toTypedArray()

    private fun isFineLocationGranted(): Boolean =
        ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

    private fun isLocationServicesEnabled(): Boolean {
        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    private fun isLocationReadyForWifiP2p(): Boolean =
        isFineLocationGranted() && isLocationServicesEnabled()

    private fun ensureLocationForWifiTier(result: MethodChannel.Result) {
        if (isLocationReadyForWifiP2p()) {
            result.success(mapOf("ready" to true))
        } else if (!isFineLocationGranted()) {
            result.error(
                "location_permission_denied",
                "ACCESS_FINE_LOCATION is required for Wi-Fi Direct.",
                null,
            )
        } else {
            result.error(
                "location_disabled",
                "Location services (GPS) must be enabled for Wi-Fi Direct.",
                null,
            )
        }
    }

    private fun ensureLocationReadyForWifiTier(
        result: MethodChannel.Result,
        onReady: () -> Unit,
    ) {
        if (isLocationReadyForWifiP2p()) {
            onReady()
            return
        }
        if (!isFineLocationGranted()) {
            result.error(
                "location_permission_denied",
                "ACCESS_FINE_LOCATION is required for Wi-Fi Direct.",
                null,
            )
            return
        }
        result.error(
            "location_disabled",
            "Location services (GPS) must be enabled for Wi-Fi Direct.",
            null,
        )
    }

    private fun ensureWlanPermissionsThenExecute(
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        val missing = requiredWlanPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            action()
            return
        }
        pendingPermissionResult = result
        pendingPermissionAction = action
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), 9201)
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
        pendingFriendlyName = baseName
        if (pendingHubIp != null && pendingHubIp!!.isNotBlank()) {
            advertisedEndpoint = "${pendingHubIp}:${pendingHubPort}"
        }
        var broadcastLabel = baseName.trim()
        if (broadcastLabel.isEmpty()) {
            broadcastLabel = modelFallback.trim().ifEmpty { "?" }
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
        handshakePayload = ByteArray(0)
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
        handshakePayload = ByteArray(0)
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

        cancelHandshakeWait()
        handshakeDelivered = false
        handshakeDeliveryResult = result
        activeGattClient?.close()
        var handshakeSetupStarted = false
        fun beginHandshakeSetup(gatt: BluetoothGatt) {
            if (handshakeSetupStarted) return
            handshakeSetupStarted = true
            gatt.discoverServices()
        }
        activeGattClient = device.connectGatt(this, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    Log.i("AirShareNative", "Guest BLE connected — requesting MTU 512")
                    if (!gatt.requestMtu(512)) {
                        Log.w("AirShareNative", "requestMtu(512) returned false; continuing with default MTU")
                        beginHandshakeSetup(gatt)
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (!handshakeDelivered && handshakeDeliveryResult != null) {
                        handshakeDeliveryResult?.error(
                            "handshake_disconnect",
                            "Disconnected during handshake.",
                            null,
                        )
                        handshakeDeliveryResult = null
                        cancelHandshakeWait()
                    }
                    gatt.close()
                    if (activeGattClient == gatt) activeGattClient = null
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.i(
                        "AirShareNative",
                        "Guest BLE MTU negotiated: $mtu (max ATT payload ≈ ${mtu - 3})",
                    )
                } else {
                    Log.w(
                        "AirShareNative",
                        "Guest BLE MTU request failed status=$status mtu=$mtu; continuing",
                    )
                }
                beginHandshakeSetup(gatt)
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    handshakeDeliveryResult?.error(
                        "service_discovery_failed",
                        "Unable to discover handshake service.",
                        null,
                    )
                    handshakeDeliveryResult = null
                    gatt.close()
                    return
                }
                val service = gatt.getService(serviceUuid)
                val characteristic = service?.getCharacteristic(handshakeCharacteristicUuid)
                if (characteristic == null) {
                    handshakeDeliveryResult?.error(
                        "characteristic_missing",
                        "Handshake characteristic missing.",
                        null,
                    )
                    handshakeDeliveryResult = null
                    gatt.close()
                    return
                }
                handshakeDeliveryGatt = gatt
                gatt.setCharacteristicNotification(characteristic, true)
                val descriptor = characteristic.getDescriptor(clientConfigDescriptorUuid)
                if (descriptor == null) {
                    if (!gatt.readCharacteristic(characteristic)) {
                        handshakeDeliveryResult?.error(
                            "handshake_read_failed",
                            "Failed to start handshake read.",
                            null,
                        )
                        handshakeDeliveryResult = null
                        gatt.close()
                    } else {
                        scheduleHandshakeWait(gatt)
                    }
                    return
                }
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                if (!gatt.writeDescriptor(descriptor)) {
                    if (!gatt.readCharacteristic(characteristic)) {
                        handshakeDeliveryResult?.error(
                            "handshake_notify_failed",
                            "Failed to enable handshake notifications.",
                            null,
                        )
                        handshakeDeliveryResult = null
                        gatt.close()
                    } else {
                        scheduleHandshakeWait(gatt)
                    }
                }
            }

            override fun onDescriptorWrite(
                gatt: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                if (descriptor.uuid != clientConfigDescriptorUuid) return
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    handshakeDeliveryResult?.error(
                        "handshake_notify_failed",
                        "Failed to subscribe to handshake notifications.",
                        null,
                    )
                    handshakeDeliveryResult = null
                    gatt.close()
                    return
                }
                val characteristic = gatt
                    .getService(serviceUuid)
                    ?.getCharacteristic(handshakeCharacteristicUuid)
                if (characteristic == null) {
                    handshakeDeliveryResult?.error(
                        "characteristic_missing",
                        "Handshake characteristic missing after notify.",
                        null,
                    )
                    handshakeDeliveryResult = null
                    gatt.close()
                    return
                }
                scheduleHandshakeWait(gatt)
                if (!gatt.readCharacteristic(characteristic)) {
                    Log.w("AirShareNative", "Initial handshake read not started; waiting for notify only.")
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
                    if (!handshakeDelivered) {
                        handshakeDeliveryResult?.error("handshake_failed", "Secure handshake read failed.", null)
                        handshakeDeliveryResult = null
                        cancelHandshakeWait()
                    }
                    gatt.close()
                    return
                }
                deliverGuestHandshake(gatt, value, "read")
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

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                if (characteristic.uuid != handshakeCharacteristicUuid) return
                deliverGuestHandshake(gatt, value, "notify")
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                onCharacteristicChanged(
                    gatt,
                    characteristic,
                    characteristic.value ?: ByteArray(0),
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

    private fun clearHotspotState() {
        hotspotActive = false
        pendingHotspotSsid = null
        pendingHotspotPassword = null
        pendingHotspotHubIp = ""
    }

    /**
     * LocalOnlyHotspot on Android 10+ ignores custom SSID/password — only system values are real.
     */
    private fun extractLocalOnlyHotspotCredentials(
        reservation: WifiManager.LocalOnlyHotspotReservation,
    ): Pair<String, String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val config: SoftApConfiguration = reservation.softApConfiguration
                val ssid = config.ssid?.let { wifiSsid ->
                    try {
                        wifiSsid.javaClass.getMethod("getUtf8Text").invoke(wifiSsid) as? String
                    } catch (_: Exception) {
                            wifiSsid.toString()
                        }
                }?.trim('"')?.trim().orEmpty().orEmpty()
                val password = config.passphrase?.toString()?.trim().orEmpty().orEmpty()
                if (ssid.isNotEmpty()) {
                    Log.i(
                        "AirShareNative",
                        "Hotspot credentials from softApConfiguration: ssid=$ssid pass_len=${password.length}",
                    )
                    return ssid to password
                }
            } catch (e: Exception) {
                Log.w("AirShareNative", "softApConfiguration read failed: ${e.message}")
            }
        }
        @Suppress("DEPRECATION")
        val wifiConfig = reservation.wifiConfiguration
        val ssid = wifiConfig?.SSID?.trim('"')?.trim().orEmpty().orEmpty()
        val password = wifiConfig?.preSharedKey?.trim('"')?.trim().orEmpty().orEmpty()
        Log.i(
            "AirShareNative",
            "Hotspot credentials from wifiConfiguration: ssid=$ssid pass_len=${password.length}",
        )
        return ssid to password
    }

    /// Tears down LocalOnlyHotspot (ap0) so the Wi‑Fi chip is clean for later LAN use.
    private fun stopNativeHotspot(result: MethodChannel.Result) {
        try {
            Log.i("AirShareNative", "stopNativeHotspot: releasing hotspot reservation")
            hubWlanRequestTimeoutRunnable?.let { hubWlanRequestHandler.removeCallbacks(it) }
            hubWlanRequestTimeoutRunnable = null
            val connectivityManager =
                getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            safeUnregisterHubWlanCallback(connectivityManager)
            try {
                connectivityManager.bindProcessToNetwork(null)
            } catch (e: Exception) {
                Log.w("AirShareNative", "stopNativeHotspot: bindProcessToNetwork(null): ${e.message}")
            }
            try {
                localHotspotReservation?.close()
            } catch (e: Exception) {
                Log.w("AirShareNative", "stopNativeHotspot: local reservation close: ${e.message}")
            }
            try {
                activeHotspotReservation?.close()
            } catch (e: Exception) {
                Log.w("AirShareNative", "stopNativeHotspot: active reservation close: ${e.message}")
            }
            localHotspotReservation = null
            activeHotspotReservation = null
            clearHotspotState()
            val p2pMgr = wifiP2pManager
            val p2pChan = wifiP2pChannel
            if (p2pMgr != null && p2pChan != null) {
                p2pMgr.removeGroup(p2pChan, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.i("AirShareNative", "stopNativeHotspot: P2P group removed")
                    }
                    override fun onFailure(reason: Int) {
                        Log.w("AirShareNative", "stopNativeHotspot: P2P removeGroup reason=$reason")
                    }
                })
            }
            wifiP2pManager = null
            wifiP2pChannel = null
            pendingP2pMac = ""
            Log.i("AirShareNative", "stopNativeHotspot: complete")
            result.success(null)
        } catch (e: Exception) {
            Log.e("AirShareNative", "stopNativeHotspot failed: ${e.message}", e)
            localHotspotReservation = null
            activeHotspotReservation = null
            clearHotspotState()
            result.error("hotspot_teardown_failed", e.message, null)
        }
    }

    private fun startTemporaryHotspot(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "LocalOnlyHotspot requires Android 8.0+.", null)
            return
        }
        val preConnectedLan = pendingLanIp.trim()
            .ifBlank { resolvePreConnectedHostLanIpv4().orEmpty() }
        if (preConnectedLan.isNotEmpty() && isPrivateLanIpv4(preConnectedLan)) {
            Log.i(
                "AirShareNative",
                "startTemporaryHotspot: skipped — pre-connected Tier 1 LAN $preConnectedLan (wlan0/ap0)",
            )
            result.success(
                mapOf(
                    "ssid" to "",
                    "password" to "",
                    "hubIp" to preConnectedLan,
                    "hotspotActive" to false,
                    "tier1PreConnected" to true,
                ),
            )
            return
        }
        if (activeHotspotReservation != null && hotspotActive) {
            Log.w("AirShareNative", "LocalOnlyHotspot already active")
            val ssid = pendingHotspotSsid.orEmpty()
            val password = pendingHotspotPassword.orEmpty()
            val hubIp = pendingHotspotHubIp.ifBlank { resolveLocalIpv4Address() }
            result.success(
                mapOf(
                    "ssid" to ssid,
                    "password" to password,
                    "hubIp" to hubIp,
                    "hotspotActive" to true,
                ),
            )
            return
        }
        clearHotspotState()
        val requestedPort = call.argument<Int>("hubPort") ?: pendingHubPort
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        try {
            wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                    activeHotspotReservation?.close()
                    localHotspotReservation = reservation
                    activeHotspotReservation = reservation
                    hotspotActive = true
                    handshakePayload = ByteArray(0)
                    handshakeCharacteristic?.value = null
                    val (systemSsid, systemPassword) = extractLocalOnlyHotspotCredentials(reservation)
                    if (systemSsid.isBlank()) {
                        Log.e(
                            "AirShareNative",
                            "LocalOnlyHotspot onStarted but system SSID is empty — cannot advertise to guest",
                        )
                        hotspotActive = false
                        activeHotspotReservation = null
                        localHotspotReservation = null
                        try {
                            reservation.close()
                        } catch (_: Exception) {}
                        result.error(
                            "hotspot_credentials_unavailable",
                            "Could not read system-generated hotspot SSID from reservation.",
                            null,
                        )
                        return
                    }
                    val hubIp = resolveHotspotHubIpv4Address()
                    logAllIpv4Interfaces("LocalOnlyHotspot.onStarted")
                    pendingHotspotSsid = systemSsid
                    pendingHotspotPassword = systemPassword
                    pendingHotspotHubIp = hubIp
                    pendingHubPort = requestedPort
                    if (pendingLanIp.isBlank() && pendingP2pIp.isBlank()) {
                        pendingHubIp = hubIp
                    }
                    val endpointIp = pendingLanIp.ifBlank {
                        pendingP2pIp.ifBlank { hubIp }
                    }
                    advertisedEndpoint = "$endpointIp:$pendingHubPort"
                    endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
                    Log.i(
                        "AirShareNative",
                        "LocalOnlyHotspot onStarted: system_ssid=$systemSsid hotspot_hub_ip=$hubIp lan_ip=$pendingLanIp (hotspotActive=true)",
                    )
                    result.success(
                        mapOf(
                            "ssid" to systemSsid,
                            "password" to systemPassword,
                            "hubIp" to hubIp,
                            "hotspotActive" to true,
                            "systemGenerated" to true,
                        ),
                    )
                }

                override fun onFailed(reason: Int) {
                    activeHotspotReservation = null
                    localHotspotReservation = null
                    clearHotspotState()
                    Log.e("AirShareNative", "LocalOnlyHotspot onFailed reason=$reason")
                    result.error("hotspot_failed", "Hotspot failed with reason=$reason", null)
                }
            }, null)
        } catch (se: SecurityException) {
            clearHotspotState()
            result.error("hotspot_permission", "Missing hotspot permission: ${se.message}", null)
        }
    }

    private fun safeUnregisterHubWlanCallback(connectivityManager: ConnectivityManager) {
        val callback = connectivityCallback
        if (callback == null) {
            connectivityCallbackRegistered = false
            return
        }
        if (!connectivityCallbackRegistered) {
            connectivityCallback = null
            return
        }
        try {
            connectivityManager.unregisterNetworkCallback(callback)
        } catch (e: IllegalArgumentException) {
            Log.w(
                "AirShareNative",
                "unregisterNetworkCallback ignored (not registered): ${e.message}",
            )
        }
        connectivityCallback = null
        connectivityCallbackRegistered = false
    }

    private fun connectToHubWlan(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.error("unsupported", "WLAN specifier requires Android 10+.", null)
                return
            }
            if (!isFineLocationGranted()) {
                Log.e(
                    "AirShareNative",
                    "connectToHubWlan: ACCESS_FINE_LOCATION not granted — " +
                        "WifiNetworkSpecifier dialog cannot appear.",
                )
                result.error(
                    "location_permission_denied",
                    "ACCESS_FINE_LOCATION must be granted before joining a Wi-Fi network.",
                    null,
                )
                return
            }
            if (!isLocationServicesEnabled()) {
                Log.e(
                    "AirShareNative",
                    "connectToHubWlan: location services disabled — " +
                        "WifiNetworkSpecifier dialog cannot appear.",
                )
                result.error(
                    "location_disabled",
                    "Location services (GPS) must be enabled to join a Wi-Fi network.",
                    null,
                )
                return
            }

            val ssid = call.argument<String>("ssid")?.trim()
            val password = call.argument<String>("password")
            if (ssid.isNullOrBlank() || password.isNullOrBlank()) {
                result.error("invalid_wlan_credentials", "SSID and password are required.", null)
                return
            }

            val connectivityManager =
                getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            safeUnregisterHubWlanCallback(connectivityManager)
            hubWlanRequestTimeoutRunnable?.let { hubWlanRequestHandler.removeCallbacks(it) }
            hubWlanRequestTimeoutRunnable = null

            val specifier = try {
                WifiNetworkSpecifier.Builder()
                    .setSsid(ssid)
                    .setWpa2Passphrase(password)
                    .build()
            } catch (e: Exception) {
                Log.e("AirShareNative", "connectToHubWlan: specifier build failed: ${e.message}", e)
                result.error(
                    "wlan_specifier_failed",
                    "Failed to build Wi-Fi network specifier: ${e.message}",
                    null,
                )
                return
            }

            val request = try {
                NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .setNetworkSpecifier(specifier)
                    .build()
            } catch (e: Exception) {
                Log.e("AirShareNative", "connectToHubWlan: NetworkRequest build failed: ${e.message}", e)
                result.error(
                    "wlan_request_build_failed",
                    "Failed to build network request: ${e.message}",
                    null,
                )
                return
            }

            var resultDelivered = false
            fun deliverSuccess() {
                if (resultDelivered) return
                resultDelivered = true
                hubWlanRequestTimeoutRunnable?.let { hubWlanRequestHandler.removeCallbacks(it) }
                hubWlanRequestTimeoutRunnable = null
                Log.i("AirShareNative", "connectToHubWlan: success for ssid=$ssid")
                result.success(null)
            }
            fun deliverError(code: String, message: String, throwable: Throwable? = null) {
                if (resultDelivered) return
                resultDelivered = true
                hubWlanRequestTimeoutRunnable?.let { hubWlanRequestHandler.removeCallbacks(it) }
                hubWlanRequestTimeoutRunnable = null
                safeUnregisterHubWlanCallback(connectivityManager)
                if (throwable != null) {
                    Log.e("AirShareNative", "connectToHubWlan: $code — $message", throwable)
                } else {
                    Log.e("AirShareNative", "connectToHubWlan: $code — $message")
                }
                result.error(code, message, null)
            }

            Log.i(
                "AirShareNative",
                "connectToHubWlan: requesting network for ssid='$ssid' " +
                    "(expect system Wi-Fi connection dialog)",
            )

            connectivityCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    try {
                        connectivityManager.bindProcessToNetwork(network)
                        Log.i(
                            "AirShareNative",
                            "connectToHubWlan: onAvailable — bound to hub hotspot ssid=$ssid",
                        )
                        deliverSuccess()
                    } catch (e: Exception) {
                        deliverError(
                            "wlan_bind_failed",
                            "Connected but failed to bind process to network: ${e.message}",
                            e,
                        )
                    }
                }

                override fun onUnavailable() {
                    deliverError(
                        "wlan_unavailable",
                        "System declined the Wi-Fi connection request for ssid=$ssid. " +
                            "User may have dismissed the dialog or credentials are wrong.",
                    )
                }

                override fun onLost(network: Network) {
                    Log.w("AirShareNative", "connectToHubWlan: onLost ssid=$ssid")
                }

                override fun onLosing(network: Network, maxMsToLive: Int) {
                    Log.w(
                        "AirShareNative",
                        "connectToHubWlan: onLosing ssid=$ssid maxMsToLive=$maxMsToLive",
                    )
                }
            }

            try {
                val mainHandler = Handler(Looper.getMainLooper())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    connectivityManager.requestNetwork(
                        request,
                        connectivityCallback!!,
                        mainHandler,
                        45_000,
                    )
                } else {
                    connectivityManager.requestNetwork(request, connectivityCallback!!)
                }
                connectivityCallbackRegistered = true
                hubWlanRequestTimeoutRunnable = Runnable {
                    deliverError(
                        "wlan_timeout",
                        "Timed out waiting for user to approve Wi-Fi connection to ssid=$ssid (45s).",
                    )
                }
                hubWlanRequestHandler.postDelayed(hubWlanRequestTimeoutRunnable!!, 45_000)
                Log.i(
                    "AirShareNative",
                    "connectToHubWlan: requestNetwork registered — awaiting user dialog / onAvailable",
                )
            } catch (e: SecurityException) {
                connectivityCallback = null
                connectivityCallbackRegistered = false
                deliverError(
                    "wlan_security_exception",
                    "SecurityException calling requestNetwork (check Location permission): ${e.message}",
                    e,
                )
            } catch (e: IllegalArgumentException) {
                connectivityCallback = null
                connectivityCallbackRegistered = false
                deliverError(
                    "wlan_request_invalid",
                    "IllegalArgumentException calling requestNetwork: ${e.message}",
                    e,
                )
            } catch (e: Exception) {
                connectivityCallback = null
                connectivityCallbackRegistered = false
                deliverError(
                    "wlan_request_failed",
                    "requestNetwork failed: ${e.message}",
                    e,
                )
            }
        } catch (e: Exception) {
            Log.e("AirShareNative", "connectToHubWlan: unexpected fatal error: ${e.message}", e)
            result.error(
                "wlan_connect_failed",
                "connectToHubWlan failed before requestNetwork: ${e.message}",
                null,
            )
        }
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
        handshakePayload = ByteArray(0)
        clearPendingRead()
        pendingHotspotSsid = null
        pendingHotspotPassword = null
        pendingHubIp = null
        pendingLanIp = ""
        pendingP2pIp = ""
        pendingHotspotHubIp = ""
        hotspotActive = false
        hubWlanRequestTimeoutRunnable?.let { hubWlanRequestHandler.removeCallbacks(it) }
        hubWlanRequestTimeoutRunnable = null
        cancelHandshakeWait()
        handshakeDeliveryResult = null
        handshakeDeliveryGatt = null
        handshakeDelivered = false
        activeGattClient?.close()
        activeGattClient = null
        stopNativeHotspot(MethodChannelResultProxy())
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        safeUnregisterHubWlanCallback(connectivityManager)
        try {
            connectivityManager.bindProcessToNetwork(null)
        } catch (_: Exception) {}
        val p2pMgr = wifiP2pManager
        val p2pChan = wifiP2pChannel
        if (p2pMgr != null && p2pChan != null) {
            p2pMgr.removeGroup(p2pChan, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {}
                override fun onFailure(reason: Int) {}
            })
        }
        wifiP2pManager = null
        wifiP2pChannel = null
        pendingP2pMac = ""
        cleanupGuestP2p()
        result.success(null)
    }

    private fun clearP2pTierState() {
        pendingP2pMac = ""
        pendingP2pIp = ""
    }

    private fun removeP2pGroupThen(
        mgr: WifiP2pManager?,
        chan: WifiP2pManager.Channel?,
        delayMs: Long,
        onComplete: () -> Unit,
    ) {
        if (mgr == null || chan == null) {
            clearP2pTierState()
            Handler(Looper.getMainLooper()).postDelayed({ onComplete() }, delayMs)
            return
        }
        mgr.removeGroup(chan, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.i("AirShareNative", "removeGroup success — waiting ${delayMs}ms for radio reset")
                clearP2pTierState()
                Handler(Looper.getMainLooper()).postDelayed({ onComplete() }, delayMs)
            }

            override fun onFailure(reason: Int) {
                Log.w("AirShareNative", "removeGroup failed reason=$reason — still waiting ${delayMs}ms")
                clearP2pTierState()
                Handler(Looper.getMainLooper()).postDelayed({ onComplete() }, delayMs)
            }
        })
    }

    private fun teardownP2pBeforeHotspot(result: MethodChannel.Result) {
        val mgr = wifiP2pManager
        val chan = wifiP2pChannel
        removeP2pGroupThen(mgr, chan, 500) {
            wifiP2pManager = null
            wifiP2pChannel = null
            result.success(null)
        }
    }

    private fun startWifiDirectGroupInternal(result: MethodChannel.Result) {
        val mgr = applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (mgr == null) {
            result.error("p2p_unavailable", "WifiP2pManager not available on this device", null)
            return
        }
        val chan = mgr.initialize(this, mainLooper, null)
        wifiP2pManager = mgr
        wifiP2pChannel = chan

        mgr.removeGroup(chan, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { doCreateP2pGroup(mgr, chan, result) }
            override fun onFailure(reason: Int) { doCreateP2pGroup(mgr, chan, result) }
        })
    }

    private fun isUsableP2pMac(mac: String?): Boolean {
        val normalized = mac?.trim()?.uppercase(Locale.US).orEmpty()
        if (normalized.isEmpty()) return false
        return normalized != "02:00:00:00:00:00" && normalized != "00:00:00:00:00:00"
    }

    // Real P2P MAC from WifiP2pGroup metadata only — never from NetworkInterface/BT adapter.
    private fun extractP2pGroupOwnerMac(group: WifiP2pGroup): String {
        val owner = group.owner
        if (owner != null && isUsableP2pMac(owner.deviceAddress)) {
            return owner.deviceAddress.trim()
        }
        for (client in group.clientList.orEmpty()) {
            if (client.isGroupOwner && isUsableP2pMac(client.deviceAddress)) {
                return client.deviceAddress.trim()
            }
        }
        return ""
    }

    private fun applyP2pGroupState(group: WifiP2pGroup, ownerMac: String) {
        val ownerIp = "192.168.49.1"
        pendingP2pIp = ownerIp
        pendingP2pMac = ownerMac
        if (pendingLanIp.isBlank()) {
            pendingHubIp = ownerIp
        }
        val endpointIp = pendingLanIp.ifBlank { ownerIp }
        advertisedEndpoint = "$endpointIp:$pendingHubPort"
        endpointCharacteristic?.value = advertisedEndpoint.toByteArray(StandardCharsets.UTF_8)
        Log.i(
            "AirShareNative",
            "WifiDirect group ready: network=${group.networkName} ownerIp=$ownerIp ownerMac=$ownerMac " +
                "isGO=${group.isGroupOwner} clients=${group.clientList?.size ?: 0}",
        )
    }

    private fun requestP2pGroupInfoWhenReady(
        mgr: WifiP2pManager,
        chan: WifiP2pManager.Channel,
        attempt: Int,
        maxAttempts: Int,
        result: MethodChannel.Result,
    ) {
        mgr.requestGroupInfo(chan, object : WifiP2pManager.GroupInfoListener {
            override fun onGroupInfoAvailable(group: WifiP2pGroup?) {
                if (group == null) {
                    Log.w(
                        "AirShareNative",
                        "onGroupInfoAvailable: group is null (attempt ${attempt + 1}/$maxAttempts)",
                    )
                    if (attempt + 1 < maxAttempts) {
                        Handler(Looper.getMainLooper()).postDelayed({
                            requestP2pGroupInfoWhenReady(mgr, chan, attempt + 1, maxAttempts, result)
                        }, 350L * (attempt + 1))
                    } else {
                        removeP2pGroupThen(mgr, chan, 500) {
                            wifiP2pManager = null
                            wifiP2pChannel = null
                            result.error(
                                "p2p_no_group",
                                "Group created but WifiP2pGroup metadata unavailable",
                                null,
                            )
                        }
                    }
                    return
                }

                val ownerMac = extractP2pGroupOwnerMac(group)
                if (!isUsableP2pMac(ownerMac)) {
                    val rawOwner = group.owner?.deviceAddress ?: "null"
                    Log.w(
                        "AirShareNative",
                        "onGroupInfoAvailable: owner MAC not ready '$rawOwner' " +
                            "(attempt ${attempt + 1}/$maxAttempts) — retrying",
                    )
                    if (attempt + 1 < maxAttempts) {
                        Handler(Looper.getMainLooper()).postDelayed({
                            requestP2pGroupInfoWhenReady(mgr, chan, attempt + 1, maxAttempts, result)
                        }, 400L * (attempt + 1))
                    } else {
                        removeP2pGroupThen(mgr, chan, 500) {
                            wifiP2pManager = null
                            wifiP2pChannel = null
                            result.error(
                                "p2p_mac_unavailable",
                                "Could not obtain valid P2P group owner MAC from WifiP2pGroup.owner",
                                null,
                            )
                        }
                    }
                    return
                }

                applyP2pGroupState(group, ownerMac)
                val ssid = group.networkName
                val psk = group.passphrase
                val ownerIp = pendingP2pIp
                result.success(
                    mapOf(
                        "ssid" to ssid,
                        "password" to psk,
                        "hubIp" to ownerIp,
                        "p2pMac" to ownerMac,
                    ),
                )
            }
        })
    }

    private fun doCreateP2pGroup(
        mgr: WifiP2pManager,
        chan: WifiP2pManager.Channel,
        result: MethodChannel.Result,
    ) {
        mgr.createGroup(chan, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.i("AirShareNative", "createGroup success — requesting WifiP2pGroup owner MAC")
                Handler(Looper.getMainLooper()).postDelayed({
                    requestP2pGroupInfoWhenReady(mgr, chan, 0, 10, result)
                }, 300)
            }

            override fun onFailure(reason: Int) {
                removeP2pGroupThen(mgr, chan, 500) {
                    wifiP2pManager = null
                    wifiP2pChannel = null
                    result.error("p2p_group_failed", "createGroup failed reason=$reason", null)
                }
            }
        })
    }

    private fun connectToWifiDirectPeerInternal(call: MethodCall, result: MethodChannel.Result) {
        val peerMac = call.argument<String>("peerMac")?.trim() ?: ""
        if (peerMac.isEmpty()) {
            result.error("invalid_mac", "peerMac is required", null)
            return
        }
        val mgr = applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (mgr == null) {
            result.error("p2p_unavailable", "WifiP2pManager not available", null)
            return
        }
        val chan = mgr.initialize(this, mainLooper, null)
        guestP2pManager = mgr
        guestP2pChannel = chan

        // Timeout: if the connection broadcast never arrives, fail cleanly after 30 s
        val timeoutRunnable = Runnable {
            cleanupGuestP2p()
            result.error("p2p_timeout", "Wi-Fi Direct connection timed out after 30s", null)
        }
        guestP2pTimeoutRunnable = timeoutRunnable
        guestP2pTimeoutHandler.postDelayed(timeoutRunnable, 30_000)

        val intentFilter = IntentFilter(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        var receiver: BroadcastReceiver? = null
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION) return
                @Suppress("DEPRECATION")
                val networkInfo: android.net.NetworkInfo? =
                    intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO)
                if (networkInfo?.isConnected != true) return
                mgr.requestConnectionInfo(chan) { info ->
                    val ownerIp = info?.groupOwnerAddress?.hostAddress
                        ?.takeIf { it.isNotEmpty() } ?: "192.168.49.1"
                    Log.i("AirShareNative", "WifiDirect peer connected, groupOwnerIp=$ownerIp")
                    guestP2pTimeoutHandler.removeCallbacks(timeoutRunnable)
                    guestP2pTimeoutRunnable = null
                    try { unregisterReceiver(receiver) } catch (_: Exception) {}
                    guestP2pReceiver = null
                    result.success(ownerIp)
                }
            }
        }
        guestP2pReceiver = receiver
        registerReceiver(receiver, intentFilter)

        val config = WifiP2pConfig().apply {
            deviceAddress = peerMac
            wps.setup = WpsInfo.PBC
            groupOwnerIntent = 0  // guest defers; host (group creator) stays owner
        }
        mgr.connect(chan, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.i("AirShareNative", "WifiDirect connect() initiated for $peerMac — waiting for broadcast")
            }
            override fun onFailure(reason: Int) {
                guestP2pTimeoutHandler.removeCallbacks(timeoutRunnable)
                guestP2pTimeoutRunnable = null
                cleanupGuestP2p()
                result.error("p2p_connect_failed", "connect() failed reason=$reason", null)
            }
        })
    }

    private fun cleanupGuestP2p() {
        guestP2pTimeoutRunnable?.let { guestP2pTimeoutHandler.removeCallbacks(it) }
        guestP2pTimeoutRunnable = null
        try { guestP2pReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
        guestP2pReceiver = null
        val mgr = guestP2pManager; val chan = guestP2pChannel
        if (mgr != null && chan != null) {
            mgr.removeGroup(chan, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {}
                override fun onFailure(reason: Int) {}
            })
        }
        guestP2pManager = null
        guestP2pChannel = null
    }

    private fun stopWifiDirectGroup(result: MethodChannel.Result) {
        val mgr  = wifiP2pManager
        val chan = wifiP2pChannel
        if (mgr != null && chan != null) {
            mgr.removeGroup(chan, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { result.success(null) }
                override fun onFailure(reason: Int) { result.success(null) }
            })
        } else {
            result.success(null)
        }
        wifiP2pManager = null
        wifiP2pChannel = null
    }

    private fun isExcludedVirtualInterface(ifaceName: String): Boolean {
        val l = ifaceName.lowercase(Locale.US)
        if (l.contains("p2p")) return true
        if (l.contains("rndis") || l.contains("usb")) return true
        if (l.contains("swlan")) return true
        return false
    }

    /** Manual / active hotspot AP (`ap0`, `ap1`, softap) — valid Tier 1 when already hosting. */
    private fun isHotspotAccessPointInterface(ifaceName: String): Boolean {
        val l = ifaceName.lowercase(Locale.US)
        if (l == "ap0" || l == "ap1") return true
        if (l.matches(Regex("^ap\\d+$"))) return true
        return l.contains("softap")
    }

    /** Station Wi‑Fi (`wlan0`, …) for shared LAN / home Wi‑Fi. */
    private fun isWlanStationInterface(ifaceName: String): Boolean {
        val l = ifaceName.lowercase(Locale.US)
        return l.contains("wlan") || l.contains("wifi")
    }

    private fun isPreConnectedHostInterface(ifaceName: String): Boolean {
        return isWlanStationInterface(ifaceName) || isHotspotAccessPointInterface(ifaceName)
    }

    private fun isHotspotHubInterface(ifaceName: String): Boolean =
        isHotspotAccessPointInterface(ifaceName)

    /// Best private IPv4 on wlan0 or ap0/ap1 (pre-connected Tier 1 — no LocalOnlyHotspot).
    private fun resolvePreConnectedHostLanIpv4(): String? {
        return try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            var best: Pair<String, Int>? = null
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback || isExcludedVirtualInterface(iface.name)) continue
                if (!isPreConnectedHostInterface(iface.name)) continue
                for (address in Collections.list(iface.inetAddresses)) {
                    if (address !is Inet4Address || address.isLoopbackAddress) continue
                    val ip = address.hostAddress?.trim().orEmpty()
                    if (ip.isEmpty() || !isPrivateLanIpv4(ip)) continue
                    val score = when {
                        iface.name.equals("wlan0", ignoreCase = true) -> 60
                        isWlanStationInterface(iface.name) -> 40
                        isHotspotAccessPointInterface(iface.name) -> 30
                        else -> 10
                    }
                    if (best == null || score > best!!.second) {
                        best = ip to score
                        Log.i(
                            "AirShareNative",
                            "resolvePreConnectedHostLanIpv4: candidate $ip on ${iface.name} score=$score",
                        )
                    }
                }
            }
            best?.first
        } catch (e: Exception) {
            Log.w("AirShareNative", "resolvePreConnectedHostLanIpv4 failed: ${e.message}")
            null
        }
    }

    private fun logAllIpv4Interfaces(reason: String) {
        try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            for (iface in interfaces) {
                for (address in Collections.list(iface.inetAddresses)) {
                    if (address is Inet4Address) {
                        Log.i(
                            "AirShareNative",
                            "IPv4 interface [$reason]: ${iface.name} up=${iface.isUp} loopback=${iface.isLoopback} addr=${address.hostAddress}",
                        )
                    }
                }
            }
        } catch (e: Exception) {
            Log.w("AirShareNative", "IPv4 interface dump failed [$reason]: ${e.message}")
        }
    }

    /// Hub IP on LocalOnlyHotspot (ap0) after [hotspotActive], else pre-connected LAN.
    private fun resolveHotspotHubIpv4Address(): String {
        resolvePreConnectedHostLanIpv4()?.let { return it }
        return try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback || !isHotspotHubInterface(iface.name)) continue
                for (address in Collections.list(iface.inetAddresses)) {
                    if (address is Inet4Address && !address.isLoopbackAddress) {
                        val ip = address.hostAddress ?: continue
                        if (!isPrivateLanIpv4(ip)) continue
                        Log.i("AirShareNative", "Hotspot hub IP from ${iface.name}: $ip")
                        return ip
                    }
                }
            }
            "192.168.43.1"
        } catch (_: Exception) {
            "192.168.43.1"
        }
    }

    private fun resolveLocalIpv4Address(): String =
        resolvePreConnectedHostLanIpv4() ?: resolveHotspotHubIpv4Address()

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
