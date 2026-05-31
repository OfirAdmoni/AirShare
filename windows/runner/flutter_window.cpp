#include "flutter_window.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cctype>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <optional>
#include <sstream>
#include <thread>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kAirSharePlatformTaskMsg = WM_APP + 0x7800;
void TrimAsciiWhitespace(std::string& s) {
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) {
    s.pop_back();
  }
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) {
    s.erase(s.begin());
  }
}

std::string GetHostComputerNameUtf8() {
  wchar_t buf[MAX_COMPUTERNAME_LENGTH + 1] = {};
  DWORD n = static_cast<DWORD>(MAX_COMPUTERNAME_LENGTH + 1);
  if (!GetComputerNameW(buf, &n) || n == 0) {
    return {};
  }
  buf[n] = L'\0';
  const int required =
      WideCharToMultiByte(CP_UTF8, 0, buf, -1, nullptr, 0, nullptr, nullptr);
  if (required <= 1) {
    return {};
  }
  std::string out(static_cast<size_t>(required - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, buf, -1, out.data(), required, nullptr,
                      nullptr);
  return out;
}

constexpr char kBleTransportChannel[] = "air_share/ble_transport";
constexpr char kBleScanEventsChannel[] = "air_share/ble_scan_events";
constexpr char kBleUiChannel[] = "air_share/ble_ui";
constexpr char kWlanLinkChannel[] = "air_share/wlan_link";
constexpr wchar_t kAirShareServiceUuid[] = L"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr wchar_t kHandshakeUuid[] = L"6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr wchar_t kEndpointUuid[] = L"6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher
    g_watcher{nullptr};
}  // namespace

void FlutterWindow::DispatchToPlatformThread(
    std::unique_ptr<AirSharePlatformTask> task) {
  if (!task) {
    return;
  }
  HWND hwnd = GetHandle();
  if (!hwnd) {
    task->Run();
    return;
  }
  AirSharePlatformTask* raw = task.release();
  if (!PostMessageW(hwnd, kAirSharePlatformTaskMsg, 0,
                    reinterpret_cast<LPARAM>(raw))) {
    std::unique_ptr<AirSharePlatformTask> fail(raw);
    fail->Run();
  }
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  InitializeNativeChannels();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (ble_scanning_active_) {
    if (g_watcher) {
      g_watcher.Stop();
    }
    ble_scanning_active_ = false;
  }
  {
    std::lock_guard<std::mutex> lock(approval_mutex_);
    ClearPendingReadState();
  }
  CancelApprovalTimeout();
  if (gatt_provider_) {
    gatt_provider_.StopAdvertising();
    gatt_provider_ = nullptr;
  }
  gatt_handshake_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kAirSharePlatformTaskMsg) {
    std::unique_ptr<AirSharePlatformTask> task(
        reinterpret_cast<AirSharePlatformTask*>(lparam));
    if (task) {
      task->Run();
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::InitializeNativeChannels() {
  const std::wstring uuid_log =
      L"[AirShareNative] Native | UUID Verify | Service: " +
      std::wstring(kAirShareServiceUuid) + L" | Characteristic: " +
      std::wstring(kHandshakeUuid) + L"\n";
  OutputDebugStringW(uuid_log.c_str());
  auto messenger = flutter_controller_->engine()->messenger();
  auto codec = &flutter::StandardMethodCodec::GetInstance();

  ble_method_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(messenger,
                                                       kBleTransportChannel,
                                                       codec);
  ble_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "startScanning") {
          StartBleScanning(result.get());
          return;
        }
        if (call.method_name() == "stopScanning") {
          StopBleScanning(result.get());
          return;
        }
        if (call.method_name() == "establishSecureHandshake") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args",
                          "Secure handshake arguments are missing.");
            return;
          }
          EstablishSecureHandshake(*args, std::move(result));
          return;
        }
        if (call.method_name() == "readPeerEndpoint") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args", "Endpoint read arguments are missing.");
            return;
          }
          ReadPeerEndpoint(*args, std::move(result));
          return;
        }
        if (call.method_name() == "startHubAdvertising") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          StartHubAdvertising(args, result.get());
          return;
        }
        if (call.method_name() == "stopHubAdvertising") {
          StopHubAdvertising(result.get());
          return;
        }
        if (call.method_name() == "approveConnection") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args", "Approval arguments are missing.");
            return;
          }
          ApproveConnection(*args, result.get());
          return;
        }
        if (call.method_name() == "updateHubEndpoint") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args", "Endpoint update arguments are missing.");
            return;
          }
          UpdateHubEndpoint(*args, result.get());
          return;
        }
        if (call.method_name() == "updateConnectionEndpoints") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args",
                          "Connection endpoint arguments are missing.");
            return;
          }
          UpdateConnectionEndpoints(*args, result.get());
          return;
        }
        if (call.method_name() == "resetHostHandshakeState") {
          ResetHostHandshakeState(result.get());
          return;
        }
        if (call.method_name() == "resetGuestHandshakeState") {
          ResetGuestHandshakeState(result.get());
          return;
        }
        if (call.method_name() == "waitForSessionHandshake") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args",
                          "Session handshake wait arguments are missing.");
            return;
          }
          WaitForSessionHandshake(*args, std::move(result));
          return;
        }
        if (call.method_name() == "getLocalPeerId") {
          GetLocalPeerId(std::move(result));
          return;
        }
        if (call.method_name() == "isBluetoothEnabled") {
          IsBluetoothEnabled(std::move(result));
          return;
        }
        result->NotImplemented();
      });

  ble_ui_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(messenger, kBleUiChannel,
                                                       codec);

  wlan_method_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(messenger,
                                                       kWlanLinkChannel,
                                                       codec);
  wlan_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "connectToHubWlan") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("invalid_args", "WLAN arguments are missing.");
            return;
          }
          ConnectToHubWlan(*args, result.get());
          return;
        }
        if (call.method_name() == "startTemporaryHotspot") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          pending_ssid_ = "AirShareLink";
          pending_password_ = "AirShare@2026";
          pending_hub_ip_ = "192.168.137.1";
          pending_hub_port_ = 8080;
          if (args) {
            const auto it = args->find(flutter::EncodableValue("hubPort"));
            if (it != args->end()) {
              if (const auto p = std::get_if<int>(&it->second)) {
                pending_hub_port_ = *p;
              } else if (const auto p64 = std::get_if<int64_t>(&it->second)) {
                pending_hub_port_ = static_cast<int>(*p64);
              }
            }
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("ssid"),
               flutter::EncodableValue(pending_ssid_)},
              {flutter::EncodableValue("password"),
               flutter::EncodableValue(pending_password_)},
              {flutter::EncodableValue("hubIp"),
               flutter::EncodableValue(pending_hub_ip_)},
          }));
          return;
        }
        if (call.method_name() == "stopInternalLink") {
          StopInternalLink(result.get());
          return;
        }
        result->NotImplemented();
      });

  ble_scan_event_channel_ = std::make_unique<
      flutter::EventChannel<flutter::EncodableValue>>(messenger,
                                                      kBleScanEventsChannel,
                                                      codec);
  ble_scan_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events) {
            ble_scan_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*) {
            ble_scan_sink_.reset();
            return nullptr;
          }));
}

void FlutterWindow::IsBluetoothEnabled(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  using namespace winrt::Windows::Devices::Bluetooth;
  using namespace winrt::Windows::Devices::Radios;
  try {
    auto adapter = BluetoothAdapter::GetDefaultAsync().get();
    if (!adapter) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    auto radio = adapter.GetRadioAsync().get();
    result->Success(
        flutter::EncodableValue(radio.State() == RadioState::On));
  } catch (...) {
    result->Success(flutter::EncodableValue(false));
  }
}

