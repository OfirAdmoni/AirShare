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
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
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

std::string ExtractJsonStringField(const std::string& key, const std::string& json) {
  const std::string needle = "\"" + key + "\":\"";
  auto start = json.find(needle);
  if (start == std::string::npos) {
    return {};
  }
  start += needle.size();
  auto end = json.find('"', start);
  if (end == std::string::npos) {
    return {};
  }
  return json.substr(start, end - start);
}

int ExtractJsonIntField(const std::string& key, const std::string& json, int default_v) {
  const std::string needle = "\"" + key + "\":";
  auto start = json.find(needle);
  if (start == std::string::npos) {
    return default_v;
  }
  start += needle.size();
  while (start < json.size() &&
         std::isspace(static_cast<unsigned char>(json[start]))) {
    start++;
  }
  int val = 0;
  bool any = false;
  while (start < json.size() &&
         std::isdigit(static_cast<unsigned char>(json[start]))) {
    any = true;
    val = val * 10 + (json[start] - '0');
    start++;
  }
  return any ? val : default_v;
}

flutter::EncodableMap HandshakeJsonToEncodableMap(const std::string& json) {
  const int hub_port = ExtractJsonIntField("hub_port", json,
                                           ExtractJsonIntField("hubPort", json, 8080));
  std::string lan = ExtractJsonStringField("lan_ip", json);
  const std::string hub_ip = ExtractJsonStringField("hubIp", json);
  const std::string hotspot_ssid = ExtractJsonStringField("hotspot_ssid", json);
  const std::string ssid = ExtractJsonStringField("ssid", json);
  // Older Windows hosts only sent hubIp. Promote to lan_ip when no hotspot
  // credentials are present (matches Android guest parse fallback).
  if (lan.empty() && !hub_ip.empty() && hotspot_ssid.empty() && ssid.empty()) {
    lan = hub_ip;
  }
  return {
      {flutter::EncodableValue("lan_ip"), flutter::EncodableValue(lan)},
      {flutter::EncodableValue("p2p_ip"),
       flutter::EncodableValue(ExtractJsonStringField("p2p_ip", json))},
      {flutter::EncodableValue("p2p_mac"),
       flutter::EncodableValue(ExtractJsonStringField("p2p_mac", json))},
      {flutter::EncodableValue("p2pMac"),
       flutter::EncodableValue(ExtractJsonStringField("p2pMac", json))},
      {flutter::EncodableValue("hotspot_ssid"),
       flutter::EncodableValue(hotspot_ssid)},
      {flutter::EncodableValue("ssid"), flutter::EncodableValue(ssid)},
      {flutter::EncodableValue("hotspot_pass"),
       flutter::EncodableValue(ExtractJsonStringField("hotspot_pass", json))},
      {flutter::EncodableValue("password"),
       flutter::EncodableValue(ExtractJsonStringField("password", json))},
      {flutter::EncodableValue("hotspot_hub_ip"),
       flutter::EncodableValue(ExtractJsonStringField("hotspot_hub_ip", json))},
      {flutter::EncodableValue("hubIp"), flutter::EncodableValue(hub_ip)},
      {flutter::EncodableValue("hub_port"), flutter::EncodableValue(hub_port)},
      {flutter::EncodableValue("hubPort"), flutter::EncodableValue(hub_port)},
      {flutter::EncodableValue("tls_cert_sha256"),
       flutter::EncodableValue(ExtractJsonStringField("tls_cert_sha256", json))},
      {flutter::EncodableValue("friendly_name"),
       flutter::EncodableValue(ExtractJsonStringField("friendly_name", json))},
  };
}

std::string BuildClientHelloJson(const std::string& peer_id,
                                 const std::string& display_name) {
  std::string name = display_name.empty() ? "Guest" : display_name;
  std::ostringstream oss;
  oss << "{\"type\":\"client_hello\",\"peer_id\":\"" << peer_id
      << "\",\"display_name\":\"" << name << "\"}";
  return oss.str();
}

bool TryParseClientHello(const std::string& json,
                         std::string* peer_id,
                         std::string* display_name) {
  if (ExtractJsonStringField("type", json) != "client_hello") {
    return false;
  }
  const std::string name = ExtractJsonStringField("display_name", json);
  if (name.empty()) {
    return false;
  }
  if (peer_id) {
    *peer_id = ExtractJsonStringField("peer_id", json);
  }
  if (display_name) {
    *display_name = name;
  }
  return true;
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

// Canonical UUID string — must match lib/air_share_constants.dart + Android/iOS.
constexpr wchar_t kAirShareServiceUuidW[] =
    L"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr wchar_t kHandshakeUuidW[] = L"6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr wchar_t kEndpointUuidW[] = L"6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr char kAirShareServiceUuidUtf8[] =
    "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";

// ---------------------------------------------------------------------------
// UUID byte-order ground truth for 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//
// RFC / string octet order (how humans write the UUID):
//   6E 40 00 01  B5 A3  F3 93  E0 A9 E5 0E 24 DC CA 9E
//
// Windows GUID struct (winrt::guid / GUID) on little-endian x86/x64:
//   Data1=0x6E400001 → mem 01 00 40 6E
//   Data2=0xB5A3     → mem A3 B5
//   Data3=0xF393     → mem 93 F3
//   Data4            → mem E0 A9 E5 0E 24 DC CA 9E
//   Full GUID memory: 01 00 40 6E A3 B5 93 F3 E0 A9 E5 0E 24 DC CA 9E
//
// Bluetooth Core Spec AD types 0x06/0x07 (128-bit Service UUID list):
//   multipacket UUID fields are little-endian = REVERSE of the RFC octets.
//   BLE on-air AD payload: 9E CA DC 24 0E E5 A9 E0 93 F3 A3 B5 01 00 40 6E
//
// IMPORTANT: GUID memory ≠ BLE AD payload. ServiceUuids().Append(guid) asks
// WinRT/the radio stack to convert; some Intel vs Realtek/Qualcomm stacks have
// been observed to emit GUID memory bytes (or a partial swap) on the air,
// which 3rd-party scanners then display as a mutated UUID. We therefore publish
// the Service UUID via an explicit AD DataSection (type 0x07) with the BLE
// little-endian payload below — not via ServiceUuids.Append.
// ---------------------------------------------------------------------------
constexpr uint8_t kAirShareServiceUuidBleAdLe[16] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E,
};

