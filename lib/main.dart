import 'package:flutter/material.dart';
import 'dart:io';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/discovery_page.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/sender_staging_page.dart';

void main() {
  runApp(const AirShareApp());
}

class AirShareApp extends StatefulWidget {
  const AirShareApp({super.key});

  @override
  State<AirShareApp> createState() => _AirShareAppState();
}

class _AirShareAppState extends State<AirShareApp> {
  final HubStatus _hubStatus = HubStatus();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<FileZoneSession?> _fileZoneSession =
      ValueNotifier<FileZoneSession?>(null);

  @override
  void initState() {
    super.initState();
    ConnectionLogger.instance.initialize();
    ConnectionLogger.instance.log('Application Start');
    BleTransport.instance.setUiHandler((call) async {
      if (call.method != 'notifyConnectionRequest') {
        return null;
      }
      final args = call.arguments as Map<dynamic, dynamic>? ?? {};
      final friendlyName = (args['friendlyName'] ?? 'Unknown Device').toString();
      await ConnectionLogger.instance.log(
        'Connection Request Prompted',
        details: 'peer=$friendlyName',
      );
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) return null;
      final approved = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Connection Request'),
          content: Text('Device $friendlyName wants to connect. Allow?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Approve'),
            ),
          ],
        ),
      );
      if (approved == true) {
        final pendingIp = HubEndpointState.instance.pendingIp;
        if (pendingIp != null && pendingIp.isNotEmpty) {
          await BleTransport.instance.updateHubEndpoint(
            ip: pendingIp,
            port: HubEndpointState.instance.pendingPort,
          );
          await ConnectionLogger.instance.log(
            'Connection | Advertising real IP',
            details: '$pendingIp:${HubEndpointState.instance.pendingPort}',
          );
        }
      }
      await BleTransport.instance.approveConnection(approved: approved == true);
      await ConnectionLogger.instance.log(
        'Connection Request Decision',
        details: approved == true ? 'approved' : 'declined',
      );
      return null;
    });
  }

  @override
  void dispose() {
    _fileZoneSession.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HubStatusScope(
      status: _hubStatus,
      child: FileZoneSessionScope(
        notifier: _fileZoneSession,
        child: MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'AirShare',
          theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
          home: const ModeSelectionPage(),
        ),
      ),
    );
  }
}

class ModeSelectionPage extends StatefulWidget {
  const ModeSelectionPage({super.key});

  @override
  State<ModeSelectionPage> createState() => _ModeSelectionPageState();
}

class _ModeSelectionPageState extends State<ModeSelectionPage> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  String _modelHint = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadBranding();
  }

  Future<void> _loadBranding() async {
    final saved = await DeviceBranding.savedDisplayNameRaw();
    final model = await DeviceBranding.hardwareDefaultName();
    if (!mounted) return;
    setState(() {
      _nameController.text = saved ?? '';
      _modelHint = model;
      _loaded = true;
    });
  }

  Future<void> _persistName() async {
    await DeviceBranding.saveDisplayName(_nameController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device name saved')),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AirShare Transfer Console')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_loaded)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: LinearProgressIndicator(),
                  )
                else ...[
                  Text(
                    'Send as (BLE name)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _nameController,
                    focusNode: _nameFocus,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: _modelHint.isEmpty
                          ? 'Device model if empty'
                          : 'Empty = use "$_modelHint"',
                      suffixIcon: IconButton(
                        tooltip: 'Save',
                        icon: const Icon(Icons.save_outlined),
                        onPressed: _persistName,
                      ),
                    ),
                    onEditingComplete: _persistName,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Leave blank to advertise as this device\'s model name ($_modelHint).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                ],
                ElevatedButton.icon(
                  onPressed: () {
                    ConnectionLogger.instance.log('Receiver Flow Opened');
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (discoveryContext) => DiscoveryPage(
                          onEndpointReady: (endpoint) async {
                            await ConnectionLogger.instance.log(
                              'Connection | Triggering auto-connect',
                              details: 'hub=${endpoint.ip}:${endpoint.port}',
                            );
                            final n = FileZoneSessionScope.of(discoveryContext);
                            n.value = FileZoneSession(
                              hubHost: endpoint.ip,
                              hubPort: endpoint.port,
                            );
                            await Navigator.of(discoveryContext).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => FileListScreen(
                                  hubHost: endpoint.ip,
                                  hubPort: endpoint.port,
                                  modeTitle: 'Receive Files',
                                  isHubMode: false,
                                ),
                              ),
                            );
                            n.value = null;
                          },
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.move_to_inbox),
                  label: const Text('Receive Files'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    ConnectionLogger.instance.log('Sender Flow Opened');
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const SenderStagingPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.send),
                  label: const Text('Send Files'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const ManualConnectionPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Connect Manually'),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const ConnectionLogPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('Log View'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ManualConnectionPage extends StatefulWidget {
  const ManualConnectionPage({super.key});

  @override
  State<ManualConnectionPage> createState() => _ManualConnectionPageState();
}

class _ManualConnectionPageState extends State<ManualConnectionPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  bool _connecting = false;

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (ip.isEmpty || port == null || port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid IP and port')),
      );
      return;
    }
    setState(() => _connecting = true);
    await ConnectionLogger.instance.log(
      'Socket Connection Attempt',
      details: 'manual target=$ip:$port',
    );
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 3),
      );
      await socket.close();
      await ConnectionLogger.instance.log('Socket Connection Success', details: '$ip:$port');
    } catch (e) {
      await ConnectionLogger.instance.log('Socket Connection Failed', details: e.toString());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection check failed: $e')),
      );
      setState(() => _connecting = false);
      return;
    }

    if (!mounted) return;
    final notifier = FileZoneSessionScope.of(context);
    notifier.value = FileZoneSession(hubHost: ip, hubPort: port);
    await ConnectionLogger.instance.log('Manual Session Initialized', details: '$ip:$port');
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FileListScreen(
          hubHost: ip,
          hubPort: port,
          modeTitle: 'Manual Connection',
          isHubMode: false,
        ),
      ),
    );
    notifier.value = null;
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manual Connection')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'IP Address',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: const Icon(Icons.power),
              label: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

class ConnectionLogPage extends StatefulWidget {
  const ConnectionLogPage({super.key});

  @override
  State<ConnectionLogPage> createState() => _ConnectionLogPageState();
}

class _ConnectionLogPageState extends State<ConnectionLogPage> {
  bool _clearing = false;

  Future<void> _clearLogs() async {
    setState(() => _clearing = true);
    try {
      await ConnectionLogger.instance.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs cleared')),
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Audit Log'),
        actions: [
          IconButton(
            tooltip: 'Clear Logs',
            onPressed: _clearing ? null : _clearLogs,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: ConnectionLogger.instance.entries,
        builder: (context, lines, _) {
          if (lines.isEmpty) {
            return const Center(child: Text('No logs yet'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(lines[index], style: const TextStyle(fontSize: 12)),
            ),
          );
        },
      ),
    );
  }
}