void FlutterWindow::GetLocalPeerId(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  using namespace winrt::Windows::Devices::Bluetooth;
  try {
    auto adapter = BluetoothAdapter::GetDefaultAsync().get();
    if (!adapter) {
      result->Error("no_adapter", "Bluetooth adapter unavailable.");
      return;
    }
    std::stringstream id_stream;
    id_stream << adapter.BluetoothAddress();
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("peerId")] =
        flutter::EncodableValue(id_stream.str());
    result->Success(flutter::EncodableValue(payload));
  } catch (const winrt::hresult_error& e) {
    result->Error("local_peer_failed", WinrtStringToUtf8(e.message()));
  } catch (...) {
    result->Error("local_peer_failed", "Unable to resolve local peer id.");
  }
}

void FlutterWindow::StartBleScanning(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  using namespace winrt::Windows::Devices::Bluetooth::Advertisement;

  try {
    discovered_peers_.clear();
    g_watcher = BluetoothLEAdvertisementWatcher();
    g_watcher.ScanningMode(BluetoothLEScanningMode::Active);

    watcher_received_token_ = g_watcher.Received([this](
                                                     auto&&,
                                                     const BluetoothLEAdvertisementReceivedEventArgs&
                                                         args) {
      std::vector<winrt::guid> uuids;
      for (const auto& uuid : args.Advertisement().ServiceUuids()) {
        uuids.push_back(uuid);
      }
      if (!IsAirShareService(uuids)) {
        return;
      }
      const auto bt_addr = args.BluetoothAddress();
      std::stringstream id_stream;
      id_stream << bt_addr;
      const std::string peer_id = id_stream.str();
      const std::string friendly_name =
          WinrtStringToUtf8(args.Advertisement().LocalName());
      discovered_peers_[bt_addr] = {
          peer_id, friendly_name.empty() ? "Nearby peer" : friendly_name};
      PublishDiscoveredPeers();
    });

    watcher_stopped_token_ = g_watcher.Stopped(
        [](auto&&, const BluetoothLEAdvertisementWatcherStoppedEventArgs& args) {
          OutputDebugStringW(
              (L"[AirShareNative] BLE watcher stopped. Error=" +
               std::to_wstring(static_cast<int>(args.Error())) + L"\n")
                  .c_str());
        });

    g_watcher.Start();
    ble_scanning_active_ = true;
    OutputDebugStringW(L"[AirShareNative] Peer Discovery via BLE started.\n");
    result->Success(flutter::EncodableValue());
  } catch (const winrt::hresult_error& e) {
    std::wstring msg =
        L"[AirShareNative] BLE scan start failed: " + std::wstring(e.message().c_str());
    OutputDebugStringW((msg + L"\n").c_str());
    result->Error("ble_scan_start_failed", WinrtStringToUtf8(e.message()));
  }
}

void FlutterWindow::StopBleScanning(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  ClearGuestHandshakeSession();
  try {
    if (g_watcher) {
      if (watcher_received_token_) {
        g_watcher.Received(*watcher_received_token_);
      }
      if (watcher_stopped_token_) {
        g_watcher.Stopped(*watcher_stopped_token_);
      }
      g_watcher.Stop();
    }
    watcher_received_token_.reset();
    watcher_stopped_token_.reset();
    ble_scanning_active_ = false;
    OutputDebugStringW(L"[AirShareNative] Peer Discovery via BLE stopped.\n");
    result->Success(flutter::EncodableValue());
  } catch (const winrt::hresult_error& e) {
    result->Error("ble_scan_stop_failed", WinrtStringToUtf8(e.message()));
  }
}

