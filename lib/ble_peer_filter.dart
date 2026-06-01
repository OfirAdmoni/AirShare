import 'dart:io';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/device_branding.dart';
import 'package:air_share/local_peer_identity.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Filters BLE scan results so the local device is not shown as a connectable peer.
class BlePeerFilter {
  BlePeerFilter._();

  static String? _localPeerId;
  static final Set<String> _localNameCandidates = {};
  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _localNameCandidates.clear();
    try {
      final identity = await LocalPeerIdentity.resolve();
      _localPeerId = identity.peerId.trim();
      _addName(identity.displayName);
    } catch (e) {
      debugPrint('[BlePeerFilter] LocalPeerIdentity unavailable: $e');
    }
    try {
      _addName(await DeviceBranding.effectiveAdvertisingName());
      _addName(await DeviceBranding.hardwareDefaultName());
    } catch (e) {
      debugPrint('[BlePeerFilter] DeviceBranding unavailable: $e');
    }
    if (Platform.isMacOS) {
      try {
        final mac = await DeviceInfoPlugin().macOsInfo;
        _addName(mac.computerName);
        _addName(mac.hostName);
        _addName(mac.model);
      } catch (e) {
        debugPrint('[BlePeerFilter] macOS device info unavailable: $e');
      }
      try {
        final names = _localNameCandidates.toList();
        await BleTransport.instance.syncLocalBleIdentity(
          peerId: _localPeerId ?? '',
          advertisingName: names.isNotEmpty ? names.first : '',
        );
      } catch (e) {
        debugPrint('[BlePeerFilter] syncLocalBleIdentity skipped: $e');
      }
    }
    _initialized = true;
    await ConnectionLogger.instance.log(
      'BLE | Self-filter ready',
      details:
          'local_peer_id=${_localPeerId ?? "?"} names=${_localNameCandidates.join("|")}',
    );
  }

  static void _addName(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return;
    _localNameCandidates.add(trimmed.toLowerCase());
  }

  /// Returns peers that are not this device.
  static Future<List<BlePeer>> filterPeers(List<BlePeer> peers) async {
    await ensureInitialized();
    final kept = <BlePeer>[];
    for (final peer in peers) {
      if (_isSelfPeer(peer)) {
        await ConnectionLogger.instance.log(
          'BLE | Ignored self peer',
          details:
              'id=${peer.id} name=${peer.friendlyName} '
              'local_id=${_localPeerId ?? "?"}',
        );
        debugPrint(
          '[BlePeerFilter] ignored self peer id=${peer.id} name=${peer.friendlyName}',
        );
        continue;
      }
      kept.add(peer);
    }
    return kept;
  }

  static bool _isSelfPeer(BlePeer peer) {
    final peerId = peer.id.trim();
    if (_localPeerId != null &&
        _localPeerId!.isNotEmpty &&
        peerId == _localPeerId) {
      return true;
    }
    return _nameMatchesLocal(peer.friendlyName);
  }

  static bool _nameMatchesLocal(String peerName) {
    final normalized = peerName.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (_localNameCandidates.contains(normalized)) return true;
    for (final local in _localNameCandidates) {
      if (normalized == local) return true;
    }
    return false;
  }
}