// Expected Windows GUID mixed-endian components (for CreateAsync / GATT ATT).
constexpr uint32_t kServiceData1 = 0x6E400001u;
constexpr uint16_t kServiceData2 = 0xB5A3u;
constexpr uint16_t kServiceData3 = 0xF393u;
constexpr uint8_t kServiceData4[8] = {0xE0, 0xA9, 0xE5, 0x0E,
                                      0x24, 0xDC, 0xCA, 0x9E};

const winrt::guid& AirShareServiceGuid() {
  // GATT ATT database must use the canonical Windows GUID (string-parsed).
  static const winrt::guid g{winrt::guid(kAirShareServiceUuidW)};
  return g;
}
const winrt::guid& HandshakeGuid() {
  static const winrt::guid g{winrt::guid(kHandshakeUuidW)};
  return g;
}
const winrt::guid& EndpointGuid() {
  static const winrt::guid g{winrt::guid(kEndpointUuidW)};
  return g;
}

std::string BytesToHex(const uint8_t* bytes, size_t n) {
  std::string out;
  out.reserve(n * 3);
  char tmp[4];
  for (size_t i = 0; i < n; ++i) {
    if (i) out.push_back(' ');
    std::snprintf(tmp, sizeof(tmp), "%02X", bytes[i]);
    out += tmp;
  }
  return out;
}

std::string GuidToCanonicalString(const winrt::guid& g) {
  char buf[64];
  std::snprintf(
      buf, sizeof(buf),
      "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
      g.Data1, g.Data2, g.Data3, g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3],
      g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
  return buf;
}

// Windows GUID in-memory layout (NOT Bluetooth AD payload).
void GuidToMemoryBytes(const winrt::guid& g, uint8_t out[16]) {
  out[0] = static_cast<uint8_t>(g.Data1 & 0xFF);
  out[1] = static_cast<uint8_t>((g.Data1 >> 8) & 0xFF);
  out[2] = static_cast<uint8_t>((g.Data1 >> 16) & 0xFF);
  out[3] = static_cast<uint8_t>((g.Data1 >> 24) & 0xFF);
  out[4] = static_cast<uint8_t>(g.Data2 & 0xFF);
  out[5] = static_cast<uint8_t>((g.Data2 >> 8) & 0xFF);
  out[6] = static_cast<uint8_t>(g.Data3 & 0xFF);
  out[7] = static_cast<uint8_t>((g.Data3 >> 8) & 0xFF);
  for (int i = 0; i < 8; ++i) out[8 + i] = g.Data4[i];
}

std::string GuidToMemoryHex(const winrt::guid& g) {
  uint8_t bytes[16];
  GuidToMemoryBytes(g, bytes);
  return BytesToHex(bytes, 16);
}

// Interpret 16 AD payload bytes the way a BLE-spec scanner does (reverse of
// RFC octets) → UUID string a 3rd-party scanner should display.
std::string BleAdLeBytesToUuidString(const uint8_t le[16]) {
  char buf[64];
  std::snprintf(
      buf, sizeof(buf),
      "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
      le[15], le[14], le[13], le[12], le[11], le[10], le[9], le[8], le[7],
      le[6], le[5], le[4], le[3], le[2], le[1], le[0]);
  return buf;
}

void LogGuidDetails(const char* label, const winrt::guid& g) {
  uint8_t mem[16];
  GuidToMemoryBytes(g, mem);
  const std::string canon = GuidToCanonicalString(g);
  const std::string mem_hex = BytesToHex(mem, 16);
  const std::string ble_hex = BytesToHex(kAirShareServiceUuidBleAdLe, 16);
  const std::string if_mem_on_air = BleAdLeBytesToUuidString(mem);
  const std::string if_ble_on_air =
      BleAdLeBytesToUuidString(kAirShareServiceUuidBleAdLe);
  const std::wstring msg =
      L"[AirShareNative] " +
      std::wstring(label, label + std::strlen(label)) + L"\n"
      L"  canonical_string=" +
      std::wstring(canon.begin(), canon.end()) + L"\n"
      L"  guid_memory_hex=[" +
      std::wstring(mem_hex.begin(), mem_hex.end()) + L"]  "
      L"(Windows GUID layout — must NOT be raw AD payload)\n"
      L"  ble_ad_le_hex=[" +
      std::wstring(ble_hex.begin(), ble_hex.end()) + L"]  "
      L"(AD type 0x07 payload we emit)\n"
      L"  scanner_if_guid_memory_leaked=" +
      std::wstring(if_mem_on_air.begin(), if_mem_on_air.end()) + L"\n"
      L"  scanner_if_ble_ad_correct=" +
      std::wstring(if_ble_on_air.begin(), if_ble_on_air.end()) + L"\n";
  OutputDebugStringW(msg.c_str());
}

bool VerifyCanonicalServiceGuid(const winrt::guid& g) {
  bool ok = g.Data1 == kServiceData1 && g.Data2 == kServiceData2 &&
            g.Data3 == kServiceData3;
  for (int i = 0; i < 8; ++i) {
    ok = ok && (g.Data4[i] == kServiceData4[i]);
  }
  const std::string canon = GuidToCanonicalString(g);
  ok = ok && (canon == kAirShareServiceUuidUtf8);
  // Sanity: BLE AD LE bytes must decode back to the canonical string.
  const std::string from_ble =
      BleAdLeBytesToUuidString(kAirShareServiceUuidBleAdLe);
  ok = ok && (_stricmp(from_ble.c_str(), kAirShareServiceUuidUtf8) == 0);
  if (!ok) {
    OutputDebugStringW(
        L"[AirShareNative] FATAL: Service UUID canonical/BLE-AD mapping broken.\n");
    LogGuidDetails("UUID Verify FAIL", g);
  } else {
    OutputDebugStringW(
        L"[AirShareNative] UUID Verify OK: GUID components + BLE AD LE "
        L"payload both map to 6E400001-B5A3-F393-E0A9-E50E24DCCA9E.\n");
  }
  return ok;
}

const wchar_t* GattAdvStatusName(
    winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
        GattServiceProviderAdvertisementStatus status) {
  using winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
      GattServiceProviderAdvertisementStatus;
  switch (status) {
    case GattServiceProviderAdvertisementStatus::Created:
      return L"Created";
    case GattServiceProviderAdvertisementStatus::Stopped:
      return L"Stopped";
    case GattServiceProviderAdvertisementStatus::Started:
      return L"Started";
    case GattServiceProviderAdvertisementStatus::Aborted:
      return L"Aborted";
    default: {
      // Newer SDKs: StartedWithoutAllAdvertisementData == 4
      if (static_cast<int>(status) == 4) {
        return L"StartedWithoutAllAdvertisementData";
      }
      return L"Unknown";
    }
  }
}

