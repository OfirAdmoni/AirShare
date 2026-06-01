import 'package:flutter/widgets.dart';

enum HubLifecycle { idle, starting, broadcasting, error, stopped }

class HubStatus extends ChangeNotifier {
  HubLifecycle lifecycle = HubLifecycle.idle;
  bool serverActive = false;
  bool advertisingActive = false;
  String message = 'Service Offline';
  String? lastError;

  void setStarting() {
    lifecycle = HubLifecycle.starting;
    serverActive = false;
    advertisingActive = false;
    message = 'Initializing hub services...';
    lastError = null;
    notifyListeners();
  }

  void setBroadcasting() {
    lifecycle = HubLifecycle.broadcasting;
    serverActive = true;
    advertisingActive = true;
    message = 'Room is open — ready to share!';
    lastError = null;
    notifyListeners();
  }

  void setError(String details) {
    lifecycle = HubLifecycle.error;
    serverActive = false;
    advertisingActive = false;
    message = 'Service Offline';
    lastError = details;
    notifyListeners();
  }

  void setStopped() {
    lifecycle = HubLifecycle.stopped;
    serverActive = false;
    advertisingActive = false;
    message = 'Service Offline';
    notifyListeners();
  }
}

class HubStatusScope extends InheritedNotifier<HubStatus> {
  const HubStatusScope({required HubStatus status, required super.child, super.key})
    : super(notifier: status);

  static HubStatus of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<HubStatusScope>();
    assert(scope != null, 'HubStatusScope is missing in widget tree');
    return scope!.notifier!;
  }
}
