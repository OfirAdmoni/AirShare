import 'package:flutter/material.dart';

import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/local_peer_identity.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  late final VoidCallback _focusListener;
  String _hardwareDefault = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _focusListener = () {
      if (!_nameFocus.hasFocus) {
        _autoSave();
      }
    };
    _nameFocus.addListener(_focusListener);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final saved = await DeviceBranding.savedDisplayNameRaw();
    final hw = await DeviceBranding.hardwareDefaultName();
    await ConnectionLogger.instance.log(
      'DeviceName | Loaded from storage: ${saved ?? "(none — using hardware default)"}',
    );
    if (!mounted) return;
    setState(() {
      _nameController.text = saved ?? '';
      _hardwareDefault = hw;
      _loaded = true;
    });
  }

  // Silent save triggered by focus-out — no SnackBar.
  Future<void> _autoSave() async {
    if (!_loaded) return;
    await DeviceBranding.saveDisplayName(_nameController.text);
    LocalPeerIdentity.invalidate();
  }

  // Explicit save triggered by the save button or keyboard Done — shows SnackBar.
  Future<void> _explicitSave() async {
    if (!_loaded) return;
    await DeviceBranding.saveDisplayName(_nameController.text);
    LocalPeerIdentity.invalidate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device name saved')),
    );
  }

  @override
  void dispose() {
    _nameFocus.removeListener(_focusListener);
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loaded
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Device name',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _nameController,
                    focusNode: _nameFocus,
                    textCapitalization: TextCapitalization.words,
                    maxLength: 32,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: 'Default: $_hardwareDefault',
                      suffixIcon: IconButton(
                        tooltip: 'Save',
                        icon: const Icon(Icons.save_outlined),
                        onPressed: _explicitSave,
                      ),
                    ),
                    onEditingComplete: _explicitSave,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'This name is shown to nearby devices during discovery. '
                    'Leave blank to use the system default ($_hardwareDefault).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
