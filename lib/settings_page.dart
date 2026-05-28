import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/local_peer_identity.dart';

const String _appVersion = '1.0.0';
const String _prefPinEnabled = 'security_pin_enabled';
const String _prefPin = 'security_pin';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // ── Device name ───────────────────────────────────────────────────────────
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  late final VoidCallback _focusListener;
  String _hardwareDefault = '';
  bool _loaded = false;

  // ── Save location ─────────────────────────────────────────────────────────
  String? _savePath;

  // ── Connection PIN ────────────────────────────────────────────────────────
  bool _pinEnabled = false;
  final TextEditingController _pinController = TextEditingController();
  bool _pinObscured = true;

  @override
  void initState() {
    super.initState();
    _focusListener = () {
      if (!_nameFocus.hasFocus) _autoSaveName();
    };
    _nameFocus.addListener(_focusListener);
    _loadAll();
  }

  Future<void> _loadAll() async {
    final savedName = await DeviceBranding.savedDisplayNameRaw();
    final hw = await DeviceBranding.hardwareDefaultName();
    final savePath = await _resolveSavePath();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _nameController.text = savedName ?? '';
      _hardwareDefault = hw;
      _savePath = savePath;
      _pinEnabled = prefs.getBool(_prefPinEnabled) ?? false;
      _pinController.text = prefs.getString(_prefPin) ?? '';
      _loaded = true;
    });
    await ConnectionLogger.instance.log(
      'DeviceName | Loaded: ${savedName ?? "(hardware default)"}',
    );
  }

  Future<String> _resolveSavePath() async {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      final base = ext ?? await getApplicationDocumentsDirectory();
      return p.join(base.path, 'AirShare', 'Received');
    }
    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'AirShare');
    }
    final dl = await getDownloadsDirectory();
    return p.join((dl ?? await getApplicationDocumentsDirectory()).path, 'AirShare');
  }

  Future<void> _autoSaveName() async {
    if (!_loaded) return;
    await DeviceBranding.saveDisplayName(_nameController.text);
    LocalPeerIdentity.invalidate();
  }

  Future<void> _explicitSaveName() async {
    if (!_loaded) return;
    await DeviceBranding.saveDisplayName(_nameController.text);
    LocalPeerIdentity.invalidate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device name saved')),
    );
  }

  Future<void> _savePin() async {
    final pin = _pinController.text.trim();
    if (_pinEnabled && pin.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN must be at least 4 digits')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefPinEnabled, _pinEnabled);
    if (_pinEnabled) {
      await prefs.setString(_prefPin, pin);
    } else {
      await prefs.remove(_prefPin);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_pinEnabled ? 'PIN saved' : 'PIN protection disabled'),
      ),
    );
  }

  @override
  void dispose() {
    _nameFocus.removeListener(_focusListener);
    _nameController.dispose();
    _nameFocus.dispose();
    _pinController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                _sectionHeader(context, 'Device'),
                _deviceNameSection(context),
                const SizedBox(height: 24),
                _sectionHeader(context, 'Save Location'),
                _saveLocationSection(context),
                const SizedBox(height: 24),
                _sectionHeader(context, 'Connection Security'),
                _securitySection(context),
                const SizedBox(height: 24),
                _sectionHeader(context, 'About'),
                _aboutSection(context),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
      ),
    );
  }

  // ── Device name ───────────────────────────────────────────────────────────

  Widget _deviceNameSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _nameController,
          focusNode: _nameFocus,
          textCapitalization: TextCapitalization.words,
          maxLength: 32,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Device name',
            hintText: 'Default: $_hardwareDefault',
            suffixIcon: IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.save_outlined),
              onPressed: _explicitSaveName,
            ),
          ),
          onEditingComplete: _explicitSaveName,
        ),
        const SizedBox(height: 4),
        Text(
          'Shown to nearby devices during discovery. Leave blank to use the system default ($_hardwareDefault).',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  // ── Save location ─────────────────────────────────────────────────────────

  Widget _saveLocationSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, color: cs.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Received files folder',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  _savePath ?? 'Resolving…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Security ──────────────────────────────────────────────────────────────

  Widget _securitySection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          value: _pinEnabled,
          onChanged: (v) => setState(() => _pinEnabled = v),
          title: const Text('Require PIN for incoming connections'),
          subtitle: const Text('Senders must enter the PIN before connecting'),
          contentPadding: EdgeInsets.zero,
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 220),
          firstCurve: Curves.easeOut,
          secondCurve: Curves.easeOut,
          crossFadeState: _pinEnabled
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _pinController,
                obscureText: _pinObscured,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'PIN (4–8 digits)',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _pinObscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _pinObscured = !_pinObscured),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'The PIN is stored locally and shown to senders at connection time.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _savePin,
                child: const Text('Save PIN settings'),
              ),
            ],
          ),
          secondChild: const SizedBox.shrink(),
        ),
      ],
    );
  }

  // ── About ─────────────────────────────────────────────────────────────────

  Widget _aboutSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = <_AboutRow>[
      const _AboutRow(label: 'Version', value: _appVersion),
      const _AboutRow(
          label: 'Transport',
          value: 'Bluetooth LE discovery · Wi-Fi LAN transfer'),
      const _AboutRow(label: 'Licence', value: 'MIT'),
      const _AboutRow(label: 'Built with', value: 'Flutter · Dart'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].label,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    rows[i].value,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (i < rows.length - 1)
              Divider(height: 1, indent: 16, endIndent: 16, color: cs.outlineVariant),
          ],
        ],
      ),
    );
  }
}

class _AboutRow {
  const _AboutRow({required this.label, required this.value});
  final String label;
  final String value;
}
