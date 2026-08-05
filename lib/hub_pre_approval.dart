/// BLE-approved guests that should receive an auth token on [POST /join]
/// without a second host dialog.
class HubPreApproval {
  HubPreApproval._();

  static final Set<String> _keys = {};

  static String _normalizePeerId(String id) {
    return id.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
  }

  static String _normalizeName(String name) => name.trim().toLowerCase();

  /// Windows reports [BluetoothAddress] as decimal; Android/iOS use MAC hex.
  static String? _decimalBtAddressToHexMac(String raw) {
    final trimmed = raw.trim();
    if (!RegExp(r'^\d+$').hasMatch(trimmed)) return null;
    final value = int.tryParse(trimmed);
    if (value == null || value <= 0) return null;
    return value.toRadixString(16).padLeft(12, '0').toLowerCase();
  }

  /// WinRT device ids embed a MAC, e.g. `BluetoothLE#BluetoothLEaa:bb:cc:dd:ee:ff-...`
  static String? _macFromWinRtDeviceId(String raw) {
    final match = RegExp(
      r'([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}',
    ).firstMatch(raw);
    if (match == null) return null;
    return _normalizePeerId(match.group(0)!);
  }

  static Iterable<String> _peerIdKeyVariants(String raw) sync* {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    yield 'id:$trimmed';

    final hex = _normalizePeerId(trimmed);
    if (hex.isNotEmpty) {
      yield 'idn:$hex';
    }

    final fromDecimal = _decimalBtAddressToHexMac(trimmed);
    if (fromDecimal != null && fromDecimal.isNotEmpty) {
      yield 'idn:$fromDecimal';
    }

    final fromWinRt = _macFromWinRtDeviceId(trimmed);
    if (fromWinRt != null && fromWinRt.isNotEmpty) {
      yield 'idn:$fromWinRt';
    }
  }

  static void add({String? peerId, String? displayName}) {
    for (final key in _peerIdKeyVariants(peerId ?? '')) {
      _keys.add(key);
    }
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty) {
      _keys.add('name:${_normalizeName(name)}');
    }
  }

  /// BLE approval should key only on stable transport peer id, not OS factory names.
  static void addBlePeer(String peerId) => add(peerId: peerId);

  static bool hasAny() => _keys.isNotEmpty;

  static bool matches({String? peerId, String? displayName}) {
    for (final key in _peerIdKeyVariants(peerId ?? '')) {
      if (_keys.contains(key)) return true;
    }
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty && _keys.contains('name:${_normalizeName(name)}')) {
      return true;
    }
    return false;
  }

  static void consume({String? peerId, String? displayName}) {
    for (final key in _peerIdKeyVariants(peerId ?? '')) {
      _keys.remove(key);
    }
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty) {
      _keys.remove('name:${_normalizeName(name)}');
    }
  }

  static void clear() => _keys.clear();
}