void FlutterWindow::EstablishSecureHandshake(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  using namespace winrt::Windows::Devices::Bluetooth;
  using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;

  const auto peer_id_it = args.find(flutter::EncodableValue("peerId"));
  if (peer_id_it == args.end()) {
    result->Error("invalid_peer", "Peer id is required.");
    return;
  }
  const auto args_copy = args;
  std::thread([this, args_copy, result = std::move(result)]() mutable {
    BluetoothLEDevice ble_device{nullptr};
    try {
      const auto peer_id_it = args_copy.find(flutter::EncodableValue("peerId"));
      const auto peer_id = std::get<std::string>(peer_id_it->second);
      const uint64_t bt_address = _strtoui64(peer_id.c_str(), nullptr, 10);
      ble_device = BluetoothLEDevice::FromBluetoothAddressAsync(bt_address).get();
      if (!ble_device) {
        DispatchToPlatformThread([result = std::move(result)]() mutable {
          result->Error("peer_not_found", "Unable to open BLE peer.");
        });
        return;
      }
      std::wstring peer_w(peer_id.begin(), peer_id.end());
      const std::wstring discovery_msg =
          L"[AirShareNative] Native | BLE | Starting Service Discovery for " +
          peer_w + L"\n";
      OutputDebugStringW(discovery_msg.c_str());

    auto service_uuid = winrt::guid(kAirShareServiceUuid);
    GattDeviceServicesResult services_result{nullptr};
    bool service_available = false;
    for (int attempt = 1; attempt <= 3; ++attempt) {
      services_result = ble_device.GetGattServicesForUuidAsync(service_uuid).get();
      if (services_result.Status() == GattCommunicationStatus::Success &&
          services_result.Services().Size() > 0) {
        service_available = true;
        break;
      }
      std::wstring msg = L"[AirShareNative] Handshake service not ready (attempt " +
                         std::to_wstring(attempt) + L"/3)\n";
      OutputDebugStringW(msg.c_str());
      if (attempt < 3) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
      }
    }
    if (!service_available) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("service_missing", "AirShare service not available.");
      });
      return;
    }

    auto handshake_uuid = winrt::guid(kHandshakeUuid);
    auto chars_result = services_result.Services().GetAt(0)
                            .GetCharacteristicsForUuidAsync(handshake_uuid)
                            .get();
    if (chars_result.Status() != GattCommunicationStatus::Success ||
        chars_result.Characteristics().Size() == 0) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("handshake_characteristic_missing",
                      "Handshake characteristic missing.");
      });
      return;
    }

    ClearGuestHandshakeSession();
    auto handshake_char = chars_result.Characteristics().GetAt(0);

    std::string guest_public_key;
    const auto guest_pk_it =
        args_copy.find(flutter::EncodableValue("guestPublicKey"));
    if (guest_pk_it != args_copy.end()) {
      if (const auto* s = std::get_if<std::string>(&guest_pk_it->second)) {
        guest_public_key = *s;
      }
    }
    if (guest_public_key.empty()) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("invalid_guest_key", "guestPublicKey is required.");
      });
      return;
    }
    try {
      const std::string guest_json =
          "{\"guest_public_key\":\"" + guest_public_key + "\"}";
      winrt::Windows::Storage::Streams::DataWriter writer;
      writer.WriteString(winrt::to_hstring(guest_json));
      const auto write_buffer = writer.DetachBuffer();
      const auto write_status = handshake_char
                                    .WriteValueAsync(write_buffer,
                                                     GattWriteOption::WriteWithResponse)
                                    .get();
      if (write_status != GattCommunicationStatus::Success) {
        try {
          ble_device.Close();
        } catch (...) {
        }
        DispatchToPlatformThread([result = std::move(result)]() mutable {
          result->Error("guest_key_write_failed",
                        "Failed to write guest_public_key to host.");
        });
        return;
      }
      OutputDebugStringW(
          L"[AirShareNative] Native | guest_public_key written before handshake read.\n");
    } catch (const winrt::hresult_error& e) {
      const std::string err_msg = WinrtStringToUtf8(e.message());
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result), err_msg]() mutable {
        result->Error("guest_key_write_failed", err_msg);
      });
      return;
    }

    std::string json;
    bool has_infrastructure = false;
    bool keep_guest_connection = false;
    for (int attempt = 1; attempt <= 15; ++attempt) {
      GattReadResult read_result{nullptr};
      try {
        read_result =
            handshake_char.ReadValueAsync(BluetoothCacheMode::Uncached).get();
      } catch (const winrt::hresult_error& e) {
        const std::wstring msg = L"[AirShareNative] Native | Handshake read attempt " +
                                 std::to_wstring(attempt) +
                                 L"... Status: Fail (" + e.message().c_str() + L")\n";
        OutputDebugStringW(msg.c_str());
        if (attempt < 15) {
          std::this_thread::sleep_for(std::chrono::seconds(2));
          continue;
        }
        try {
          ble_device.Close();
        } catch (...) {
        }
        DispatchToPlatformThread([result = std::move(result)]() mutable {
          result->Error("handshake_read_failed", "Unable to read handshake payload.");
        });
        return;
      }
      if (read_result.Status() != GattCommunicationStatus::Success) {
        const std::wstring msg = L"[AirShareNative] Native | Handshake read attempt " +
                                 std::to_wstring(attempt) + L"... Status: Fail\n";
        OutputDebugStringW(msg.c_str());
        if (attempt < 15) {
          std::this_thread::sleep_for(std::chrono::seconds(2));
          continue;
        }
        try {
          ble_device.Close();
        } catch (...) {
        }
        DispatchToPlatformThread([result = std::move(result)]() mutable {
          result->Error("handshake_read_failed", "Unable to read handshake payload.");
        });
        return;
      }

      auto buffer = read_result.Value();
      winrt::Windows::Storage::Streams::DataReader reader =
          winrt::Windows::Storage::Streams::DataReader::FromBuffer(buffer);
      const uint32_t len = reader.UnconsumedBufferLength();
      if (len == 0) {
        if (attempt < 15) {
          std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        continue;
      }
      std::vector<uint8_t> bytes(len);
      reader.ReadBytes(bytes);
      json.assign(reinterpret_cast<const char*>(bytes.data()), bytes.size());
      if (!JsonHasInfrastructure(json)) {
        if (attempt < 15) {
          std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        continue;
      }
      has_infrastructure = true;
      auto extract = [](const std::string& key, const std::string& src) {
        const std::string needle = "\"" + key + "\":\"";
        auto start = src.find(needle);
        if (start == std::string::npos) return std::string();
        start += needle.size();
        auto end = src.find('"', start);
        if (end == std::string::npos) return std::string();
        return src.substr(start, end - start);
      };
      if (!extract("host_public_key", json).empty()) {
        OutputDebugStringW(
            L"[AirShareNative] Native | Handshake read complete (session keys present).\n");
        break;
      }
      OutputDebugStringW(
          L"[AirShareNative] Native | Handshake infrastructure read; "
          L"session keys pending host Approve.\n");
      {
        std::lock_guard<std::mutex> lock(guest_handshake_mutex_);
        guest_handshake_device_ = ble_device;
        guest_handshake_char_ = handshake_char;
        keep_guest_connection = true;
        guest_session_received_ = false;
        guest_session_notify_json_.clear();
      }
      EnableGuestHandshakeNotifications(handshake_char);
      break;
    }
    if (!has_infrastructure) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("handshake_read_failed",
                      "Host handshake endpoints are not available yet.");
      });
      return;
    }
    const auto payload = ParseHandshakeJsonToMap(json);
    if (!keep_guest_connection) {
      OutputDebugStringW(
          L"[AirShareNative] Peer Handshake complete; closing BLE peripheral.\n");
      try {
        ble_device.Close();
      } catch (...) {
      }
    } else {
      OutputDebugStringW(
          L"[AirShareNative] Peer Handshake partial; keeping BLE open for session keys.\n");
    }
    DispatchToPlatformThread(
        [result = std::move(result), payload = std::move(payload)]() mutable {
          result->Success(flutter::EncodableValue(payload));
        });
    } catch (const winrt::hresult_error& e) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      const std::string err = WinrtStringToUtf8(e.message());
      DispatchToPlatformThread([result = std::move(result), err]() mutable {
        result->Error("handshake_error", err);
      });
    }
  }).detach();
}

void FlutterWindow::ReadPeerEndpoint(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  using namespace winrt::Windows::Devices::Bluetooth;
  using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;

  const auto peer_id_it = args.find(flutter::EncodableValue("peerId"));
  if (peer_id_it == args.end()) {
    result->Error("invalid_peer", "Peer id is required.");
    return;
  }
  const auto args_copy = args;
  std::thread([this, args_copy, result = std::move(result)]() mutable {
    BluetoothLEDevice ble_device{nullptr};
    try {
      const auto peer_id_it = args_copy.find(flutter::EncodableValue("peerId"));
      const auto peer_id = std::get<std::string>(peer_id_it->second);
      const uint64_t bt_address = _strtoui64(peer_id.c_str(), nullptr, 10);
      ble_device = BluetoothLEDevice::FromBluetoothAddressAsync(bt_address).get();
      if (!ble_device) {
        DispatchToPlatformThread([result = std::move(result)]() mutable {
          result->Error("peer_not_found", "Unable to open BLE peer.");
        });
        return;
      }

    auto service_uuid = winrt::guid(kAirShareServiceUuid);
    auto services_result = ble_device.GetGattServicesForUuidAsync(service_uuid).get();
    if (services_result.Status() != GattCommunicationStatus::Success ||
        services_result.Services().Size() == 0) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("service_missing", "AirShare service not available.");
      });
      return;
    }

    auto endpoint_uuid = winrt::guid(kEndpointUuid);
    auto chars_result = services_result.Services().GetAt(0)
                            .GetCharacteristicsForUuidAsync(endpoint_uuid)
                            .get();
    if (chars_result.Status() != GattCommunicationStatus::Success ||
        chars_result.Characteristics().Size() == 0) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("endpoint_characteristic_missing",
                      "Endpoint characteristic missing.");
      });
      return;
    }

    auto read_result = chars_result.Characteristics().GetAt(0).ReadValueAsync().get();
    if (read_result.Status() != GattCommunicationStatus::Success) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("endpoint_read_failed", "Unable to read endpoint payload.");
      });
      return;
    }
    auto buffer = read_result.Value();
    winrt::Windows::Storage::Streams::DataReader reader =
        winrt::Windows::Storage::Streams::DataReader::FromBuffer(buffer);
    const uint32_t len = reader.UnconsumedBufferLength();
    std::vector<uint8_t> bytes(len);
    if (len > 0) {
      reader.ReadBytes(bytes);
    }
    const std::string endpoint(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    const auto colon = endpoint.find(':');
    if (colon == std::string::npos) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("invalid_endpoint_payload", "Endpoint payload malformed.");
      });
      return;
    }
    const std::string ip = endpoint.substr(0, colon);
    const std::string port_s = endpoint.substr(colon + 1);
    int port = 0;
    try {
      port = std::stoi(port_s);
    } catch (...) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("invalid_endpoint_payload", "Endpoint payload malformed.");
      });
      return;
    }
    try {
      ble_device.Close();
    } catch (...) {
    }
    DispatchToPlatformThread(
        [result = std::move(result), ip, port]() mutable {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("ip"), flutter::EncodableValue(ip)},
              {flutter::EncodableValue("port"), flutter::EncodableValue(port)},
          }));
        });
    } catch (const winrt::hresult_error& e) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      const std::string err = WinrtStringToUtf8(e.message());
      DispatchToPlatformThread([result = std::move(result), err]() mutable {
        result->Error("endpoint_error", err);
      });
    }
  }).detach();
}

