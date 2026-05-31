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
#include <condition_variable>
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
  void WaitForSessionHandshake(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ClearGuestHandshakeSession();
  void ResetHostHandshakeState(
      flutter::MethodResult<flutter::EncodableValue>* result);
  void ResetGuestHandshakeState(
      flutter::MethodResult<flutter::EncodableValue>* result);
  bool EnableGuestHandshakeNotifications(
      const winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
          GattCharacteristic& characteristic);
  void DisableGuestHandshakeNotifications();
  void RefreshHostHandshakeGattCache();
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
  void NotifyFlutterConnectionRequest(const std::string& friendly_name,
                                      const std::string& session_key);
  void RegisterGuestSession(const std::string& transport_id,
                            const std::string& guest_public_key);
  std::string ResolveSessionKey(const std::string& transport_id);
  std::string ParseGuestPublicKeyFromWriteBuffer(
      const winrt::Windows::Storage::Streams::IBuffer& buffer);
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
  winrt::Windows::Storage::Streams::IBuffer BuildHandshakeBufferForPeer(
      const std::string& peer_id) const;
  winrt::Windows::Storage::Streams::IBuffer BuildEndpointBuffer() const;
  flutter::EncodableMap ParseHandshakeJsonToMap(const std::string& json) const;
  bool JsonHasInfrastructure(const std::string& json) const;
  bool HandshakeBufferHasInfrastructure() const;

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
  std::string pending_lan_ip_;
  std::string pending_p2p_ip_;
  std::string pending_p2p_mac_;
  std::string pending_hotspot_hub_ip_;
  std::string pending_hub_ip_;
  int pending_hub_port_ = 8080;
  std::string host_session_public_key_;
  /// guest_public_key → host_public_key after Approve.
  std::unordered_map<std::string, std::string> approved_peer_host_keys_;
  std::unordered_map<std::string, std::string> guest_public_key_by_transport_;
  std::unordered_map<std::string, std::string> transport_by_guest_public_key_;
  mutable std::mutex session_map_mutex_;
  std::string pending_tls_cert_sha256_;

  std::mutex guest_handshake_mutex_;
  winrt::Windows::Devices::Bluetooth::BluetoothLEDevice guest_handshake_device_{
      nullptr};
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic
      guest_handshake_char_{nullptr};
  std::optional<winrt::event_token> guest_handshake_value_changed_token_;
  std::mutex guest_session_cv_mutex_;
  std::condition_variable guest_session_cv_;
  std::string guest_session_notify_json_;
  bool guest_session_received_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
