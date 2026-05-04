#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/base.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Foundation.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void InitializeNativeChannels();
  void StartBleScanning(flutter::MethodResult<flutter::EncodableValue>* result);
  void StopBleScanning(flutter::MethodResult<flutter::EncodableValue>* result);
  void EstablishSecureHandshake(
      const flutter::EncodableMap& args,
      flutter::MethodResult<flutter::EncodableValue>* result);
  void StartHubAdvertising(const flutter::EncodableMap* args,
                           flutter::MethodResult<flutter::EncodableValue>* result);
  void StopHubAdvertising(flutter::MethodResult<flutter::EncodableValue>* result);
  void StopHubAdvertisingInternal();
  void ApproveConnection(const flutter::EncodableMap& args,
                         flutter::MethodResult<flutter::EncodableValue>* result);
  void ConnectToHubWlan(const flutter::EncodableMap& args,
                        flutter::MethodResult<flutter::EncodableValue>* result);
  void StopInternalLink(flutter::MethodResult<flutter::EncodableValue>* result);

  void PublishDiscoveredPeers();
  bool IsAirShareService(const std::vector<winrt::guid>& uuids) const;
  std::string WinrtStringToUtf8(const winrt::hstring& value) const;
  void NotifyFlutterConnectionRequest(const std::string& friendly_name,
                                      const std::string& session_id);
  void CancelApprovalTimeout();
  void ScheduleApprovalTimeout();
  void ClearPendingReadState();
  winrt::Windows::Storage::Streams::IBuffer BuildHandshakeBuffer() const;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      ble_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      wlan_method_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ble_ui_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      ble_scan_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> ble_scan_sink_;

  std::unordered_map<uint64_t, std::pair<std::string, std::string>>
      discovered_peers_;
  std::optional<winrt::event_token> watcher_received_token_;
  std::optional<winrt::event_token> watcher_stopped_token_;
  bool ble_scanning_active_ = false;

  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattServiceProvider
      gatt_provider_{nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic
      gatt_handshake_{nullptr};
  std::optional<winrt::event_token> handshake_read_token_;
  bool is_advertising_ = false;

  winrt::Windows::Foundation::IDeferral pending_read_deferral_{nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattReadRequest
      pending_read_request_{nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession
      pending_gatt_session_{nullptr};
  std::string pending_session_id_;
  std::mutex approval_mutex_;
  std::atomic<uint64_t> approval_timeout_generation_{0};

  std::string pending_ssid_;
  std::string pending_password_;
  std::string pending_hub_ip_;
  int pending_hub_port_ = 8080;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