void FlutterWindow::StartHubAdvertising(
    const flutter::EncodableMap* args,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  using namespace winrt::Windows::Devices::Bluetooth;
  using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
  try {
    if (gatt_provider_) {
      result->Success(flutter::EncodableValue());
      return;
    }
    auto async = GattServiceProvider::CreateAsync(winrt::guid(kAirShareServiceUuid));
    auto provider_result = async.get();
    if (provider_result.Error() != BluetoothError::Success) {
      result->Error("gatt_provider_failed", "Unable to create GATT service provider.");
      return;
    }
    gatt_provider_ = provider_result.ServiceProvider();

    GattLocalCharacteristicParameters params;
    params.CharacteristicProperties(GattCharacteristicProperties::Read |
                                    GattCharacteristicProperties::Notify |
                                    GattCharacteristicProperties::Write);
    params.WriteProtectionLevel(GattProtectionLevel::Plain);
    params.UserDescription(L"Secure handshake payload");

    auto char_result =
        gatt_provider_.Service()
            .CreateCharacteristicAsync(winrt::guid(kHandshakeUuid), params)
            .get();
    if (char_result.Error() != BluetoothError::Success) {
      result->Error("gatt_characteristic_failed",
                    "Unable to create handshake characteristic.");
      return;
    }
    gatt_handshake_ = char_result.Characteristic();

    GattLocalCharacteristicParameters endpoint_params;
    endpoint_params.CharacteristicProperties(GattCharacteristicProperties::Read |
                                             GattCharacteristicProperties::Write);
    endpoint_params.UserDescription(L"Hub endpoint");
    auto endpoint_result =
        gatt_provider_.Service()
            .CreateCharacteristicAsync(winrt::guid(kEndpointUuid), endpoint_params)
            .get();
    if (endpoint_result.Error() != BluetoothError::Success) {
      result->Error("gatt_characteristic_failed",
                    "Unable to create endpoint characteristic.");
      return;
    }
    gatt_endpoint_ = endpoint_result.Characteristic();
    endpoint_read_token_ = gatt_endpoint_.ReadRequested(
        [this](GattLocalCharacteristic const&, GattReadRequestedEventArgs args) {
          auto deferral = args.GetDeferral();
          try {
            auto request = args.GetRequestAsync().get();
            request.RespondWithValue(BuildEndpointBuffer());
          } catch (...) {
          }
          deferral.Complete();
        });

    handshake_write_token_ = gatt_handshake_.WriteRequested(
        [this](GattLocalCharacteristic const&,
               GattWriteRequestedEventArgs args) {
          auto deferral = args.GetDeferral();
          try {
            auto request = args.GetRequestAsync().get();
            const std::string transport_id =
                WinrtStringToUtf8(args.Session().DeviceId().Id());
            const auto guest_pk =
                ParseGuestPublicKeyFromWriteBuffer(request.Value());
            if (!guest_pk.empty()) {
              RegisterGuestSession(transport_id, guest_pk);
            }
            request.Respond();
          } catch (...) {
          }
          deferral.Complete();
        });

    handshake_read_token_ = gatt_handshake_.ReadRequested(
        [this](GattLocalCharacteristic const&,
               GattReadRequestedEventArgs args) {
          auto deferral = args.GetDeferral();
          try {
            auto request = args.GetRequestAsync().get();
            if (HandshakeBufferHasInfrastructure()) {
              const std::string transport_id =
                  WinrtStringToUtf8(args.Session().DeviceId().Id());
              const std::string session_key = ResolveSessionKey(transport_id);
              const auto buffer = BuildHandshakeBufferForPeer(session_key);
              request.RespondWithValue(buffer);
              deferral.Complete();
              if (!session_key.empty() &&
                  approved_peer_host_keys_.find(session_key) ==
                      approved_peer_host_keys_.end()) {
                std::lock_guard<std::mutex> lock(approval_mutex_);
                pending_gatt_session_ = args.Session();
                pending_session_id_ = session_key;
                NotifyFlutterConnectionRequest("BLE Peer", session_key);
                ScheduleApprovalTimeout();
              }
              return;
            }
            std::string session_id;
            {
              std::lock_guard<std::mutex> lock(approval_mutex_);
              if (pending_read_request_) {
                try {
                  request.RespondWithValue(nullptr);
                } catch (...) {
                }
                deferral.Complete();
                return;
              }

              pending_read_deferral_ =
                  deferral.as<winrt::Windows::Foundation::IDeferral>();
              pending_read_request_ = request;
              pending_gatt_session_ = args.Session();
              pending_session_id_ =
                  WinrtStringToUtf8(args.Session().DeviceId().Id());
              session_id = pending_session_id_;
            }
            OutputDebugStringW(
                L"[AirShareNative] Peer Handshake Blocked - Waiting for UI Approval\n");
            NotifyFlutterConnectionRequest("BLE Peer", session_id);
            ScheduleApprovalTimeout();
            return;
          } catch (...) {
            deferral.Complete();
          }
        });

    constexpr int kBleAdvPduMax = 31;
    constexpr int kPrimaryFlagsAnd128UuidEstimate = 3 + 18;
    static_assert(kPrimaryFlagsAnd128UuidEstimate <= 31,
                  "primary advertisement flags + 128-bit UUID must fit legacy 31-byte PDU");
    try {
      std::string friendly_u8;
      if (args) {
        const auto it = args->find(flutter::EncodableValue("friendlyName"));
        if (it != args->end()) {
          try {
            friendly_u8 = std::get<std::string>(it->second);
          } catch (...) {
          }
        }
      }
      TrimAsciiWhitespace(friendly_u8);
      if (friendly_u8.empty()) {
        friendly_u8 = GetHostComputerNameUtf8();
        TrimAsciiWhitespace(friendly_u8);
      }
      if (friendly_u8.empty()) {
        friendly_u8 = "Windows";
      }
      winrt::hstring h_label = winrt::to_hstring(friendly_u8);
      std::wstring wname(h_label.c_str());
      if (wname.size() > 10) {
        wname.resize(10);
      }
      while (wname.size() > 1) {
        const std::string u8 =
            WinrtStringToUtf8(winrt::hstring(wname.c_str()));
        const int scan_est = static_cast<int>(2 + u8.size());
        if (scan_est <= kBleAdvPduMax) {
          break;
        }
        wname.pop_back();
      }
      const std::string u8_final =
          wname.empty() ? std::string()
                        : WinrtStringToUtf8(winrt::hstring(wname.c_str()));
      const int scan_ad_estimate =
          u8_final.empty() ? 0 : static_cast<int>(2 + u8_final.size());
      if (scan_ad_estimate > kBleAdvPduMax) {
        OutputDebugStringW(
            L"[AirShareNative] BLE scan-response name still too large; refusing StartAdvertising.\n");
        StopHubAdvertisingInternal();
        result->Error("ble_adv_oversize",
                      "BLE scan response would exceed 31 bytes; shorten the device name.");
        return;
      }
      const std::wstring wlog =
          L"[AirShareNative] BLE adv verify: primary~" +
          std::to_wstring(kPrimaryFlagsAnd128UuidEstimate) + L"B (flags+service UUID), scan~" +
          std::to_wstring(scan_ad_estimate) + L"B (Flutter/local name, truncated for PDU), max PDU=" +
          std::to_wstring(kBleAdvPduMax) + L"\n";
      OutputDebugStringW(wlog.c_str());
    } catch (...) {
      OutputDebugStringW(
          L"[AirShareNative] BLE adv verify: name check failed; continuing with StartAdvertising.\n");
    }

    GattServiceProviderAdvertisingParameters adv_params;
    adv_params.IsConnectable(true);
    adv_params.IsDiscoverable(true);
    OutputDebugStringW(
        L"[AirShareNative] Starting GATT advertising with primary packet carrying service UUID 6E400001-B5A3-F393-E0A9-E50E24DCCA9E.\n");
    gatt_provider_.StartAdvertising(adv_params);
    is_advertising_ = true;
    OutputDebugStringW(L"[AirShareNative] Hub BLE advertising started (GATT server).\n");
    OutputDebugStringW(
        L"[AirShareNative] Firewall hint: allow inbound TCP 8080 (example: netsh advfirewall firewall add rule name=\"AirShare 8080\" dir=in action=allow protocol=TCP localport=8080).\n");
    result->Success(flutter::EncodableValue());
  } catch (const winrt::hresult_error& e) {
    result->Error("ble_advertise_failed", WinrtStringToUtf8(e.message()));
  }
}

