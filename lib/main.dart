import 'package:flutter/material.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/discovery_page.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
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
    BleTransport.instance.setUiHandler((call) async {
      if (call.method != 'notifyConnectionRequest') {
        return null;
      }
      final args = call.arguments as Map<dynamic, dynamic>? ?? {};
      final friendlyName = (args['friendlyName'] ?? 'Unknown Device').toString();
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
      await BleTransport.instance.approveConnection(approved: approved == true);
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
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (discoveryContext) => DiscoveryPage(
                          onLinkReady: (payload) async {
                            final n = FileZoneSessionScope.of(discoveryContext);
                            n.value = FileZoneSession(
                              hubHost: payload.hubIp,
                              hubPort: payload.hubPort,
                            );
                            await Navigator.of(discoveryContext).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => FileListScreen(
                                  hubHost: payload.hubIp,
                                  hubPort: payload.hubPort,
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
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const SenderStagingPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.send),
                  label: const Text('Send Files'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
