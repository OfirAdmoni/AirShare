/// Last host endpoint fields pushed to native BLE (for approve-time refresh).
class HostBleEndpointSnapshot {
  HostBleEndpointSnapshot({
    this.lanIp = '',
    this.p2pIp = '',
    this.p2pMac = '',
    this.hotspotSsid = '',
    this.hotspotPass = '',
    this.hotspotHubIp = '',
    this.hubPort = 8080,
    this.hostPublicKey = '',
    this.tlsCertSha256 = '',
  });

  final String lanIp;
  final String p2pIp;
  final String p2pMac;
  final String hotspotSsid;
  final String hotspotPass;
  final String hotspotHubIp;
  final int hubPort;
  final String hostPublicKey;
  final String tlsCertSha256;

  bool get hasAnyTier =>
      lanIp.isNotEmpty ||
      p2pIp.isNotEmpty ||
      p2pMac.isNotEmpty ||
      hotspotSsid.isNotEmpty;

  bool get hasInfrastructure =>
      hasAnyTier && tlsCertSha256.isNotEmpty;
}
