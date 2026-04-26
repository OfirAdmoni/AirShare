import 'package:flutter/material.dart';
import 'package:nsd/nsd.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({required this.onServerSelected, super.key});

  final ValueChanged<String> onServerSelected;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  static const String _serviceType = '_airshare._tcp';

  Discovery? _discovery;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  @override
  void dispose() {
    _stopDiscovery();
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    if (_isScanning) return;

    try {
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Discovery error: $e')));
    }
  }

  Future<void> _stopDiscovery() async {
    final discovery = _discovery;
    if (discovery == null) return;

    _discovery = null;
    _isScanning = false;
    await stopDiscovery(discovery);
  }

  @override
  Widget build(BuildContext context) {
    final services = _discovery?.services ?? const <Service>[];

    return Scaffold(
      appBar: AppBar(title: const Text('AirShare - Discover Servers')),
      body: services.isEmpty
          ? Center(
              child: Text(
                _isScanning ? 'Scanning local network...' : 'No servers found',
              ),
            )
          : ListView.builder(
              itemCount: services.length,
              itemBuilder: (context, index) {
                final service = services[index];
                final host = service.host?.replaceAll(RegExp(r'\.$'), '');
                final displayTarget =
                    (host != null && host.isNotEmpty)
                    ? host
                    : (service.name ?? 'Unknown server');

                return ListTile(
                  leading: const Icon(Icons.computer),
                  title: Text(displayTarget),
                  subtitle: Text('Port ${service.port ?? 8080}'),
                  onTap: host == null || host.isEmpty
                      ? null
                      : () => widget.onServerSelected(host),
                );
              },
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
