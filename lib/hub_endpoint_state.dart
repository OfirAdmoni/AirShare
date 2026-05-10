class HubEndpointState {
  HubEndpointState._();

  static final HubEndpointState instance = HubEndpointState._();

  String? pendingIp;
  int pendingPort = 8080;

  void setPending({
    required String ip,
    required int port,
  }) {
    pendingIp = ip.trim();
    pendingPort = port;
  }

  void clear() {
    pendingIp = null;
    pendingPort = 8080;
  }
}