void FlutterWindow::StopHubAdvertising(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  StopHubAdvertisingInternal();
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::ResetHostHandshakeState(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  {
    std::lock_guard<std::mutex> lock(approval_mutex_);
    CancelApprovalTimeout();
    ClearPendingReadState();
  }
  {
    std::lock_guard<std::mutex> lock(session_map_mutex_);
    guest_public_key_by_transport_.clear();
    transport_by_guest_public_key_.clear();
  }
  approved_peer_host_keys_.clear();
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::ResetGuestHandshakeState(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  ClearGuestHandshakeSession();
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::StopHubAdvertisingInternal() {
  CancelApprovalTimeout();
  ClearGuestHandshakeSession();
  approved_peer_host_keys_.clear();
  pending_lan_ip_.clear();
  pending_p2p_ip_.clear();
  pending_p2p_mac_.clear();
  pending_hotspot_hub_ip_.clear();
  host_session_public_key_.clear();
  approved_peer_host_keys_.clear();
  pending_tls_cert_sha256_.clear();
  ClearPendingReadState();
  {
    std::lock_guard<std::mutex> lock(session_map_mutex_);
    guest_public_key_by_transport_.clear();
    transport_by_guest_public_key_.clear();
  }
  if (gatt_handshake_ && handshake_write_token_) {
    gatt_handshake_.WriteRequested(*handshake_write_token_);
  }
  if (gatt_handshake_ && handshake_read_token_) {
    gatt_handshake_.ReadRequested(*handshake_read_token_);
  }
  if (gatt_endpoint_ && endpoint_read_token_) {
    gatt_endpoint_.ReadRequested(*endpoint_read_token_);
  }
  handshake_write_token_.reset();
  handshake_read_token_.reset();
  endpoint_read_token_.reset();
  gatt_handshake_ = nullptr;
  gatt_endpoint_ = nullptr;
  if (gatt_provider_) {
    gatt_provider_.StopAdvertising();
    gatt_provider_ = nullptr;
  }
  is_advertising_ = false;
}

void FlutterWindow::ApproveConnection(
    const flutter::EncodableMap& args,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  std::lock_guard<std::mutex> lock(approval_mutex_);
  const auto approved_it = args.find(flutter::EncodableValue("approved"));
  if (approved_it == args.end()) {
    result->Error("invalid_args", "approved flag required.");
    return;
  }
  const bool approved = std::get<bool>(approved_it->second);
  if (!approved) {
    CancelApprovalTimeout();
    try {
      if (pending_read_request_) {
        pending_read_request_.RespondWithValue(nullptr);
      }
    } catch (...) {
    }
    if (pending_read_deferral_) {
      pending_read_deferral_.Complete();
      pending_read_deferral_ = nullptr;
    }
    pending_read_request_ = nullptr;
    try {
      if (pending_gatt_session_) {
        pending_gatt_session_.Close();
      }
    } catch (...) {
    }
    pending_gatt_session_ = nullptr;
    pending_session_id_.clear();
    OutputDebugStringW(L"[AirShareNative] Peer Handshake Blocked: declined by operator.\n");
    result->Success(flutter::EncodableValue());
    return;
  }

  const auto session_it = args.find(flutter::EncodableValue("sessionKey"));
  const auto peer_it = args.find(flutter::EncodableValue("peerId"));
  std::string session_key = pending_session_id_;
  if (session_it != args.end()) {
    if (const auto p = std::get_if<std::string>(&session_it->second)) {
      if (!p->empty()) session_key = *p;
    }
  } else if (peer_it != args.end()) {
    if (const auto p = std::get_if<std::string>(&peer_it->second)) {
      if (!p->empty()) session_key = *p;
    }
  }
  const auto host_pk_it = args.find(flutter::EncodableValue("hostPublicKey"));
  if (host_pk_it != args.end()) {
    if (const auto pk = std::get_if<std::string>(&host_pk_it->second)) {
      if (!pk->empty()) host_session_public_key_ = *pk;
    }
  }
  if (session_key.empty() || host_session_public_key_.empty()) {
    result->Error("invalid_peer", "sessionKey and host public key are required.");
    return;
  }
  approved_peer_host_keys_[session_key] = host_session_public_key_;

  CancelApprovalTimeout();
  try {
    const auto buffer = BuildHandshakeBufferForPeer(session_key);
    if (pending_read_request_) {
      pending_read_request_.RespondWithValue(buffer);
      if (pending_read_deferral_) {
        pending_read_deferral_.Complete();
        pending_read_deferral_ = nullptr;
      }
      pending_read_request_ = nullptr;
    }
    if (gatt_handshake_) {
      gatt_handshake_.NotifyValueAsync(buffer).get();
    }
    RefreshHostHandshakeGattCache();
    OutputDebugStringW(L"[AirShareNative] Peer Handshake Released.\n");
  } catch (const winrt::hresult_error& e) {
    result->Error("handshake_release_failed", WinrtStringToUtf8(e.message()));
    ClearPendingReadState();
    return;
  }
  pending_session_id_.clear();
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::UpdateHubEndpoint(
    const flutter::EncodableMap& args,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  const auto ip_it = args.find(flutter::EncodableValue("ip"));
  if (ip_it == args.end()) {
    result->Error("invalid_endpoint", "ip is required.");
    return;
  }
  const auto port_it = args.find(flutter::EncodableValue("port"));
  pending_hub_ip_ = std::get<std::string>(ip_it->second);
  if (port_it != args.end()) {
    if (const auto p = std::get_if<int>(&port_it->second)) {
      pending_hub_port_ = *p;
    } else if (const auto p64 = std::get_if<int64_t>(&port_it->second)) {
      pending_hub_port_ = static_cast<int>(*p64);
    }
  }
  const auto pk_it = args.find(flutter::EncodableValue("hostPublicKey"));
  if (pk_it != args.end()) {
    if (const auto pk = std::get_if<std::string>(&pk_it->second)) {
      if (!pk->empty()) {
        host_session_public_key_ = *pk;
      }
    }
  }
  const auto tls_it = args.find(flutter::EncodableValue("tlsCertSha256"));
  if (tls_it != args.end()) {
    if (const auto tls = std::get_if<std::string>(&tls_it->second)) {
      if (tls->empty()) {
        pending_tls_cert_sha256_.clear();
      } else {
        pending_tls_cert_sha256_ = *tls;
      }
    }
  }
  RefreshHostHandshakeGattCache();
  result->Success(flutter::EncodableValue());
}

namespace {

std::string EncodableMapString(const flutter::EncodableMap& args,
                               const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return {};
  }
  if (const auto s = std::get_if<std::string>(&it->second)) {
    return *s;
  }
  return {};
}

int EncodableMapInt(const flutter::EncodableMap& args, const char* key,
                    int default_v) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return default_v;
  }
  if (const auto v = std::get_if<int>(&it->second)) {
    return *v;
  }
  if (const auto v64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*v64);
  }
  return default_v;
}

}  // namespace

