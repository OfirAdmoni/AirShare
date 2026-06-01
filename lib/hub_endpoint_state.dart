/// Host hub endpoint + last BLE handshake tier fields (for Approve-time refresh).
class HubEndpointState {
  HubEndpointState._();

  static final HubEndpointState instance = HubEndpointState._();

  String? pendingIp;
  int pendingPort = 8080;

  String rememberedLanIp = '';
  String rememberedP2pIp = '';
  String rememberedP2pMac = '';
  String rememberedHotspotSsid = '';
  String rememberedHotspotPass = '';
  String rememberedHotspotHubIp = '';

  void rememberBleEndpoints({
    required String lanIp,
    required String p2pIp,
    required String p2pMac,
    required String hotspotSsid,
    required String hotspotPass,
    required String hotspotHubIp,
    required int hubPort,
  }) {
    rememberedLanIp = lanIp.trim();
    rememberedP2pIp = p2pIp.trim();
    rememberedP2pMac = p2pMac.trim();
    rememberedHotspotSsid = hotspotSsid.trim();
    rememberedHotspotPass = hotspotPass.trim();
    rememberedHotspotHubIp = hotspotHubIp.trim();
    pendingPort = hubPort;
    final primary = rememberedLanIp.isNotEmpty
        ? rememberedLanIp
        : (rememberedP2pIp.isNotEmpty
            ? rememberedP2pIp
            : rememberedHotspotHubIp);
    if (primary.isNotEmpty) {
      pendingIp = primary;
    }
  }

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
    rememberedLanIp = '';
    rememberedP2pIp = '';
    rememberedP2pMac = '';
    rememberedHotspotSsid = '';
    rememberedHotspotPass = '';
    rememberedHotspotHubIp = '';
  }
}