bool IsGattAdvertisingEffectivelyStarted(
    winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
        GattServiceProviderAdvertisementStatus status) {
  using winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
      GattServiceProviderAdvertisementStatus;
  if (status == GattServiceProviderAdvertisementStatus::Started) {
    return true;
  }
  // UUID present but OS may have omitted LocalName when PDU is full — still OK.
  return static_cast<int>(status) == 4;
}

const wchar_t* BluetoothErrorName(
    winrt::Windows::Devices::Bluetooth::BluetoothError error) {
  using winrt::Windows::Devices::Bluetooth::BluetoothError;
  switch (error) {
    case BluetoothError::Success:
      return L"Success";
    case BluetoothError::RadioNotAvailable:
      return L"RadioNotAvailable";
    case BluetoothError::ResourceInUse:
      return L"ResourceInUse";
    case BluetoothError::DeviceNotConnected:
      return L"DeviceNotConnected";
    case BluetoothError::OtherError:
      return L"OtherError";
    case BluetoothError::DisabledByPolicy:
      return L"DisabledByPolicy";
    case BluetoothError::NotSupported:
      return L"NotSupported";
    case BluetoothError::DisabledByUser:
      return L"DisabledByUser";
    case BluetoothError::ConsentRequired:
      return L"ConsentRequired";
    case BluetoothError::TransportNotSupported:
      return L"TransportNotSupported";
    default:
      return L"Unknown";
  }
}

bool TryGetEncodableString(const flutter::EncodableMap& args,
                           const char* key,
                           std::string* out) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return false;
  }
  try {
    *out = std::get<std::string>(it->second);
    return true;
  } catch (...) {
    return false;
  }
}

bool TryGetEncodableInt(const flutter::EncodableMap& args,
                        const char* key,
                        int* out) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return false;
  }
  if (const auto p = std::get_if<int>(&it->second)) {
    *out = *p;
    return true;
  }
  if (const auto p64 = std::get_if<int64_t>(&it->second)) {
    *out = static_cast<int>(*p64);
    return true;
  }
  return false;
}

void AppendJsonStringField(std::ostringstream& oss,
                           bool* first,
                           const char* key,
                           const std::string& value) {
  if (value.empty()) {
    return;
  }
  if (!*first) {
    oss << ',';
  }
  *first = false;
  oss << '"' << key << "\":\"" << value << '"';
}

