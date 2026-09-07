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
#include <utility>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "win32_window.h"

// Move-only tasks for posting to the Win32 / Flutter platform thread (std::function
// cannot store lambdas that capture std::unique_ptr on MSVC).
struct AirSharePlatformTask {
  virtual void Run() = 0;
  virtual ~AirSharePlatformTask() = default;
};

template <typename F>
struct AirShareLambdaPlatformTask final : AirSharePlatformTask {
  F fn;
  explicit AirShareLambdaPlatformTask(F&& f) : fn(std::forward<F>(f)) {}
  void Run() override { fn(); }
};

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
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ReadPeerEndpoint(const flutter::EncodableMap& args,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartHubAdvertising(const flutter::EncodableMap* args,
                           flutter::MethodResult<flutter::EncodableValue>* result);
  void StopHubAdvertising(flutter::MethodResult<flutter::EncodableValue>* result);
  void StopHubAdvertisingInternal();
  void ApproveConnection(const flutter::EncodableMap& args,
                         flutter::MethodResult<flutter::EncodableValue>* result);
  void UpdateHubEndpoint(const flutter::EncodableMap& args,
                         flutter::MethodResult<flutter::EncodableValue>* result);
  void UpdateConnectionEndpoints(
      const flutter::EncodableMap& args,
      flutter::MethodResult<flutter::EncodableValue>* result);
  void GetLocalPeerId(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void IsBluetoothEnabled(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ConnectToHubWlan(const flutter::EncodableMap& args,
                        flutter::MethodResult<flutter::EncodableValue>* result);
  void StopInternalLink(flutter::MethodResult<flutter::EncodableValue>* result);

  void PublishDiscoveredPeers();
  bool IsAirShareService(const std::vector<winrt::guid>& uuids) const;
  std::string WinrtStringToUtf8(const winrt::hstring& value) const;
  void ApplyLanIpFromDart(const std::string& lan_ip, const char* reason);
  void NotifyFlutterConnectionRequest(const std::string& friendly_name,
                                      const std::string& session_id);
  // Runs on the Win32 message-thread (same thread Flutter expects for channels).
  void DispatchToPlatformThread(std::unique_ptr<AirSharePlatformTask> task);

  template <typename F>
  void DispatchToPlatformThread(F&& f) {
    DispatchToPlatformThread(
        std::unique_ptr<AirSharePlatformTask>(new AirShareLambdaPlatformTask<
                                              std::decay_t<F>>(std::forward<F>(f))));
  }

  void CancelApprovalTimeout();
  void ScheduleApprovalTimeout();
  void ClearPendingReadState();
  winrt::Windows::Storage::Streams::IBuffer BuildHandshakeBuffer() const;
  winrt::Windows::Storage::Streams::IBuffer BuildEndpointBuffer() const;
  std::string ResolveGuestDisplayName(const std::string& session_id);

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
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattLocalCharacteristic
      gatt_endpoint_{nullptr};
  std::optional<winrt::event_token> handshake_read_token_;
  std::optional<winrt::event_token> handshake_write_token_;
  std::optional<winrt::event_token> endpoint_read_token_;
  std::optional<winrt::event_token> gatt_adv_status_token_;
  bool is_advertising_ = false;

  winrt::Windows::Foundation::IDeferral pending_read_deferral_{nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattReadRequest
      pending_read_request_{nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattSession
      pending_gatt_session_{nullptr};
  std::string pending_session_id_;
  std::unordered_map<std::string, std::pair<std::string, std::string>>
      client_hello_by_session_;
  std::mutex approval_mutex_;
  std::atomic<uint64_t> approval_timeout_generation_{0};

  std::string pending_ssid_;
  std::string pending_password_;
  std::string pending_hub_ip_;
  std::string pending_lan_ip_;
  std::string pending_p2p_ip_;
  std::string pending_p2p_mac_;
  std::string pending_hotspot_ssid_;
  std::string pending_hotspot_pass_;
  std::string pending_hotspot_hub_ip_;
  std::string pending_tls_cert_sha256_;
  int pending_hub_port_ = 8080;
  std::string pending_friendly_name_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
