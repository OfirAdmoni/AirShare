import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:nsd/nsd.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({required this.onHubSelected, super.key});

  final ValueChanged<String> onHubSelected;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  static const String _serviceType = '_airshare._tcp';
  static const int _fallbackDiscoveryPort = 45454;
  static const String _discoveryProbe = 'AIRSHARE_DISCOVERY_PROBE';
  static const String _discoveryResponse = 'AIRSHARE_DISCOVERY_RESPONSE';

  Discovery? _discovery;
  MDnsClient? _mdnsClient;
  Timer? _windowsScanTimer;
  Timer? _udpProbeTimer;
  RawDatagramSocket? _udpSocket;
  bool _isScanning = false;
  bool _usingWindowsUdpFallback = false;
  final List<_DiscoveredHub> _hubs = [];
  final Set<String> _localIps = {};

  @override
  void initState() {
    super.initState();
    _initializeDiscovery();
  }

  Future<void> _initializeDiscovery() async {
    await _captureLocalIps();
    await _startDiscovery();
  }

  @override
  void dispose() {
    _stopDiscovery();
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    if (_isScanning) return;

    try {
      if (Platform.isWindows) {
        await _startWindowsDiscovery();
        return;
      }

      final discovery = await startDiscovery(
        _serviceType,
        ipLookupType: IpLookupType.any,
      );

      if (!mounted) {
        await stopDiscovery(discovery);
        return;
      }

      setState(() {
        _discovery = discovery;
        _isScanning = true;
      });

      discovery.addListener(() {
        if (!mounted) return;
        setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('[Discovery] start failed: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Network discovery error: $e')));
    }
  }

  Future<void> _startWindowsDiscovery() async {
    try {
      _mdnsClient = MDnsClient();
      await _mdnsClient!.start();
      _isScanning = true;
      _usingWindowsUdpFallback = false;
      await _scanWindowsHubs();
      _windowsScanTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
        try {
          await _scanWindowsHubs();
        } on SocketException catch (error) {
          debugPrint('[Discovery][Windows] IPv4 multicast scan socket error: $error');
          if (_isWindowsSocket10042(error)) {
            await _switchToWindowsUdpFallback(error);
            return;
          }
        } catch (error) {
          debugPrint('[Discovery][Windows] periodic scan failed: $error');
        }
      });
      if (mounted) {
        setState(() {});
      }
    } on SocketException catch (error) {
      debugPrint('[Discovery][Windows] mDNS startup failed: $error');
      if (_isWindowsSocket10042(error)) {
        await _switchToWindowsUdpFallback(error);
        return;
      }
      _isScanning = false;
      rethrow;
    } catch (error) {
      debugPrint('[Discovery][Windows] discovery initialization failed: $error');
      _isScanning = false;
      rethrow;
    }
  }

  Future<void> _scanWindowsHubs() async {
    final client = _mdnsClient;
    if (client == null) return;

    final Map<String, _DiscoveredHub> nextHubs = {};
    final ptrStream = client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$_serviceType.local'),
    );

    await for (final ptr in ptrStream) {
      final srvStream = client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(ptr.domainName),
      );
      await for (final srv in srvStream) {
        final ipStream = client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target),
        );
        await for (final ip in ipStream) {
          final host = ip.address.address;
          if (_isSelfHost(host)) {
            continue;
          }
          nextHubs[host] = _DiscoveredHub(host: host, port: srv.port);
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _hubs
        ..clear()
        ..addAll(nextHubs.values);
    });
  }

  Future<void> _captureLocalIps() async {
    _localIps
      ..clear()
      ..add('127.0.0.1')
      ..add('localhost');
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          _localIps.add(address.address);
        }
      }
    } catch (error) {
      debugPrint('[Discovery] Unable to enumerate local IPv4 interfaces: $error');
    }
  }

  bool _isSelfHost(String host) => _localIps.contains(host);

  bool _isWindowsSocket10042(SocketException error) {
    return error.osError?.errorCode == 10042 ||
        error.toString().contains('10042');
  }

  Future<void> _switchToWindowsUdpFallback(SocketException error) async {
    debugPrint('[Discovery][Windows] switching to UDP fallback after 10042: $error');
    _windowsScanTimer?.cancel();
    _windowsScanTimer = null;
    _mdnsClient?.stop();
    _mdnsClient = null;
    await _startWindowsUdpFallback();
  }

  Future<void> _startWindowsUdpFallback() async {
    try {
      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: false,
      );
      _udpSocket!.broadcastEnabled = true;
      _isScanning = true;
      _usingWindowsUdpFallback = true;

      _udpSocket!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = _udpSocket!.receive();
        if (datagram == null) return;
        final payload = utf8.decode(datagram.data, allowMalformed: true);
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) return;
          if (decoded['type'] != _discoveryResponse) return;
          final host = datagram.address.address;
          if (_isSelfHost(host)) return;
          final port = decoded['port'] is int ? decoded['port'] as int : 8080;

          if (!mounted) return;
          setState(() {
            final exists = _hubs.any((hub) => hub.host == host && hub.port == port);
            if (!exists) {
              _hubs.add(_DiscoveredHub(host: host, port: port));
            }
          });
        } catch (parseError) {
          debugPrint('[Discovery][Windows][UDP] response parse error: $parseError');
        }
      });

      await _sendUdpProbe();
      _udpProbeTimer?.cancel();
      _udpProbeTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
        await _sendUdpProbe();
      });
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      debugPrint('[Discovery][Windows][UDP] fallback startup failed: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network discovery fallback error: $error')),
      );
    }
  }

  Future<void> _sendUdpProbe() async {
    final socket = _udpSocket;
    if (socket == null) return;
    final payload = utf8.encode(_discoveryProbe);
    socket.send(payload, InternetAddress('255.255.255.255'), _fallbackDiscoveryPort);

    for (final ip in _localIps.where((ip) => ip != '127.0.0.1' && ip != 'localhost')) {
      final parts = ip.split('.');
      if (parts.length != 4) continue;
      final broadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
      try {
        socket.send(payload, InternetAddress(broadcast), _fallbackDiscoveryPort);
      } catch (_) {
        // Continue probing other interfaces.
      }
    }
  }

  Future<void> _stopDiscovery() async {
    _windowsScanTimer?.cancel();
    _windowsScanTimer = null;
    _udpProbeTimer?.cancel();
    _udpProbeTimer = null;

    _udpSocket?.close();
    _udpSocket = null;
    _usingWindowsUdpFallback = false;

    if (_mdnsClient != null) {
      _mdnsClient!.stop();
      _mdnsClient = null;
    }

    final discovery = _discovery;
    if (discovery != null) {
      _discovery = null;
      _isScanning = false;
      await stopDiscovery(discovery);
    }

    if (mounted) {
      setState(() {
        _isScanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = (_discovery?.services ?? const <Service>[]).where((service) {
      final host = service.host?.replaceAll(RegExp(r'\.$'), '');
      if (host == null || host.isEmpty) return true;
      return !_isSelfHost(host);
    }).toList();
    final hasDesktopHubs = _hubs.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Network Discovery')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Active Directory', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: services.isEmpty && !hasDesktopHubs
                  ? Center(
                      child: Text(
                        _isScanning
                            ? (_usingWindowsUdpFallback
                                  ? 'Scanning local network for hubs (IPv4 fallback)...'
                                  : 'Scanning local network for hubs...')
                            : 'No hubs discovered',
                      ),
                    )
                  : ListView.builder(
                      itemCount: Platform.isWindows ? _hubs.length : services.length,
                      itemBuilder: (context, index) {
                        if (Platform.isWindows) {
                          final hub = _hubs[index];
                          return ListTile(
                            leading: const Icon(Icons.hub),
                            title: Text(hub.host),
                            subtitle: Text('Hub endpoint :${hub.port}'),
                            onTap: () => widget.onHubSelected(hub.host),
                          );
                        }

                        final service = services[index];
                        final hubHost = service.host?.replaceAll(RegExp(r'\.$'), '');
                        final displayTarget =
                            (hubHost != null && hubHost.isNotEmpty)
                            ? hubHost
                            : (service.name ?? 'Unknown hub');

                        return ListTile(
                          leading: const Icon(Icons.hub),
                          title: Text(displayTarget),
                          subtitle: Text('Hub endpoint :${service.port ?? 8080}'),
                          onTap: hubHost == null || hubHost.isEmpty
                              ? null
                              : () => widget.onHubSelected(hubHost),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await _stopDiscovery();
          await _startDiscovery();
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

class _DiscoveredHub {
  const _DiscoveredHub({required this.host, required this.port});

  final String host;
  final int port;
}