void AppendJsonIntField(std::ostringstream& oss,
                        bool* first,
                        const char* key,
                        int value) {
  if (!*first) {
    oss << ',';
  }
  *first = false;
  oss << '"' << key << "\":" << value;
}

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
  StopHubAdvertisingInternal();
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
  VerifyCanonicalServiceGuid(AirShareServiceGuid());
  LogGuidDetails("UUID Verify | Service", AirShareServiceGuid());
  LogGuidDetails("UUID Verify | Handshake char", HandshakeGuid());
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

    LogGuidDetails("Scan | filter target Service UUID", AirShareServiceGuid());

    watcher_received_token_ = g_watcher.Received([this](
                                                     auto&&,
                                                     const BluetoothLEAdvertisementReceivedEventArgs&
                                                         args) {
      const auto bt_addr = args.BluetoothAddress();

      // Collect service UUIDs (present in primary advertisements, absent in
      // scan responses — Android puts the device name in the scan response).
      std::vector<winrt::guid> uuids;
      for (const auto& uuid : args.Advertisement().ServiceUuids()) {
        uuids.push_back(uuid);
      }

      const std::string friendly_name =
          WinrtStringToUtf8(args.Advertisement().LocalName());

      // MUST-HAVE: log every advertisement's UUIDs before filtering so we can
      // compare on-air bytes against the canonical Service UUID.
      {
        std::wstring uuid_list;
        if (uuids.empty()) {
          uuid_list = L"(none)";
        } else {
          for (size_t i = 0; i < uuids.size(); ++i) {
            if (i) uuid_list += L" ; ";
            const std::string s = GuidToCanonicalString(uuids[i]);
            const std::string hx = GuidToMemoryHex(uuids[i]);
            uuid_list += std::wstring(s.begin(), s.end()) + L" hex=[" +
                         std::wstring(hx.begin(), hx.end()) + L"]";
          }
        }
        // Also dump raw 128-bit UUID AD sections (types 0x06/0x07) when present.
        std::wstring raw_sections;
        try {
          for (const auto& section : args.Advertisement().DataSections()) {
            const uint8_t dtype = section.DataType();
            if (dtype != 0x06 && dtype != 0x07) continue;
            auto buf = section.Data();
            winrt::Windows::Storage::Streams::DataReader reader =
                winrt::Windows::Storage::Streams::DataReader::FromBuffer(buf);
            const uint32_t len = reader.UnconsumedBufferLength();
            std::vector<uint8_t> raw(len);
            if (len > 0) reader.ReadBytes(raw);
            raw_sections += L" type=0x";
            wchar_t tb[8];
            std::swprintf(tb, 8, L"%02X", dtype);
            raw_sections += tb;
            raw_sections += L" bytes=[";
            for (uint32_t i = 0; i < len; ++i) {
              if (i) raw_sections += L" ";
              std::swprintf(tb, 8, L"%02X", raw[i]);
              raw_sections += tb;
            }
            raw_sections += L"]";
            if (len >= 16) {
              const std::string decoded = BleAdLeBytesToUuidString(raw.data());
              raw_sections += L" decoded_as=" +
                              std::wstring(decoded.begin(), decoded.end());
            }
          }
        } catch (...) {
        }
        if (raw_sections.empty()) raw_sections = L" (no 0x06/0x07 AD)";

        // Log ads that carry Service UUIDs always; also log named ads with no
        // UUID (helps catch hosts whose UUID was crowded out of the PDU).
        if (!uuids.empty() || !friendly_name.empty()) {
          std::wstringstream addr;
          addr << std::hex << bt_addr;
          OutputDebugStringW(
              (L"[AirShareNative] Scan | ADV addr=0x" + addr.str() +
               L" name=\"" +
               std::wstring(friendly_name.begin(), friendly_name.end()) +
               L"\" serviceUuids=" + uuid_list + L" raw128=" + raw_sections +
               L"\n")
                  .c_str());
        }
      }

      const bool is_known_peer =
          (discovered_peers_.find(bt_addr) != discovered_peers_.end());

      // Unknown device with no AirShare service UUID → not our peer, skip.
      if (!IsAirShareService(uuids) && !is_known_peer) return;

      if (is_known_peer) {
        // Scan-response (or repeat advertisement): update the stored name only
        // when we actually received one — never overwrite a good name with "".
        if (!friendly_name.empty() &&
            discovered_peers_[bt_addr].second != friendly_name) {
          OutputDebugStringW(
              (L"[AirShareNative] Peer name resolved from scan response: " +
               std::wstring(friendly_name.begin(), friendly_name.end()) + L"\n")
                  .c_str());
          discovered_peers_[bt_addr].second = friendly_name;
          PublishDiscoveredPeers();
        }
      } else {
        // First sighting via primary advertisement.
        std::stringstream id_stream;
        id_stream << bt_addr;
        const std::string peer_id = id_stream.str();
        discovered_peers_[bt_addr] = {
            peer_id,
            friendly_name.empty() ? "AirShare Device" : friendly_name};
        OutputDebugStringW(
            L"[AirShareNative] Scan | AirShare peer MATCHED canonical Service "
            L"UUID — publishing to Flutter.\n");
        PublishDiscoveredPeers();
      }
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

    auto service_uuid = AirShareServiceGuid();
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

    auto handshake_uuid = HandshakeGuid();
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

    auto handshake_char = chars_result.Characteristics().GetAt(0);
    std::string guest_peer_id = peer_id;
    if (const auto guest_peer_it =
            args_copy.find(flutter::EncodableValue("guestPeerId"));
        guest_peer_it != args_copy.end()) {
      try {
        const auto parsed = std::get<std::string>(guest_peer_it->second);
        if (!parsed.empty()) {
          guest_peer_id = parsed;
        }
      } catch (...) {
      }
    }
    std::string guest_display_name;
    if (const auto guest_name_it =
            args_copy.find(flutter::EncodableValue("guestDisplayName"));
        guest_name_it != args_copy.end()) {
      try {
        guest_display_name = std::get<std::string>(guest_name_it->second);
      } catch (...) {
      }
    }
    std::string client_hello_json;
    if (const auto hello_it =
            args_copy.find(flutter::EncodableValue("clientHelloJson"));
        hello_it != args_copy.end()) {
      try {
        client_hello_json = std::get<std::string>(hello_it->second);
      } catch (...) {
      }
    }
    if (client_hello_json.empty()) {
      client_hello_json =
          BuildClientHelloJson(guest_peer_id, guest_display_name);
    }
    try {
      winrt::Windows::Storage::Streams::DataWriter hello_writer;
      hello_writer.WriteString(winrt::to_hstring(client_hello_json));
      const auto hello_buffer = hello_writer.DetachBuffer();
      const auto write_result =
          handshake_char.WriteValueWithResultAsync(hello_buffer).get();
      if (write_result.Status() == GattCommunicationStatus::Success) {
        OutputDebugStringW(L"[AirShareNative] ClientHello write succeeded\n");
      } else {
        OutputDebugStringW(L"[AirShareNative] ClientHello write failed; continuing\n");
      }
    } catch (...) {
      OutputDebugStringW(L"[AirShareNative] ClientHello write exception; continuing\n");
    }

    std::vector<uint8_t> bytes;
    bool handshake_ready = false;
    for (int attempt = 1; attempt <= 15; ++attempt) {
      GattReadResult read_result{nullptr};
      try {
        read_result = handshake_char
                          .ReadValueAsync(BluetoothCacheMode::Uncached)
                          .get();
      } catch (const winrt::hresult_error& e) {
        OutputDebugStringW(
            L"[AirShareNative] Native | BLE Read | Result Status: Exception\n");
        OutputDebugStringW(
            L"[AirShareNative] Native | BLE Read | Protocol Error: n/a\n");
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
        const std::wstring status_msg =
            L"[AirShareNative] Native | BLE Read | Result Status: " +
            std::to_wstring(static_cast<int>(read_result.Status())) + L"\n";
        OutputDebugStringW(status_msg.c_str());
        const auto protocol_error = read_result.ProtocolError();
        const std::wstring protocol_msg =
            L"[AirShareNative] Native | BLE Read | Protocol Error: " +
            (protocol_error ? std::to_wstring(protocol_error.Value())
                            : std::wstring(L"none")) +
            L"\n";
        OutputDebugStringW(protocol_msg.c_str());
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
      const std::wstring status_msg =
          L"[AirShareNative] Native | BLE Read | Result Status: " +
          std::to_wstring(static_cast<int>(read_result.Status())) + L"\n";
      OutputDebugStringW(status_msg.c_str());
      const auto protocol_error = read_result.ProtocolError();
      const std::wstring protocol_msg =
          L"[AirShareNative] Native | BLE Read | Protocol Error: " +
          (protocol_error ? std::to_wstring(protocol_error.Value())
                          : std::wstring(L"none")) +
          L"\n";
      OutputDebugStringW(protocol_msg.c_str());
      winrt::Windows::Storage::Streams::DataReader reader =
          winrt::Windows::Storage::Streams::DataReader::FromBuffer(buffer);
      const uint32_t len = reader.UnconsumedBufferLength();
      bytes.assign(len, 0);
      if (len > 0) {
        reader.ReadBytes(bytes);
        const std::wstring msg = L"[AirShareNative] Native | Handshake read attempt " +
                                 std::to_wstring(attempt) + L"... Status: Success\n";
        OutputDebugStringW(msg.c_str());
        handshake_ready = true;
        break;
      }
      const std::wstring msg = L"[AirShareNative] Native | Handshake read attempt " +
                               std::to_wstring(attempt) + L"... Status: Empty\n";
      OutputDebugStringW(msg.c_str());
      if (attempt < 15) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
      }
    }
    if (!handshake_ready) {
      try {
        ble_device.Close();
      } catch (...) {
      }
      DispatchToPlatformThread([result = std::move(result)]() mutable {
        result->Error("handshake_pending", "Handshake pending UI approval.");
      });
      return;
    }
    const std::string json(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    flutter::EncodableMap payload = HandshakeJsonToEncodableMap(json);
    {
      std::wstring preview(json.begin(), json.end());
      if (preview.size() > 200) {
        preview = preview.substr(0, 200) + L"...";
      }
      OutputDebugStringW(
          (L"[AirShareNative] Native | Handshake JSON parsed (full wire fields)\n" +
           preview + L"\n")
              .c_str());
    }
    OutputDebugStringW(
        L"[AirShareNative] Peer Handshake Released (client read); closing BLE peripheral before socket.\n");
    try {
      ble_device.Close();
    } catch (...) {
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

    auto service_uuid = AirShareServiceGuid();
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

    auto endpoint_uuid = EndpointGuid();
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
    // If a prior session is already Started, reuse it. Otherwise force a full
    // teardown — a leftover provider that never reached Started used to make
    // the next startHubAdvertising return Success without advertising.
    if (gatt_provider_ && is_advertising_) {
      const auto st = gatt_provider_.AdvertisementStatus();
      if (IsGattAdvertisingEffectivelyStarted(st)) {
        OutputDebugStringW(
            L"[AirShareNative] startHubAdvertising: already Started — no-op.\n");
        result->Success(flutter::EncodableValue());
        return;
      }
      OutputDebugStringW(
          (L"[AirShareNative] startHubAdvertising: stale provider status=" +
           std::wstring(GattAdvStatusName(st)) +
           L" — releasing before recreate.\n")
              .c_str());
    }

    auto adapter = BluetoothAdapter::GetDefaultAsync().get();
    if (!adapter) {
      result->Error("no_adapter", "Bluetooth adapter unavailable.");
      return;
    }
    if (!adapter.IsPeripheralRoleSupported()) {
      result->Error(
          "peripheral_unsupported",
          "This Bluetooth adapter does not support BLE peripheral / GATT server.");
      return;
    }

    // Always drop any previous provider/ADV handle before binding a new one.
    ReleaseGattAdvertisingSession("startHubAdvertising:preflight");

    constexpr int kMaxAttempts = 3;
    std::string last_error;
    for (int attempt = 1; attempt <= kMaxAttempts; ++attempt) {
      {
        const std::wstring msg =
            L"[AirShareNative] GATT advertise attempt " +
            std::to_wstring(attempt) + L"/" + std::to_wstring(kMaxAttempts) +
            L"\n";
        OutputDebugStringW(msg.c_str());
      }
      if (attempt > 1) {
        ReleaseGattAdvertisingSession("startHubAdvertising:retry");
      }

      last_error = CreateAndStartGattAdvertisingOnce(args, attempt);
      if (last_error.empty()) {
        is_advertising_ = true;
        OutputDebugStringW(
            L"[AirShareNative] Hub BLE advertising Started. External scanner "
            L"must show Service UUID 6E400001-B5A3-F393-E0A9-E50E24DCCA9E.\n");
        OutputDebugStringW(
            L"[AirShareNative] Firewall hint: allow inbound TCP 8080 "
            L"(example: netsh advfirewall firewall add rule name=\"AirShare "
            L"8080\" dir=in action=allow protocol=TCP localport=8080).\n");
        result->Success(flutter::EncodableValue());
        return;
      }

      OutputDebugStringW(
          (L"[AirShareNative] GATT advertise attempt failed: " +
           std::wstring(last_error.begin(), last_error.end()) + L"\n")
              .c_str());
    }

    ReleaseGattAdvertisingSession("startHubAdvertising:exhausted");
    result->Error("ble_advertise_aborted", last_error);
  } catch (const winrt::hresult_error& e) {
    ReleaseGattAdvertisingSession("startHubAdvertising:exception");
    result->Error("ble_advertise_failed", WinrtStringToUtf8(e.message()));
  } catch (...) {
    ReleaseGattAdvertisingSession("startHubAdvertising:exception");
    result->Error("ble_advertise_failed", "Unknown advertising failure.");
  }
}

void FlutterWindow::ReleaseGattAdvertisingSession(const char* reason) {
  OutputDebugStringW(
      (L"[AirShareNative] ReleaseGattAdvertisingSession(" +
       std::wstring(reason, reason + std::strlen(reason)) + L")\n")
          .c_str());
  StopHubAdvertisingInternal();
  // Radio ADV handles are released asynchronously after StopAdvertising +
  // destroying the provider. Brief grace so the next CreateAsync/StartAdvertising
  // does not immediately Aborted(status=3) on a still-busy adapter.
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
}

std::string FlutterWindow::CreateAndStartGattAdvertisingOnce(
    const flutter::EncodableMap* args, int attempt) {
  using namespace winrt::Windows::Devices::Bluetooth;
  using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;

  VerifyCanonicalServiceGuid(AirShareServiceGuid());
  LogGuidDetails("Advertise | Service UUID for GattServiceProvider",
                 AirShareServiceGuid());

  const std::string service_uuid_str =
      GuidToCanonicalString(AirShareServiceGuid());
  {
    const std::wstring wlog =
        L"[AirShareNative] Creating GattServiceProvider attempt=" +
        std::to_wstring(attempt) + L" | Service UUID=" +
        std::wstring(service_uuid_str.begin(), service_uuid_str.end()) + L"\n";
    OutputDebugStringW(wlog.c_str());
  }

  auto provider_result =
      GattServiceProvider::CreateAsync(AirShareServiceGuid()).get();
  if (provider_result.Error() != BluetoothError::Success) {
    return std::string("Unable to create GATT service provider (error=") +
           std::to_string(static_cast<int>(provider_result.Error())) + ")";
  }
  gatt_provider_ = provider_result.ServiceProvider();

  GattLocalCharacteristicParameters params;
  params.CharacteristicProperties(GattCharacteristicProperties::Read |
                                  GattCharacteristicProperties::Notify |
                                  GattCharacteristicProperties::Write);
  params.UserDescription(L"Secure handshake payload");

  auto char_result = gatt_provider_.Service()
                         .CreateCharacteristicAsync(HandshakeGuid(), params)
                         .get();
  if (char_result.Error() != BluetoothError::Success) {
    ReleaseGattAdvertisingSession("handshake_char_failed");
    return "Unable to create handshake characteristic.";
  }
  gatt_handshake_ = char_result.Characteristic();

  handshake_write_token_ = gatt_handshake_.WriteRequested(
      [this](GattLocalCharacteristic const&, GattWriteRequestedEventArgs args) {
        auto deferral = args.GetDeferral();
        try {
          auto request = args.GetRequestAsync().get();
          const auto session_id =
              WinrtStringToUtf8(args.Session().DeviceId().Id());
          const auto buffer = request.Value();
          winrt::Windows::Storage::Streams::DataReader reader =
              winrt::Windows::Storage::Streams::DataReader::FromBuffer(buffer);
          const uint32_t len = reader.UnconsumedBufferLength();
          std::string json(len, '\0');
          if (len > 0) {
            reader.ReadBytes(winrt::array_view<uint8_t>(
                reinterpret_cast<uint8_t*>(json.data()), len));
          }
          std::string peer_id;
          std::string display_name;
          if (TryParseClientHello(json, &peer_id, &display_name)) {
            std::lock_guard<std::mutex> lock(approval_mutex_);
            client_hello_by_session_[session_id] = {peer_id, display_name};
            OutputDebugStringW(
                (L"[AirShareNative] ClientHello session=" +
                 std::wstring(session_id.begin(), session_id.end()) +
                 L" name=" +
                 std::wstring(display_name.begin(), display_name.end()) +
                 L"\n")
                    .c_str());
          }
          request.Respond();
        } catch (...) {
        }
        deferral.Complete();
      });

  GattLocalCharacteristicParameters endpoint_params;
  endpoint_params.CharacteristicProperties(GattCharacteristicProperties::Read |
                                           GattCharacteristicProperties::Write);
  endpoint_params.UserDescription(L"Hub endpoint");
  auto endpoint_result =
      gatt_provider_.Service()
          .CreateCharacteristicAsync(EndpointGuid(), endpoint_params)
          .get();
  if (endpoint_result.Error() != BluetoothError::Success) {
    ReleaseGattAdvertisingSession("endpoint_char_failed");
    return "Unable to create endpoint characteristic.";
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

  handshake_read_token_ = gatt_handshake_.ReadRequested(
      [this](GattLocalCharacteristic const&, GattReadRequestedEventArgs args) {
        auto deferral = args.GetDeferral();
        try {
          auto request = args.GetRequestAsync().get();
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
              L"[AirShareNative] Peer Handshake Blocked - Waiting for UI "
              L"Approval\n");
          NotifyFlutterConnectionRequest(ResolveGuestDisplayName(session_id),
                                         session_id);
          ScheduleApprovalTimeout();
          return;
        } catch (...) {
          deferral.Complete();
        }
      });

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
    pending_friendly_name_ = friendly_u8;
  } catch (...) {
    pending_friendly_name_ = "Windows";
  }

  struct AdvStatusWait {
    std::mutex mutex;
    std::condition_variable cv;
    bool terminal = false;
    GattServiceProviderAdvertisementStatus status{};
    BluetoothError error{};
  };
  auto adv_wait = std::make_shared<AdvStatusWait>();

  gatt_adv_status_token_ = gatt_provider_.AdvertisementStatusChanged(
      [adv_wait](GattServiceProvider const& provider,
                 GattServiceProviderAdvertisementStatusChangedEventArgs const&
                     args) {
        const auto status = args.Status();
        const auto error = args.Error();
        const std::wstring msg =
            L"[AirShareNative] GATT AdvertisementStatusChanged | status=" +
            std::wstring(GattAdvStatusName(status)) + L" (" +
            std::to_wstring(static_cast<int>(status)) + L") error=" +
            std::wstring(BluetoothErrorName(error)) + L" (" +
            std::to_wstring(static_cast<int>(error)) + L") providerStatus=" +
            std::wstring(GattAdvStatusName(provider.AdvertisementStatus())) +
            L"\n";
        OutputDebugStringW(msg.c_str());
        if (IsGattAdvertisingEffectivelyStarted(status) ||
            status == GattServiceProviderAdvertisementStatus::Aborted ||
            status == GattServiceProviderAdvertisementStatus::Stopped) {
          std::lock_guard<std::mutex> lock(adv_wait->mutex);
          adv_wait->status = status;
          adv_wait->error = error;
          adv_wait->terminal = true;
          adv_wait->cv.notify_all();
        }
      });

  // Single advertiser: GattServiceProvider only (no BluetoothLEAdvertisementPublisher).
  GattServiceProviderAdvertisingParameters adv_params;
  adv_params.IsConnectable(true);
  adv_params.IsDiscoverable(true);
  {
    const std::wstring wlog =
        L"[AirShareNative] StartAdvertising | IsConnectable=1 IsDiscoverable=1 "
        L"| Service UUID=" +
        std::wstring(service_uuid_str.begin(), service_uuid_str.end()) +
        L" | handshake_friendly_name=" +
        std::wstring(pending_friendly_name_.begin(),
                     pending_friendly_name_.end()) +
        L"\n";
    OutputDebugStringW(wlog.c_str());
  }

  try {
    gatt_provider_.StartAdvertising(adv_params);
  } catch (const winrt::hresult_error& e) {
    const std::string err = WinrtStringToUtf8(e.message());
    ReleaseGattAdvertisingSession("StartAdvertising_exception");
    return std::string("StartAdvertising threw: ") + err;
  }

  {
    std::unique_lock<std::mutex> lock(adv_wait->mutex);
    const bool got = adv_wait->cv.wait_for(
        lock, std::chrono::seconds(5), [&] { return adv_wait->terminal; });
    const auto final_status =
        got ? adv_wait->status : gatt_provider_.AdvertisementStatus();
    const auto final_error =
        got ? adv_wait->error : BluetoothError::OtherError;
    const std::wstring summary =
        L"[AirShareNative] GATT advertising settle | attempt=" +
        std::to_wstring(attempt) + L" got_event=" +
        std::wstring(got ? L"yes" : L"no/timeout") + L" status=" +
        std::wstring(GattAdvStatusName(final_status)) + L" error=" +
        std::wstring(BluetoothErrorName(final_error)) + L"\n";
    OutputDebugStringW(summary.c_str());

    if (IsGattAdvertisingEffectivelyStarted(final_status)) {
      return {};
    }

    // Leave provider destroyed so the next retry starts clean.
    ReleaseGattAdvertisingSession("advertise_not_started");
    return std::string("GATT advertising did not reach Started (status=") +
           std::to_string(static_cast<int>(final_status)) + " error=" +
           std::to_string(static_cast<int>(final_error)) +
           "). Released radio session and will retry if attempts remain.";
  }
}

void FlutterWindow::StopHubAdvertising(
    flutter::MethodResult<flutter::EncodableValue>* result) {
  ReleaseGattAdvertisingSession("stopHubAdvertising");
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::StopHubAdvertisingInternal() {
  CancelApprovalTimeout();
  ClearPendingReadState();
  if (gatt_provider_ && gatt_adv_status_token_) {
    try {
      gatt_provider_.AdvertisementStatusChanged(*gatt_adv_status_token_);
    } catch (...) {
    }
  }
  gatt_adv_status_token_.reset();
  if (gatt_handshake_ && handshake_read_token_) {
    try {
      gatt_handshake_.ReadRequested(*handshake_read_token_);
    } catch (...) {
    }
  }
  if (gatt_endpoint_ && endpoint_read_token_) {
    try {
      gatt_endpoint_.ReadRequested(*endpoint_read_token_);
    } catch (...) {
    }
  }
  handshake_read_token_.reset();
  if (gatt_handshake_ && handshake_write_token_) {
    try {
      gatt_handshake_.WriteRequested(*handshake_write_token_);
    } catch (...) {
    }
  }
  handshake_write_token_.reset();
  endpoint_read_token_.reset();
  {
    std::lock_guard<std::mutex> lock(approval_mutex_);
    client_hello_by_session_.clear();
  }
  gatt_handshake_ = nullptr;
  gatt_endpoint_ = nullptr;
  if (gatt_provider_) {
    try {
      OutputDebugStringW(
          L"[AirShareNative] StopAdvertising() on GattServiceProvider.\n");
      gatt_provider_.StopAdvertising();
    } catch (const winrt::hresult_error& e) {
      OutputDebugStringW(
          (L"[AirShareNative] StopAdvertising exception: " +
           std::wstring(e.message().c_str()) + L"\n")
              .c_str());
    } catch (...) {
    }
    // Drop the WinRT object so the OS can reclaim the peripheral ADV session
    // before a subsequent CreateAsync.
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

  // Apply approve-time lan_ip before sealing the ServerHello (matches Android).
  std::string lan_from_dart;
  if (TryGetEncodableString(args, "lanIp", &lan_from_dart) ||
      TryGetEncodableString(args, "lan_ip", &lan_from_dart)) {
    ApplyLanIpFromDart(lan_from_dart, "approveConnection");
  }

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

  CancelApprovalTimeout();
  try {
    if (!pending_read_request_) {
      result->Error("no_pending_read", "No pending handshake read request.");
      return;
    }
    const auto buffer = BuildHandshakeBuffer();
    {
      winrt::Windows::Storage::Streams::DataReader preview_reader =
          winrt::Windows::Storage::Streams::DataReader::FromBuffer(buffer);
      const uint32_t len = preview_reader.UnconsumedBufferLength();
      std::string preview(len, '\0');
      if (len > 0) {
        preview_reader.ReadBytes(winrt::array_view<uint8_t>(
            reinterpret_cast<uint8_t*>(preview.data()), len));
      }
      std::string log_preview = preview;
      if (log_preview.size() > 220) {
        log_preview = log_preview.substr(0, 220) + "...";
      }
      OutputDebugStringW(
          (L"[AirShareNative] ServerHello release JSON: " +
           std::wstring(log_preview.begin(), log_preview.end()) + L"\n")
              .c_str());
      if (ExtractJsonStringField("lan_ip", preview).empty() &&
          pending_lan_ip_.empty() && pending_hub_ip_.empty()) {
        OutputDebugStringW(
            L"[AirShareNative] WARNING: ServerHello has empty lan_ip/hubIp.\n");
      }
    }
    pending_read_request_.RespondWithValue(buffer);
    if (pending_read_deferral_) {
      pending_read_deferral_.Complete();
      pending_read_deferral_ = nullptr;
    }
    pending_read_request_ = nullptr;
    gatt_handshake_.NotifyValueAsync(buffer).get();
    OutputDebugStringW(L"[AirShareNative] Peer Handshake Released.\n");
  } catch (const winrt::hresult_error& e) {
    result->Error("handshake_release_failed", WinrtStringToUtf8(e.message()));
    ClearPendingReadState();
    return;
  }
  pending_session_id_.clear();
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::ApplyLanIpFromDart(const std::string& lan_ip,
                                       const char* reason) {
  std::string trimmed = lan_ip;
  TrimAsciiWhitespace(trimmed);
  if (trimmed.empty()) {
    return;
  }
  pending_lan_ip_ = trimmed;
  // Keep legacy hubIp in sync for endpoint characteristic + older guests.
  pending_hub_ip_ = trimmed;
  const std::wstring msg =
      L"[AirShareNative] ApplyLanIpFromDart(" +
      std::wstring(reason, reason + std::strlen(reason)) + L"): " +
      std::wstring(trimmed.begin(), trimmed.end()) + L"\n";
  OutputDebugStringW(msg.c_str());
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
  std::string ip;
  try {
    ip = std::get<std::string>(ip_it->second);
  } catch (...) {
    result->Error("invalid_endpoint", "ip must be a string.");
    return;
  }
  ApplyLanIpFromDart(ip, "updateHubEndpoint");
  if (port_it != args.end()) {
    if (const auto p = std::get_if<int>(&port_it->second)) {
      pending_hub_port_ = *p;
    } else if (const auto p64 = std::get_if<int64_t>(&port_it->second)) {
      pending_hub_port_ = static_cast<int>(*p64);
    }
  }
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::UpdateConnectionEndpoints(
    const flutter::EncodableMap& args,
    flutter::MethodResult<flutter::EncodableValue>* result) {
  std::string lan_ip;
  if (TryGetEncodableString(args, "lanIp", &lan_ip) ||
      TryGetEncodableString(args, "lan_ip", &lan_ip)) {
    ApplyLanIpFromDart(lan_ip, "updateConnectionEndpoints");
  }

  std::string value;
  if (TryGetEncodableString(args, "p2pIp", &value) ||
      TryGetEncodableString(args, "p2p_ip", &value)) {
    TrimAsciiWhitespace(value);
    if (!value.empty()) {
      pending_p2p_ip_ = value;
    }
  }
  if (TryGetEncodableString(args, "p2pMac", &value) ||
      TryGetEncodableString(args, "p2p_mac", &value)) {
    TrimAsciiWhitespace(value);
    if (!value.empty()) {
      pending_p2p_mac_ = value;
    }
  }
  if (TryGetEncodableString(args, "hotspotSsid", &value) ||
      TryGetEncodableString(args, "hotspot_ssid", &value)) {
    TrimAsciiWhitespace(value);
    pending_hotspot_ssid_ = value;
    pending_ssid_ = value;
  }
  if (TryGetEncodableString(args, "hotspotPass", &value) ||
      TryGetEncodableString(args, "hotspot_pass", &value)) {
    TrimAsciiWhitespace(value);
    pending_hotspot_pass_ = value;
    pending_password_ = value;
  }
  if (TryGetEncodableString(args, "hotspotHubIp", &value) ||
      TryGetEncodableString(args, "hotspot_hub_ip", &value)) {
    TrimAsciiWhitespace(value);
    if (!value.empty()) {
      pending_hotspot_hub_ip_ = value;
    }
  }
  if (TryGetEncodableString(args, "tlsCertSha256", &value) ||
      TryGetEncodableString(args, "tls_cert_sha256", &value)) {
    TrimAsciiWhitespace(value);
    pending_tls_cert_sha256_ = value;
  }
  int port = 0;
  if (TryGetEncodableInt(args, "hubPort", &port) ||
      TryGetEncodableInt(args, "hub_port", &port)) {
    pending_hub_port_ = port;
  }

  {
    const std::wstring msg =
        L"[AirShareNative] updateConnectionEndpoints: lan_ip=" +
        std::wstring(pending_lan_ip_.begin(), pending_lan_ip_.end()) +
        L" p2p_ip=" +
        std::wstring(pending_p2p_ip_.begin(), pending_p2p_ip_.end()) +
        L" hotspot_hub_ip=" +
        std::wstring(pending_hotspot_hub_ip_.begin(),
                     pending_hotspot_hub_ip_.end()) +
        L" hub_port=" + std::to_wstring(pending_hub_port_) + L"\n";
    OutputDebugStringW(msg.c_str());
  }
  result->Success(flutter::EncodableValue());
}

void FlutterWindow::NotifyFlutterConnectionRequest(
    const std::string& friendly_name,
    const std::string& session_id) {
  DispatchToPlatformThread([this, friendly_name, session_id]() {
    if (!ble_ui_channel_) return;
    ble_ui_channel_->InvokeMethod(
        "notifyConnectionRequest",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("friendlyName"),
             flutter::EncodableValue(friendly_name)},
            {flutter::EncodableValue("sessionId"),
             flutter::EncodableValue(session_id)},
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

std::string FlutterWindow::ResolveGuestDisplayName(
    const std::string& session_id) {
  std::lock_guard<std::mutex> lock(approval_mutex_);
  const auto it = client_hello_by_session_.find(session_id);
  if (it != client_hello_by_session_.end() && !it->second.second.empty()) {
    return it->second.second;
  }
  return "Unknown Peer";
}

winrt::Windows::Storage::Streams::IBuffer FlutterWindow::BuildHandshakeBuffer() const {
  // Match Android/iOS ServerHello: explicit lan_ip (never rely on hubIp alias).
  std::string lan = pending_lan_ip_;
  TrimAsciiWhitespace(lan);
  const std::string p2p = pending_p2p_ip_;
  const std::string ssid = pending_hotspot_ssid_.empty() ? pending_ssid_
                                                        : pending_hotspot_ssid_;
  const std::string password = pending_hotspot_pass_.empty()
                                   ? pending_password_
                                   : pending_hotspot_pass_;
  const std::string p2p_mac = pending_p2p_mac_;
  const std::string hotspot_hub = pending_hotspot_hub_ip_;

  if (lan.empty()) {
    std::string hub_fallback = pending_hub_ip_;
    TrimAsciiWhitespace(hub_fallback);
    // Only promote hubIp → lan_ip when no hotspot credentials (same as Android).
    if (!hub_fallback.empty() && ssid.empty()) {
      lan = hub_fallback;
    }
  }

  const std::string primary_legacy = !lan.empty()           ? lan
                                     : !p2p.empty()         ? p2p
                                     : !hotspot_hub.empty() ? hotspot_hub
                                                            : pending_hub_ip_;

  std::ostringstream oss;
  oss << '{';
  bool first = true;
  AppendJsonStringField(oss, &first, "lan_ip", lan);
  AppendJsonStringField(oss, &first, "p2p_ip", p2p);
  AppendJsonStringField(oss, &first, "p2p_mac", p2p_mac);
  AppendJsonStringField(oss, &first, "p2pMac", p2p_mac);
  AppendJsonStringField(oss, &first, "hotspot_ssid", ssid);
  AppendJsonStringField(oss, &first, "hotspot_pass", password);
  AppendJsonStringField(oss, &first, "hotspot_hub_ip", hotspot_hub);
  AppendJsonIntField(oss, &first, "hub_port", pending_hub_port_);
  AppendJsonStringField(oss, &first, "hubIp", primary_legacy);
  AppendJsonIntField(oss, &first, "hubPort", pending_hub_port_);
  if (!ssid.empty()) {
    AppendJsonStringField(oss, &first, "ssid", ssid);
    AppendJsonStringField(oss, &first, "password", password);
  }
  AppendJsonStringField(oss, &first, "friendly_name", pending_friendly_name_);
  AppendJsonStringField(oss, &first, "tls_cert_sha256", pending_tls_cert_sha256_);
  oss << '}';

  const std::string json = oss.str();
  {
    std::string preview = json;
    if (preview.size() > 220) {
      preview = preview.substr(0, 220) + "...";
    }
    OutputDebugStringW(
        (L"[AirShareNative] Handshake JSON built | " +
         std::wstring(preview.begin(), preview.end()) + L"\n")
            .c_str());
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
         flutter::EncodableValue(kAirShareServiceUuidUtf8)},
    }));
  }
  DispatchToPlatformThread([this, peers = std::move(peers)]() mutable {
    if (!ble_scan_sink_) return;
    ble_scan_sink_->Success(flutter::EncodableValue(peers));
  });
}

bool FlutterWindow::IsAirShareService(const std::vector<winrt::guid>& uuids) const {
  const auto& target = AirShareServiceGuid();
  const auto bswap32 = [](uint32_t v) -> uint32_t {
    return ((v & 0x000000FFu) << 24) | ((v & 0x0000FF00u) << 8) |
           ((v & 0x00FF0000u) >> 8) | ((v & 0xFF000000u) >> 24);
  };
  const auto bswap16 = [](uint16_t v) -> uint16_t {
    return static_cast<uint16_t>(((v & 0x00FFu) << 8) | ((v & 0xFF00u) >> 8));
  };
  for (const auto& uuid : uuids) {
    if (uuid == target) {
      return true;
    }
    // Defensive: accept Data1/2/3 byte-swapped variant (raw BLE bytes wrongly
    // interpreted as a Windows GUID on some peers/drivers).
    const winrt::guid swapped{bswap32(uuid.Data1), bswap16(uuid.Data2),
                              bswap16(uuid.Data3),
                              {uuid.Data4[0], uuid.Data4[1], uuid.Data4[2],
                               uuid.Data4[3], uuid.Data4[4], uuid.Data4[5],
                               uuid.Data4[6], uuid.Data4[7]}};
    if (swapped == target) {
      const std::string seen = GuidToCanonicalString(uuid);
      OutputDebugStringW(
          (L"[AirShareNative] Matched AirShare UUID via endianness-swapped "
           L"Data1/2/3; seen string=" +
           std::wstring(seen.begin(), seen.end()) + L"\n")
              .c_str());
      return true;
    }
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
