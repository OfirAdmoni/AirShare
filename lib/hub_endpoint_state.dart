import 'package:air_share/host_ble_endpoint_snapshot.dart';

class HubEndpointState {
  HubEndpointState._();

  static final HubEndpointState instance = HubEndpointState._();

  String? pendingIp;
  int pendingPort = 8080;
  HostBleEndpointSnapshot? lastBleSnapshot;

  void setPending({
    required String ip,
    required int port,
  }) {
    pendingIp = ip.trim();
    pendingPort = port;
  }

  void rememberBleSnapshot(HostBleEndpointSnapshot snapshot) {
    lastBleSnapshot = snapshot;
  }

  void clear() {
    pendingIp = null;
    pendingPort = 8080;
    lastBleSnapshot = null;
  }
}

