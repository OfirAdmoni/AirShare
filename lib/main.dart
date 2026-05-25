import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/settings_page.dart';
import 'package:air_share/discovery_page.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/sender_staging_page.dart';
import 'package:air_share/ux_prompts.dart';

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
      final friendlyName = (args['friendlyName'] ?? 'Unknown Device')
          .toString();
      await ConnectionLogger.instance.log(
        'Connection Request Prompted',
        details: 'peer=$friendlyName',
      );
      if (!mounted) return null;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return null;
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
        final pendingPort = HubEndpointState.instance.pendingPort;
        await ConnectionLogger.instance.log(
          'HS | Host | Approve tapped',
          details:
              'pendingIp=${pendingIp ?? "(null)"} pendingPort=$pendingPort',
        );
        if (pendingIp != null && pendingIp.isNotEmpty) {
          await BleTransport.instance.updateHubEndpoint(
            ip: pendingIp,
            port: pendingPort,
          );
          await ConnectionLogger.instance.log(
            'HS | Host | updateHubEndpoint(native GATT)',
            details: '$pendingIp:$pendingPort',
          );
          await ConnectionLogger.instance.log(
            'Connection | Advertising real IP',
            details: '$pendingIp:$pendingPort',
          );
        } else {
          await ConnectionLogger.instance.log(
            'HS | Host | updateHubEndpoint SKIPPED',
            details: 'pendingIp empty — handshake JSON may lack hubIp',
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UxPrompts.promptBluetoothOnLaunch(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AirShare Transfer Console'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    final btReady =
                        await UxPrompts.promptBluetoothRequiredForTransfer(
                          context,
                        );
                    if (!btReady) return;
                    ConnectionLogger.instance.log('Receiver Flow Opened');
                    if (!context.mounted) return;
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (discoveryContext) => DiscoveryPage(
                          onEndpointReady: (endpoint) async {
                            if (!discoveryContext.mounted) return;
                            final n = FileZoneSessionScope.of(discoveryContext);
                            final navigator = Navigator.of(discoveryContext);
                            await ConnectionLogger.instance.log(
                              'Connection | Triggering auto-connect',
                              details: 'hub=${endpoint.ip}:${endpoint.port}',
                            );
                            if (!navigator.mounted) return;
                            n.value = FileZoneSession(
                              hubHost: endpoint.ip,
                              hubPort: endpoint.port,
                            );
                            await navigator.push<void>(
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
                  onPressed: () async {
                    final btReady =
                        await UxPrompts.promptBluetoothRequiredForTransfer(
                          context,
                        );
                    if (!btReady) return;
                    ConnectionLogger.instance.log('Sender Flow Opened');
                    if (!context.mounted) return;
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
                Text(
                  'Android can host an offline hotspot. iPhone/iPad can join an Android '
                  'host\'s hotspot. iOS cannot host a hotspot. '
                  'iOS-to-iOS offline: TODO (Multipeer Connectivity).',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
  final TextEditingController _portController = TextEditingController(
    text: '8080',
  );
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
      await ConnectionLogger.instance.log(
        'Socket Connection Success',
        details: '$ip:$port',
      );
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Socket Connection Failed',
        details: e.toString(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connection check failed: $e')));
      setState(() => _connecting = false);
      return;
    }

    if (!mounted) return;
    final notifier = FileZoneSessionScope.of(context);
    final navigator = Navigator.of(context);
    notifier.value = FileZoneSession(hubHost: ip, hubPort: port);
    await ConnectionLogger.instance.log(
      'Manual Session Initialized',
      details: '$ip:$port',
    );
    if (!navigator.mounted) {
      notifier.value = null;
      return;
    }
    await navigator.push<void>(
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
  bool _sharing = false;
  bool _returningToMainMenu = false;

  @override
  void dispose() {
    unawaited(ConnectionLogger.instance.log('Logs | Screen disposed'));
    super.dispose();
  }

  Future<void> _returnToMainMenu() async {
    if (_returningToMainMenu) return;
    _returningToMainMenu = true;
    await ConnectionLogger.instance.log('Logs | Return to main menu requested');
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await ConnectionLogger.instance.log(
      'Navigation | Return to main menu completed',
      details: 'from=logs',
    );
  }

  Future<void> _shareLogs() async {
    final lines = ConnectionLogger.instance.entries.value;
    if (lines.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No logs to share')));
      return;
    }
    if (!mounted) return;
    setState(() => _sharing = true);
    try {
      if (Platform.isWindows) {
        await Clipboard.setData(ClipboardData(text: lines.join('\n')));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Log copied to clipboard')),
        );
      } else {
        await ConnectionLogger.instance.shareDisplayedLogs();
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share logs: ${e.message ?? e.code}')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _clearLogs() async {
    if (!mounted) return;
    setState(() => _clearing = true);
    try {
      await ConnectionLogger.instance.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Logs cleared')));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_returnToMainMenu());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to Main Menu',
            icon: const Icon(Icons.arrow_back),
            onPressed: _returningToMainMenu ? null : _returnToMainMenu,
          ),
          title: const Text('Connection Audit Log'),
          actions: [
            IconButton(
              tooltip: 'Share Logs',
              onPressed: _sharing || _clearing || _returningToMainMenu
                  ? null
                  : _shareLogs,
              icon: _sharing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share_outlined),
            ),
            IconButton(
              tooltip: 'Clear Logs',
              onPressed: _clearing || _sharing || _returningToMainMenu
                  ? null
                  : _clearLogs,
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
      ),
    );
  }
}