void FlutterWindow::UpdateConnectionEndpoints(
    const flutter::EncodableMap& args,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  pending_lan_ip_ = EncodableMapString(args, "lanIp");
  pending_p2p_ip_ = EncodableMapString(args, "p2pIp");
  pending_p2p_mac_ = EncodableMapString(args, "p2pMac");
  const auto hotspot_ssid = EncodableMapString(args, "hotspotSsid");
  const auto hotspot_pass = EncodableMapString(args, "hotspotPass");
  if (!hotspot_ssid.empty() && !hotspot_pass.empty()) {
    pending_ssid_ = hotspot_ssid;
    pending_password_ = hotspot_pass;
  }
  const auto hotspot_hub = EncodableMapString(args, "hotspotHubIp");
  if (!hotspot_hub.empty()) {
    pending_hotspot_hub_ip_ = hotspot_hub;
  }
  pending_hub_port_ = EncodableMapInt(args, "hubPort", pending_hub_port_);

  const auto tls = EncodableMapString(args, "tlsCertSha256");
  if (!tls.empty()) {
    pending_tls_cert_sha256_ = tls;
  }
  const auto host_pk = EncodableMapString(args, "hostPublicKey");
  if (!host_pk.empty()) {
    host_session_public_key_ = host_pk;
  }

  std::string primary = pending_lan_ip_;
  if (primary.empty()) {
    primary = pending_p2p_ip_;
  }
  if (primary.empty()) {
    primary = pending_hotspot_hub_ip_;
  }
  if (!primary.empty()) {
    pending_hub_ip_ = primary;
  }

  RefreshHostHandshakeGattCache();
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::WaitForSessionHandshake(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  (void)args;
  std::thread([this, result = std::move(result)]() mutable {
    using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
    GattCharacteristic characteristic{nullptr};
    {
      std::lock_guard<std::mutex> lock(guest_handshake_mutex_);
      characteristic = guest_handshake_char_;
    }
    if (!characteristic) {
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("no_guest_session",
                      "No active BLE handshake session to wait on.");
      });
      return;
    }

    if (!EnableGuestHandshakeNotifications(characteristic)) {
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("handshake_notify_failed",
                      "Unable to subscribe to handshake notifications.");
      });
      return;
    }

    OutputDebugStringW(
        L"[AirShareNative] Native | Awaiting session keys via GATT notify…\n");

    bool notified = false;
    std::string json;
    {
      std::unique_lock<std::mutex> cv_lock(guest_session_cv_mutex_);
      notified = guest_session_cv_.wait_for(
          cv_lock, std::chrono::seconds(45),
          [this]() {
            std::lock_guard<std::mutex> lock(guest_handshake_mutex_);
            return guest_session_received_;
          });
      if (notified) {
        std::lock_guard<std::mutex> lock(guest_handshake_mutex_);
        json = guest_session_notify_json_;
      }
    }

    ClearGuestHandshakeSession();
    if (!notified || json.empty()) {
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("handshake_pending",
                      "Host session keys not released after Approve.");
      });
      return;
    }

    auto extract = [](const std::string& key, const std::string& src) {
      const std::string needle = "\"" + key + "\":\"";
      auto start = src.find(needle);
      if (start == std::string::npos) return std::string();
      start += needle.size();
      auto end = src.find('"', start);
      if (end == std::string::npos) return std::string();
      return src.substr(start, end - start);
    };
    if (extract("host_public_key", json).empty()) {
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("handshake_pending",
                      "Handshake notification did not include session keys.");
      });
      return;
    }

    const auto payload = ParseHandshakeJsonToMap(json);
    DispatchToPlatformThread(
        [result = std::move(result), payload = std::move(payload)]() mutable {
          result->Success(flutter::EncodableValue(payload));
        });
  }).detach();
}

bool FlutterWindow::EnableGuestHandshakeNotifications(
    const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
        GattCharacteristic& characteristic) {
  using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
  using namespace winrt::Windows::Storage::Streams;
  try {
    DisableGuestHandshakeNotifications();
    const auto status =
        characteristic
            .WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue::Notify)
            .get();
    if (status != GattCommunicationStatus::Success) {
      OutputDebugStringW(
          L"[AirShareNative] Native | CCCD notify enable failed.\n");
      return false;
    }

    guest_handshake_value_changed_token_ = characteristic.ValueChanged(
        [this](GattCharacteristic const&,
               GattValueChangedEventArgs args) {
          auto buffer = args.CharacteristicValue();
          DataReader reader = DataReader::FromBuffer(buffer);
          const uint32_t len = reader.UnconsumedBufferLength();
          if (len == 0) return;
          std::vector<uint8_t> bytes(len);
          reader.ReadBytes(bytes);
          const std::string json(reinterpret_cast<const char*>(bytes.data()),
                                 bytes.size());
          auto extract = [](const std::string& key, const std::string& src) {
            const std::string needle = "\"" + key + "\":\"";
            auto start = src.find(needle);
            if (start == std::string::npos) return std::string();
            start += needle.size();
            auto end = src.find('"', start);
            if (end == std::string::npos) return std::string();
            return src.substr(start, end - start);
          };
          if (extract("host_public_key", json).empty()) {
            OutputDebugStringW(
                L"[AirShareNative] Native | Notify ignored (no session keys).\n");
            return;
          }
          {
            std::lock_guard<std::mutex> lock(guest_handshake_mutex_);
            guest_session_notify_json_ = json;
            guest_session_received_ = true;
          }
          OutputDebugStringW(
              L"[AirShareNative] Native | Session keys received via GATT notify.\n");
          guest_session_cv_.notify_all();
        });
    OutputDebugStringW(
        L"[AirShareNative] Native | Subscribed to handshake notifications.\n");
    return true;
  } catch (...) {
    return false;
  }
}

void FlutterWindow::DisableGuestHandshakeNotifications() {
  if (guest_handshake_char_ && guest_handshake_value_changed_token_) {
    try {
      guest_handshake_char_.ValueChanged(*guest_handshake_value_changed_token_);
    } catch (...) {
    }
  }
  guest_handshake_value_changed_token_.reset();
  guest_session_received_ = false;
  guest_session_notify_json_.clear();
}

void FlutterWindow::ClearGuestHandshakeSession() {
  DisableGuestHandshakeNotifications();
  std::lock_guard<std::mutex> lock(guest_handshake_mutex_);
  guest_handshake_char_ = nullptr;
  if (guest_handshake_device_) {
    try {
      guest_handshake_device_.Close();
    } catch (...) {
    }
    guest_handshake_device_ = nullptr;
  }
}

void FlutterWindow::RefreshHostHandshakeGattCache() {
  if (!gatt_handshake_ || !HandshakeBufferHasInfrastructure()) {
    return;
  }
  try {
    const auto buffer = BuildHandshakeBuffer();
    (void)buffer;
  } catch (...) {
  }
}

