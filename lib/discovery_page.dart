import 'package:flutter/material.dart';
import 'package:nsd/nsd.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({required this.onHubSelected, super.key});

  final ValueChanged<String> onHubSelected;

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
      ).showSnackBar(SnackBar(content: Text('Network discovery error: $e')));
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
      appBar: AppBar(title: const Text('Network Discovery')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Active Directory', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: services.isEmpty
                  ? Center(
                      child: Text(
                        _isScanning
                            ? 'Scanning local network for hubs...'
                            : 'No hubs discovered',
                      ),
                    )
                  : ListView.builder(
                      itemCount: services.length,
                      itemBuilder: (context, index) {
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
