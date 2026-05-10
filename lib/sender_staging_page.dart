import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/wlan_link_manager.dart';

/// Sender (hub): start BLE advertising immediately, then HTTP hub + hotspot with matching port.
class SenderStagingPage extends StatefulWidget {
  const SenderStagingPage({super.key});

  @override
  State<SenderStagingPage> createState() => _SenderStagingPageState();
}

class _SenderStagingPageState extends State<SenderStagingPage> {
  String _status = 'Preparing hub…';
  Object? _error;
  bool _isPreparing = false;
  bool _prepareStarted = false;

  HubStatus get _hubStatus => HubStatusScope.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_prepareStarted) return;
      _prepareStarted = true;
      _prepareSender();
    });
  }

  Future<void> _prepareSender() async {
    if (!mounted || _isPreparing) return;
    setState(() {
      _isPreparing = true;
      _status = 'Starting BLE advertisement…';
      _error = null;
    });

    try {
      final advertiseAs = await DeviceBranding.effectiveAdvertisingName();
      await ConnectionLogger.instance.log('BLE Advertise Start', details: advertiseAs);
      await BleTransport.instance.startHubAdvertising(
        friendlyName: advertiseAs,
      );
      await ConnectionLogger.instance.log('BLE Advertise Result', details: 'success');
      if (!mounted) return;
      setState(() => _status = 'Starting local HTTP hub…');

      await LocalHubRuntime.instance.ensureStarted(_hubStatus);
      final port = LocalHubRuntime.instance.activePort;
      await ConnectionLogger.instance.log('HTTP Server Start', details: 'port=$port');
      final networkInfo = NetworkInfo();
      final discoveredIp = (await networkInfo.getWifiIP())?.trim();
      if (discoveredIp != null && discoveredIp.isNotEmpty) {
        await ConnectionLogger.instance.log(
          'Self IP discovered',
          details: discoveredIp,
        );
        await BleTransport.instance.updateHubEndpoint(
          ip: discoveredIp,
          port: port,
        );
      } else {
        await ConnectionLogger.instance.log(
          'Self IP discovered',
          details: 'unavailable from network_info_plus',
        );
      }

      if (!mounted) return;
      setState(() => _status = 'Starting temporary hotspot…');

      var manualHotspot = false;
      try {
        final hotspotInfo = await WlanLinkManager.instance.startTemporaryHotspot(
          ssid: 'AirShareLink',
          password: 'AirShare@2026',
          hubPort: port,
        );
        final hotspotIp = (hotspotInfo?['hubIp'] ?? '').toString();
        if (hotspotIp.isNotEmpty) {
          await BleTransport.instance.updateHubEndpoint(
            ip: hotspotIp,
            port: port,
          );
          await ConnectionLogger.instance.log(
            'Self IP discovered',
            details: hotspotIp,
          );
        }
        await ConnectionLogger.instance.log(
          'Hotspot Status',
          details: 'automatic start success',
        );
      } catch (e) {
        manualHotspot = true;
        await ConnectionLogger.instance.log(
          'Hotspot Status',
          details: 'manual required: $e',
        );
      }

      if (!mounted) return;
      setState(
        () => _status = manualHotspot
            ? 'Manual Hotspot: enable hotspot in settings and ensure the PC is connected.'
            : 'Hub ready — opening file console',
      );

      final sessionNotifier = FileZoneSessionScope.of(context);
      sessionNotifier.value = FileZoneSession(
        hubHost: '127.0.0.1',
        hubPort: port,
        isLocalHub: true,
      );

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => FileListScreen(
            hubHost: '127.0.0.1',
            hubPort: port,
            modeTitle: 'Send Files',
            isHubMode: true,
          ),
        ),
      );

      sessionNotifier.value = null;
      await BleTransport.instance.stopHubAdvertising();
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      debugPrint('[SenderStaging] $e\n$st');
      await ConnectionLogger.instance.log('BLE Advertise Result', details: 'failed: $e');
      if (!mounted) return;
      setState(() {
        _error = e;
        _status = 'Preparation failed';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isPreparing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send — Hub preparation')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.of(context).size.height - kToolbarHeight - 48,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              if (_isPreparing) const LinearProgressIndicator(),
              if (_isPreparing) const SizedBox(height: 16),
              if (_error != null)
                Text(
                  _error.toString(),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _isPreparing ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