void FlutterWindow::RegisterGuestSession(const std::string& transport_id,
                                         const std::string& guest_public_key) {
  const auto trimmed = [&]() {
    size_t start = guest_public_key.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return std::string();
    size_t end = guest_public_key.find_last_not_of(" \t\r\n");
    return guest_public_key.substr(start, end - start + 1);
  }();
  if (trimmed.empty() || transport_id.empty()) return;
  std::lock_guard<std::mutex> lock(session_map_mutex_);
  guest_public_key_by_transport_[transport_id] = trimmed;
  transport_by_guest_public_key_[trimmed] = transport_id;
}

std::string FlutterWindow::ResolveSessionKey(
    const std::string& transport_id) {
  std::lock_guard<std::mutex> lock(session_map_mutex_);
  const auto it = guest_public_key_by_transport_.find(transport_id);
  if (it != guest_public_key_by_transport_.end()) {
    return it->second;
  }
  return std::string();
}

std::string FlutterWindow::ParseGuestPublicKeyFromWriteBuffer(
    const winrt::Windows::Storage::Streams::IBuffer& buffer) {
  using namespace winrt::Windows::Storage::Streams;
  if (!buffer) return {};
  DataReader reader = DataReader::FromBuffer(buffer);
  const uint32_t len = reader.UnconsumedBufferLength();
  if (len == 0) return {};
  std::vector<uint8_t> bytes(len);
  reader.ReadBytes(bytes);
  const std::string text(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  const auto key_pos = text.find("\"guest_public_key\"");
  if (key_pos != std::string::npos) {
    const auto colon = text.find(':', key_pos);
    const auto quote_start = text.find('"', colon);
    if (quote_start != std::string::npos) {
      const auto quote_end = text.find('"', quote_start + 1);
      if (quote_end != std::string::npos && quote_end > quote_start + 1) {
        return text.substr(quote_start + 1, quote_end - quote_start - 1);
      }
    }
  }
  if (text.find('{') == std::string::npos && text.size() >= 32) {
    return text;
  }
  return {};
}

void FlutterWindow::NotifyFlutterConnectionRequest(
    const std::string& friendly_name,
    const std::string& session_key) {
  DispatchToPlatformThread([this, friendly_name, session_key]() {
    if (!ble_ui_channel_) return;
    ble_ui_channel_->InvokeMethod(
        "notifyConnectionRequest",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("friendlyName"),
             flutter::EncodableValue(friendly_name)},
            {flutter::EncodableValue("sessionKey"),
             flutter::EncodableValue(session_key)},
            {flutter::EncodableValue("sessionId"),
             flutter::EncodableValue(session_key)},
        }));
  });
}

void FlutterWindow::ScheduleApprovalTimeout() {
  CancelApprovalTimeout();
  const uint64_t token = ++approval_timeout_generation_;
  std::thread([this, token]() {
    std::this_thread::sleep_for(std::chrono::seconds(30));
    std::lock_guard<std::mutex> lock(approval_mutex_);
    if (token != approval_timeout_generation_) return;
    OutputDebugStringW(
        L"[AirShareNative] Peer Handshake Blocked: approval timeout; closing pending read.\n");
    try {
      if (pending_read_request_) {
        pending_read_request_.RespondWithValue(nullptr);
      }
    } catch (...) {
    }
    if (pending_read_deferral_) {
      pending_read_deferral_.Complete();
      pending_read_deferral_ = nullptr;
    }
    pending_read_request_ = nullptr;
    try {
      if (pending_gatt_session_) {
        pending_gatt_session_.Close();
      }
    } catch (...) {
    }
    pending_gatt_session_ = nullptr;
    pending_session_id_.clear();
  }).detach();
}

void FlutterWindow::CancelApprovalTimeout() {
  ++approval_timeout_generation_;
}

void FlutterWindow::ClearPendingReadState() {
  pending_read_request_ = nullptr;
  if (pending_read_deferral_) {
    pending_read_deferral_.Complete();
    pending_read_deferral_ = nullptr;
  }
  try {
    if (pending_gatt_session_) {
      pending_gatt_session_.Close();
    }
  } catch (...) {
  }
  pending_gatt_session_ = nullptr;
  pending_session_id_.clear();
}

bool FlutterWindow::HandshakeBufferHasInfrastructure() const {
  if (!pending_lan_ip_.empty()) return true;
  if (!pending_p2p_ip_.empty()) return true;
  if (!pending_p2p_mac_.empty()) return true;
  if (!pending_ssid_.empty()) return true;
  if (!pending_hub_ip_.empty()) return true;
  return false;
}

bool FlutterWindow::JsonHasInfrastructure(const std::string& json) const {
  auto extract = [](const std::string& key, const std::string& src) {
    const std::string needle = "\"" + key + "\":\"";
    auto start = src.find(needle);
    if (start == std::string::npos) return std::string();
    start += needle.size();
    auto end = src.find('"', start);
    if (end == std::string::npos) return std::string();
    return src.substr(start, end - start);
  };
  if (!extract("lan_ip", json).empty()) return true;
  if (!extract("hubIp", json).empty()) return true;
  if (!extract("p2p_ip", json).empty()) return true;
  if (!extract("p2p_mac", json).empty() || !extract("p2pMac", json).empty()) {
    return true;
  }
  if (!extract("hotspot_ssid", json).empty() || !extract("ssid", json).empty()) {
    return true;
  }
  return false;
}

flutter::EncodableMap FlutterWindow::ParseHandshakeJsonToMap(
    const std::string& json) const {
  auto extract = [](const std::string& key, const std::string& src) {
    const std::string needle = "\"" + key + "\":\"";
    auto start = src.find(needle);
    if (start == std::string::npos) return std::string();
    start += needle.size();
    auto end = src.find('"', start);
    if (end == std::string::npos) return std::string();
    return src.substr(start, end - start);
  };
  auto extract_int = [](const std::string& key, const std::string& src,
                        int default_v) {
    const std::string needle = "\"" + key + "\":";
    auto start = src.find(needle);
    if (start == std::string::npos) return default_v;
    start += needle.size();
    while (start < src.size() &&
           std::isspace(static_cast<unsigned char>(src[start]))) {
      start++;
    }
    int val = 0;
    bool any = false;
    while (start < src.size() &&
           std::isdigit(static_cast<unsigned char>(src[start]))) {
      any = true;
      val = val * 10 + (src[start] - '0');
      start++;
    }
    return any ? val : default_v;
  };
  std::string lan_ip = extract("lan_ip", json);
  const std::string hub_ip_legacy = extract("hubIp", json);
  if (lan_ip.empty() && !hub_ip_legacy.empty()) {
    lan_ip = hub_ip_legacy;
  }
  const int hub_port =
      extract_int("hub_port", json, extract_int("hubPort", json, 8080));
  return {
      {flutter::EncodableValue("lan_ip"), flutter::EncodableValue(lan_ip)},
      {flutter::EncodableValue("p2p_ip"),
       flutter::EncodableValue(extract("p2p_ip", json))},
      {flutter::EncodableValue("p2p_mac"),
       flutter::EncodableValue(
           extract("p2p_mac", json).empty() ? extract("p2pMac", json)
                                            : extract("p2p_mac", json))},
      {flutter::EncodableValue("hotspot_ssid"),
       flutter::EncodableValue(extract("hotspot_ssid", json).empty()
                                   ? extract("ssid", json)
                                   : extract("hotspot_ssid", json))},
      {flutter::EncodableValue("hotspot_pass"),
       flutter::EncodableValue(extract("hotspot_pass", json).empty()
                                   ? extract("password", json)
                                   : extract("hotspot_pass", json))},
      {flutter::EncodableValue("hotspot_hub_ip"),
       flutter::EncodableValue(extract("hotspot_hub_ip", json))},
      {flutter::EncodableValue("host_public_key"),
       flutter::EncodableValue(extract("host_public_key", json))},
      {flutter::EncodableValue("tls_cert_sha256"),
       flutter::EncodableValue(extract("tls_cert_sha256", json))},
      {flutter::EncodableValue("hub_port"), flutter::EncodableValue(hub_port)},
      {flutter::EncodableValue("ssid"),
       flutter::EncodableValue(extract("ssid", json))},
      {flutter::EncodableValue("password"),
       flutter::EncodableValue(extract("password", json))},
      {flutter::EncodableValue("hubIp"), flutter::EncodableValue(hub_ip_legacy)},
      {flutter::EncodableValue("hubPort"), flutter::EncodableValue(hub_port)},
  };
}

winrt::Windows::Storage::Streams::IBuffer FlutterWindow::BuildHandshakeBuffer() const {
  std::ostringstream oss;
  oss << "{";
  bool first = true;
  auto append_field = [&](const std::string& key, const std::string& value) {
    if (value.empty()) return;
    if (!first) oss << ',';
    first = false;
    oss << "\"" << key << "\":\"" << value << "\"";
  };
  append_field("lan_ip", pending_lan_ip_);
  append_field("p2p_ip", pending_p2p_ip_);
  append_field("p2p_mac", pending_p2p_mac_);
  append_field("hotspot_ssid", pending_ssid_);
  append_field("hotspot_pass", pending_password_);
  append_field("hotspot_hub_ip", pending_hotspot_hub_ip_);
  if (!first) oss << ',';
  oss << "\"hub_port\":" << pending_hub_port_;
  std::string primary = pending_lan_ip_;
  if (primary.empty()) primary = pending_p2p_ip_;
  if (primary.empty()) primary = pending_hotspot_hub_ip_;
  if (primary.empty()) primary = pending_hub_ip_;
  if (!primary.empty()) {
    oss << ",\"hubIp\":\"" << primary << "\",\"hubPort\":" << pending_hub_port_;
  }
  if (!pending_ssid_.empty()) {
    oss << ",\"ssid\":\"" << pending_ssid_ << "\",\"password\":\""
        << pending_password_ << "\"";
  }
  if (!pending_p2p_mac_.empty()) {
    oss << ",\"p2pMac\":\"" << pending_p2p_mac_ << "\"";
  }
  if (!pending_tls_cert_sha256_.empty()) {
    oss << ",\"tls_cert_sha256\":\"" << pending_tls_cert_sha256_ << "\"";
  }
  oss << "}";
  const std::string json = oss.str();
  winrt::Windows::Storage::Streams::DataWriter writer;
  writer.WriteString(winrt::to_hstring(json));
  return writer.DetachBuffer();
}

winrt::Windows::Storage::Streams::IBuffer FlutterWindow::BuildHandshakeBufferForPeer(
    const std::string& peer_id) const {
  const auto infra = BuildHandshakeBuffer();
  winrt::Windows::Storage::Streams::DataReader reader =
      winrt::Windows::Storage::Streams::DataReader::FromBuffer(infra);
  const uint32_t len = reader.UnconsumedBufferLength();
  if (len == 0) return infra;
  std::vector<uint8_t> bytes(len);
  reader.ReadBytes(bytes);
  std::string json(reinterpret_cast<const char*>(bytes.data()), bytes.size());
  const auto it = approved_peer_host_keys_.find(peer_id);
  if (it == approved_peer_host_keys_.end() || it->second.empty()) {
    return infra;
  }
  if (json.size() >= 2 && json.back() == '}') {
    json.pop_back();
    json += ",\"host_public_key\":\"" + it->second + "\"}";
  }
  winrt::Windows::Storage::Streams::DataWriter writer;
  writer.WriteString(winrt::to_hstring(json));
  return writer.DetachBuffer();
}

winrt::Windows::Storage::Streams::IBuffer FlutterWindow::BuildEndpointBuffer() const {
  const std::string endpoint = pending_hub_ip_.empty()
                                   ? std::string("0.0.0.0:") + std::to_string(pending_hub_port_)
                                   : pending_hub_ip_ + ":" + std::to_string(pending_hub_port_);
  winrt::Windows::Storage::Streams::DataWriter writer;
  writer.WriteString(winrt::to_hstring(endpoint));
  return writer.DetachBuffer();
}

void FlutterWindow::ConnectToHubWlan(
    const flutter::EncodableMap& args,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  const auto ssid_it = args.find(flutter::EncodableValue("ssid"));
  const auto pass_it = args.find(flutter::EncodableValue("password"));
  if (ssid_it == args.end() || pass_it == args.end()) {
    result->Error("invalid_wlan_args", "SSID/password required.");
    return;
  }

  const auto ssid = std::get<std::string>(ssid_it->second);
  const auto password = std::get<std::string>(pass_it->second);

  const std::string profile_name = ssid;
  const std::string profile_xml =
      R"(<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">)"
      "<name>" + profile_name + "</name>"
      "<SSIDConfig><SSID><name>" + profile_name + "</name></SSID></SSIDConfig>"
      "<connectionType>ESS</connectionType>"
      "<connectionMode>auto</connectionMode>"
      "<MSM><security><authEncryption><authentication>WPA2PSK</authentication>"
      "<encryption>AES</encryption><useOneX>false</useOneX></authEncryption>"
      "<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>" +
      password + "</keyMaterial></sharedKey></security></MSM></WLANProfile>";

  // Professional fallback through netsh profile import/connect.
  const std::string temp_profile_path = "airshare_profile.xml";
  std::ofstream profile_file(temp_profile_path, std::ios::out | std::ios::trunc);
  if (!profile_file.is_open()) {
    result->Error("wlan_profile_error", "Unable to create WLAN profile file.");
    return;
  }
  profile_file << profile_xml;
  profile_file.close();

  const std::string add_cmd =
      "netsh wlan add profile filename=\"" + temp_profile_path + "\"";
  const std::string connect_cmd =
      "netsh wlan connect name=\"" + profile_name + "\"";
  system(add_cmd.c_str());
  const int connect_code = system(connect_cmd.c_str());
  remove(temp_profile_path.c_str());

  if (connect_code != 0) {
    result->Error("wlan_connect_failed", "Failed to connect internal WLAN link.");
    return;
  }
  OutputDebugStringW(L"[AirShareNative] Internal Link Established.\n");
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::StopInternalLink(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  StopHubAdvertisingInternal();
  if (ble_scanning_active_) {
    StopBleScanning(result);
    return;
  }
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::PublishDiscoveredPeers() {
  flutter::EncodableList peers;
  for (const auto& [_, peer] : discovered_peers_) {
    peers.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("id"), flutter::EncodableValue(peer.first)},
        {flutter::EncodableValue("friendlyName"),
         flutter::EncodableValue(peer.second)},
        {flutter::EncodableValue("serviceUuid"),
         flutter::EncodableValue("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")},
    }));
  }
  DispatchToPlatformThread([this, peers = std::move(peers)]() mutable {
    if (!ble_scan_sink_) return;
    ble_scan_sink_->Success(flutter::EncodableValue(peers));
  });
}

bool FlutterWindow::IsAirShareService(const std::vector<winrt::guid>& uuids) const {
  const auto target = winrt::guid(kAirShareServiceUuid);
  for (const auto& uuid : uuids) {
    if (uuid == target) return true;
  }
  return false;
}

std::string FlutterWindow::WinrtStringToUtf8(const winrt::hstring& value) const {
  std::wstring ws(value.c_str());
  if (ws.empty()) return {};
  const int required =
      WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (required <= 0) return {};
  std::string out(required - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, out.data(), required, nullptr,
                      nullptr);
  return out;
}
