import 'dart:async';
import 'dart:math';

/// Where an approval request originated.
enum GuestApprovalSource {
  ble,
  http,
  polling,
  registration,
}

extension GuestApprovalSourceLabel on GuestApprovalSource {
  String get label => switch (this) {
        GuestApprovalSource.ble => 'BLE',
        GuestApprovalSource.http => 'HTTP',
        GuestApprovalSource.polling => 'polling',
        GuestApprovalSource.registration => 'registration',
      };
}

enum GuestApprovalState { pending, approved, denied }

enum GuestApprovalOutcomeKind {
  /// Brand-new pending entry; host UI should show exactly one dialog.
  createdNew,

  /// Same logical connection already pending; reuse, do not emit UI.
  reusedPending,

  /// Already approved for this logical connection; return existing grant.
  alreadyApproved,

  /// Already denied for this logical connection.
  alreadyDenied,

  /// Duplicate transport event ignored (same as reusedPending for UI).
  ignoredDuplicate,
}

/// Stable key: room/session + guest peer + connection attempt / handshake nonce.
class GuestApprovalKey {
  const GuestApprovalKey({
    required this.roomSessionId,
    required this.guestPeerId,
    required this.connectionAttemptId,
  });

  final String roomSessionId;
  final String guestPeerId;
  final String connectionAttemptId;

  String get value =>
      '$roomSessionId|$guestPeerId|$connectionAttemptId';

  @override
  String toString() => value;
}

class GuestApprovalEntry {
  GuestApprovalEntry({
    required this.key,
    required this.displayName,
    required this.source,
    required this.createdAt,
  }) : state = GuestApprovalState.pending;

  final GuestApprovalKey key;
  String displayName;
  final GuestApprovalSource source;
  final DateTime createdAt;
  GuestApprovalState state;
  final Completer<bool> decision = Completer<bool>();

  /// Extra lookup ids (e.g. BLE device address ↔ HTTP peer id).
  final Set<String> aliases = <String>{};

  /// True after an HTTP /join has consumed this entry (bridge used).
  bool httpJoined = false;

  /// Issued access token for this connection attempt (null until approved).
  String? accessToken;

  /// Binding is live until guest exit / invalidate.
  bool sessionActive = false;

  bool get isPending => state == GuestApprovalState.pending;
  bool get isApproved => state == GuestApprovalState.approved;
  bool get isDenied => state == GuestApprovalState.denied;
}

class GuestApprovalBeginResult {
  const GuestApprovalBeginResult({
    required this.kind,
    required this.entry,
    required this.emitUiEvent,
  });

  final GuestApprovalOutcomeKind kind;
  final GuestApprovalEntry entry;
  final bool emitUiEvent;
}

/// Per-attempt access grant returned to the guest after approval.
class GuestAccessGrant {
  const GuestAccessGrant({
    required this.accessToken,
    required this.roomSessionId,
    required this.guestPeerId,
    required this.connectionAttemptId,
    required this.displayName,
  });

  final String accessToken;
  final String roomSessionId;
  final String guestPeerId;
  final String connectionAttemptId;
  final String displayName;
}

typedef GuestApprovalLog = void Function(String message, {String? details});

/// In-memory registry ensuring one approval UI event per logical guest attempt.
///
/// ## Connection-attempt boundary
/// A connection attempt **starts** when BLE handshake approval is created or
/// when `/join` starts a new attempt id.
/// A connection attempt **ends** when the guest leaves/disconnects, the host
/// denies, the room closes, or the attempt is explicitly invalidated.
/// Temporary BLE radio drops do **not** end the attempt while [sessionActive]
/// remains true for that grant.
class GuestApprovalRegistry {
  GuestApprovalRegistry({
    GuestApprovalLog? log,
    DateTime Function()? now,
    String Function()? tokenFactory,
  })  : _log = log ?? ((_, {details}) {}),
        _now = now ?? DateTime.now,
        _tokenFactory = tokenFactory ?? _defaultToken;

  final GuestApprovalLog _log;
  final DateTime Function() _now;
  final String Function() _tokenFactory;

  String? _roomSessionId;
  final Map<String, GuestApprovalEntry> _byKey = {};
  /// Maps exact key / peer|attempt / ble device → entry key.
  final Map<String, String> _aliasToKey = {};
  final Map<String, GuestApprovalEntry> _byToken = {};

  String? get roomSessionId => _roomSessionId;

  int get pendingCount =>
      _byKey.values.where((e) => e.isPending).length;

  int get activeSessionCount =>
      _byKey.values.where((e) => e.sessionActive && e.isApproved).length;

  /// True when any guest approval is still waiting on the host.
  bool get hasPendingApproval => pendingCount > 0;

  int get entryCount => _byKey.length;

  Iterable<GuestApprovalEntry> get entries => _byKey.values;

  void startRoomSession(String roomSessionId) {
    clearAll(reason: 'new_room_session');
    _roomSessionId = roomSessionId;
    _log(
      'Approval | Room session started',
      details: 'roomSessionId=$roomSessionId',
    );
  }

  void clearAll({required String reason}) {
    for (final entry in List<GuestApprovalEntry>.from(_byKey.values)) {
      _removeEntry(entry, reason: reason);
    }
    _roomSessionId = null;
  }

  GuestApprovalKey composeKey({
    required String guestPeerId,
    required String connectionAttemptId,
  }) {
    final room = _roomSessionId;
    if (room == null || room.isEmpty) {
      throw StateError('No active room session for guest approval');
    }
    return GuestApprovalKey(
      roomSessionId: room,
      guestPeerId: guestPeerId,
      connectionAttemptId: connectionAttemptId,
    );
  }

  /// Begin or reuse an approval for one logical guest connection attempt.
  GuestApprovalBeginResult begin({
    required String guestPeerId,
    required String connectionAttemptId,
    required String displayName,
    required GuestApprovalSource source,
  }) {
    final room = _roomSessionId;
    if (room == null || room.isEmpty) {
      throw StateError('No active room session for guest approval');
    }

    final key = GuestApprovalKey(
      roomSessionId: room,
      guestPeerId: guestPeerId,
      connectionAttemptId: connectionAttemptId,
    );

    _log(
      'Approval | Begin',
      details:
          'key=${key.value} roomSessionId=$room guestPeerId=$guestPeerId '
          'connectionAttemptId=$connectionAttemptId source=${source.label} '
          'name=$displayName',
    );

    final existing = _lookupExactOrPending(key, guestPeerId);
    if (existing != null) {
      return _reuse(existing, source: source, displayName: displayName);
    }

    // Reconnect detection: same peer had a prior attempt in this room.
    final priorForPeer = _findAnyEntryForPeer(guestPeerId);
    if (priorForPeer != null) {
      _log(
        'Approval | Reconnect detected',
        details:
            'guestPeerId=$guestPeerId previousKey=${priorForPeer.key.value} '
            'newAttempt=$connectionAttemptId previousActive=${priorForPeer.sessionActive}',
      );
      // Stale completed attempts must not authorize the new one.
      if (!priorForPeer.isPending) {
        invalidateEntry(
          entry: priorForPeer,
          reason: 'superseded_by_reconnect',
        );
      }
    }

    // Cross-source bridge: HTTP ↔ BLE for the same logical connection attempt.
    if (source == GuestApprovalSource.http ||
        source == GuestApprovalSource.registration ||
        source == GuestApprovalSource.polling) {
      final bridged = _findBleBridgeCandidate(displayName: displayName);
      if (bridged != null) {
        return _attachAndReuse(
          bridged,
          guestPeerId: guestPeerId,
          connectionAttemptId: connectionAttemptId,
          displayName: displayName,
          source: source,
          httpKey: key.value,
        );
      }
    }

    // Reverse bridge: BLE notify after /join already opened a pending approval.
    if (source == GuestApprovalSource.ble) {
      final bridged = _findHttpBridgeCandidate(displayName: displayName);
      if (bridged != null) {
        return _attachAndReuse(
          bridged,
          guestPeerId: guestPeerId,
          connectionAttemptId: connectionAttemptId,
          displayName: displayName,
          source: source,
          httpKey: key.value,
        );
      }
    }

    final entry = GuestApprovalEntry(
      key: key,
      displayName: displayName,
      source: source,
      createdAt: _now(),
    );
    entry.aliases.add(guestPeerId);
    entry.aliases.add(_peerAttemptAlias(guestPeerId, connectionAttemptId));
    _byKey[key.value] = entry;
    _aliasToKey[guestPeerId] = key.value;
    _aliasToKey[key.value] = key.value;
    _aliasToKey[_peerAttemptAlias(guestPeerId, connectionAttemptId)] =
        key.value;

    _log(
      'Approval | Created new approval',
      details:
          'key=${key.value} roomSessionId=$room guestPeerId=$guestPeerId '
          'connectionAttemptId=$connectionAttemptId source=${source.label} '
          'name=$displayName',
    );

    return GuestApprovalBeginResult(
      kind: GuestApprovalOutcomeKind.createdNew,
      entry: entry,
      emitUiEvent: true,
    );
  }

  Future<bool> waitForDecision(GuestApprovalEntry entry) => entry.decision.future;

  /// Mark approved and issue a token scoped to this connection attempt.
  GuestAccessGrant? resolve({
    required GuestApprovalEntry entry,
    required bool approved,
    required String reason,
  }) {
    if (entry.decision.isCompleted) {
      _log(
        'Approval | Resolve ignored (already decided)',
        details:
            'key=${entry.key.value} state=${entry.state.name} reason=$reason',
      );
      if (approved && entry.isApproved && entry.accessToken != null) {
        return GuestAccessGrant(
          accessToken: entry.accessToken!,
          roomSessionId: entry.key.roomSessionId,
          guestPeerId: entry.key.guestPeerId,
          connectionAttemptId: entry.key.connectionAttemptId,
          displayName: entry.displayName,
        );
      }
      return null;
    }
    entry.state =
        approved ? GuestApprovalState.approved : GuestApprovalState.denied;
    entry.decision.complete(approved);
    if (!approved) {
      entry.sessionActive = false;
      entry.accessToken = null;
      _log(
        'Approval | Denied',
        details:
            'key=${entry.key.value} roomSessionId=${entry.key.roomSessionId} '
            'guestPeerId=${entry.key.guestPeerId} '
            'connectionAttemptId=${entry.key.connectionAttemptId} reason=$reason',
      );
      return null;
    }

    final token = _tokenFactory();
    entry.accessToken = token;
    entry.sessionActive = true;
    _byToken[token] = entry;
    _log(
      'Approval | Granted',
      details:
          'key=${entry.key.value} roomSessionId=${entry.key.roomSessionId} '
          'guestPeerId=${entry.key.guestPeerId} '
          'connectionAttemptId=${entry.key.connectionAttemptId} '
          'token=${_tokenPreview(token)} reason=$reason',
    );
    return GuestAccessGrant(
      accessToken: token,
      roomSessionId: entry.key.roomSessionId,
      guestPeerId: entry.key.guestPeerId,
      connectionAttemptId: entry.key.connectionAttemptId,
      displayName: entry.displayName,
    );
  }

  /// Validate guest HTTP access for this connection attempt.
  bool isAccessAllowed({
    required String? accessToken,
    required String? guestPeerId,
    required String? connectionAttemptId,
  }) {
    if (accessToken != null && accessToken.isNotEmpty) {
      final entry = _byToken[accessToken];
      if (entry == null || !entry.sessionActive || !entry.isApproved) {
        _log(
          'Approval | Stale token rejected',
          details:
              'token=${_tokenPreview(accessToken)} guestPeerId=$guestPeerId '
              'connectionAttemptId=$connectionAttemptId',
        );
        return false;
      }
      if (connectionAttemptId != null &&
          connectionAttemptId.isNotEmpty &&
          connectionAttemptId != entry.key.connectionAttemptId &&
          !_entryAcceptsAttempt(entry, connectionAttemptId)) {
        _log(
          'Approval | Stale token rejected',
          details:
              'token=${_tokenPreview(accessToken)} reason=attempt_mismatch '
              'tokenAttempt=${entry.key.connectionAttemptId} '
              'requestAttempt=$connectionAttemptId',
        );
        return false;
      }
      return true;
    }

    if (guestPeerId != null &&
        guestPeerId.isNotEmpty &&
        connectionAttemptId != null &&
        connectionAttemptId.isNotEmpty) {
      final alias = _peerAttemptAlias(guestPeerId, connectionAttemptId);
      final keyValue = _aliasToKey[alias] ?? _aliasToKey[guestPeerId];
      final entry = keyValue != null ? _byKey[keyValue] : null;
      if (entry != null &&
          entry.sessionActive &&
          entry.isApproved &&
          _entryAcceptsAttempt(entry, connectionAttemptId)) {
        return true;
      }
    }

    return false;
  }

  GuestAccessGrant? grantForEntry(GuestApprovalEntry entry) {
    if (!entry.isApproved || entry.accessToken == null || !entry.sessionActive) {
      return null;
    }
    return GuestAccessGrant(
      accessToken: entry.accessToken!,
      roomSessionId: entry.key.roomSessionId,
      guestPeerId: entry.key.guestPeerId,
      connectionAttemptId: entry.key.connectionAttemptId,
      displayName: entry.displayName,
    );
  }

  /// End one guest connection attempt without affecting other guests.
  void invalidateEntry({
    required GuestApprovalEntry entry,
    required String reason,
  }) {
    _log(
      'Approval | Guest disconnected/exited',
      details:
          'key=${entry.key.value} roomSessionId=${entry.key.roomSessionId} '
          'guestPeerId=${entry.key.guestPeerId} '
          'connectionAttemptId=${entry.key.connectionAttemptId} reason=$reason',
    );
    if (entry.accessToken != null) {
      _log(
        'Approval | Token invalidated',
        details:
            'token=${_tokenPreview(entry.accessToken!)} key=${entry.key.value} '
            'reason=$reason',
      );
    }
    _removeEntry(entry, reason: reason);
  }

  /// Invalidate by peer + attempt (preferred) or any active session for peer.
  bool invalidateGuest({
    String? guestPeerId,
    String? connectionAttemptId,
    String? accessToken,
    required String reason,
  }) {
    GuestApprovalEntry? entry;
    if (accessToken != null && accessToken.isNotEmpty) {
      entry = _byToken[accessToken];
    }
    if (entry == null &&
        guestPeerId != null &&
        guestPeerId.isNotEmpty &&
        connectionAttemptId != null &&
        connectionAttemptId.isNotEmpty) {
      final alias = _peerAttemptAlias(guestPeerId, connectionAttemptId);
      final keyValue = _aliasToKey[alias];
      if (keyValue != null) entry = _byKey[keyValue];
    }
    if (entry == null && guestPeerId != null && guestPeerId.isNotEmpty) {
      entry = _findActiveEntryForPeer(guestPeerId);
    }
    if (entry == null) {
      _log(
        'Approval | Invalidate missed',
        details:
            'guestPeerId=$guestPeerId connectionAttemptId=$connectionAttemptId '
            'reason=$reason',
      );
      return false;
    }
    invalidateEntry(entry: entry, reason: reason);
    return true;
  }

  /// Temporary BLE blip: same device still has an active HTTP session.
  GuestApprovalEntry? findActiveSessionForBleDevice(String bleDeviceId) {
    final normalized = bleDeviceId.startsWith('ble:')
        ? bleDeviceId
        : 'ble:$bleDeviceId';
    final keyValue = _aliasToKey[normalized] ?? _aliasToKey[bleDeviceId];
    if (keyValue == null) return null;
    final entry = _byKey[keyValue];
    if (entry != null && entry.sessionActive && entry.isApproved) {
      return entry;
    }
    return null;
  }

  void bindHttpIdentity({
    required GuestApprovalEntry entry,
    required String guestPeerId,
    required String connectionAttemptId,
  }) {
    _bindAlias(guestPeerId, entry);
    _bindAlias(_peerAttemptAlias(guestPeerId, connectionAttemptId), entry);
    entry.httpJoined = true;
  }

  // ── internals ───────────────────────────────────────────────────────────

  GuestApprovalBeginResult _reuse(
    GuestApprovalEntry existing, {
    required GuestApprovalSource source,
    required String displayName,
  }) {
    if (existing.displayName.trim().isEmpty) {
      existing.displayName = displayName;
    }

    if (existing.isApproved && existing.sessionActive) {
      _log(
        'Approval | Reused approved session/token',
        details:
            'key=${existing.key.value} source=${source.label} '
            'name=$displayName token=${_tokenPreview(existing.accessToken)}',
      );
      return GuestApprovalBeginResult(
        kind: GuestApprovalOutcomeKind.alreadyApproved,
        entry: existing,
        emitUiEvent: false,
      );
    }

    if (existing.isApproved && !existing.sessionActive) {
      // Should have been removed; treat as new path by falling through — but
      // callers should have invalidated. Force remove and signal created.
      _removeEntry(existing, reason: 'inactive_approved_reuse_blocked');
      _log(
        'Approval | Stale approved entry cleared',
        details: 'key=${existing.key.value} source=${source.label}',
      );
    }

    if (existing.isDenied) {
      _log(
        'Approval | Reused denied decision',
        details:
            'key=${existing.key.value} source=${source.label} '
            'name=$displayName',
      );
      return GuestApprovalBeginResult(
        kind: GuestApprovalOutcomeKind.alreadyDenied,
        entry: existing,
        emitUiEvent: false,
      );
    }

    final kind = source == existing.source
        ? GuestApprovalOutcomeKind.ignoredDuplicate
        : GuestApprovalOutcomeKind.reusedPending;

    _log(
      kind == GuestApprovalOutcomeKind.ignoredDuplicate
          ? 'Approval | Ignored duplicate approval event'
          : 'Approval | Reused pending approval',
      details:
          'key=${existing.key.value} source=${source.label} '
          'originalSource=${existing.source.label} name=$displayName',
    );

    return GuestApprovalBeginResult(
      kind: kind,
      entry: existing,
      emitUiEvent: false,
    );
  }

  /// Exact key, or peer|attempt alias, or pending-only peer alias (in-flight).
  GuestApprovalEntry? _lookupExactOrPending(
    GuestApprovalKey key,
    String guestPeerId,
  ) {
    final direct = _byKey[key.value];
    if (direct != null) return direct;

    final viaExactAlias = _aliasToKey[key.value];
    if (viaExactAlias != null) {
      final entry = _byKey[viaExactAlias];
      if (entry != null) return entry;
    }

    final viaPeerAttempt =
        _aliasToKey[_peerAttemptAlias(guestPeerId, key.connectionAttemptId)];
    if (viaPeerAttempt != null) {
      final entry = _byKey[viaPeerAttempt];
      if (entry != null) return entry;
    }

    // Peer-only alias: ONLY while pending (BLE↔HTTP bridge in flight).
    // Never reuse approved/denied across a new connectionAttemptId.
    final viaPeer = _aliasToKey[guestPeerId];
    if (viaPeer != null) {
      final entry = _byKey[viaPeer];
      if (entry != null && entry.isPending) {
        return entry;
      }
    }
    return null;
  }

  GuestApprovalEntry? _findAnyEntryForPeer(String guestPeerId) {
    final viaPeer = _aliasToKey[guestPeerId];
    if (viaPeer != null) {
      final entry = _byKey[viaPeer];
      if (entry != null) return entry;
    }
    for (final entry in _byKey.values) {
      if (entry.key.guestPeerId == guestPeerId ||
          entry.aliases.contains(guestPeerId)) {
        return entry;
      }
    }
    return null;
  }

  GuestApprovalEntry? _findActiveEntryForPeer(String guestPeerId) {
    final entry = _findAnyEntryForPeer(guestPeerId);
    if (entry != null && entry.sessionActive && entry.isApproved) return entry;
    return null;
  }

  /// Prefer a recent BLE entry in this room that HTTP can attach to.
  ///
  /// Never attach a *different* guest's registration onto an unrelated pending
  /// approval — only bridge when names match or there is a single open BLE
  /// handshake waiting for its HTTP /join.
  GuestApprovalEntry? _findBleBridgeCandidate({required String displayName}) {
    final openEntries = _byKey.values
        .where((e) => e.source == GuestApprovalSource.ble)
        .where((e) => !e.httpJoined)
        .where((e) => e.isPending || (e.isApproved && e.sessionActive))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (openEntries.isEmpty) return null;

    final normalized = displayName.trim().toLowerCase();
    for (final entry in openEntries) {
      final bleName = entry.displayName.trim().toLowerCase();
      if (normalized.isNotEmpty &&
          bleName.isNotEmpty &&
          !_isPlaceholderName(bleName) &&
          bleName == normalized) {
        return entry;
      }
    }

    // Platform hosts often send placeholder BLE names ("Unknown Peer" / "BLE Peer").
    // If exactly one BLE handshake is open, that is this guest's connection attempt.
    if (openEntries.length == 1) {
      return openEntries.first;
    }

    final approvedOpen =
        openEntries.where((e) => e.isApproved && e.sessionActive).toList();
    if (approvedOpen.length == 1) return approvedOpen.first;

    return null;
  }

  /// Prefer a pending HTTP/registration entry that BLE can attach to.
  ///
  /// Only used when BLE notify arrives after /join for the *same* guest.
  GuestApprovalEntry? _findHttpBridgeCandidate({required String displayName}) {
    final openEntries = _byKey.values
        .where(
          (e) =>
              e.source == GuestApprovalSource.http ||
              e.source == GuestApprovalSource.registration ||
              e.source == GuestApprovalSource.polling,
        )
        .where((e) => e.isPending)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (openEntries.isEmpty) return null;

    final normalized = displayName.trim().toLowerCase();
    for (final entry in openEntries) {
      final name = entry.displayName.trim().toLowerCase();
      if (normalized.isNotEmpty &&
          name.isNotEmpty &&
          !_isPlaceholderName(name) &&
          !_isPlaceholderName(normalized) &&
          name == normalized) {
        return entry;
      }
    }

    // Placeholder BLE name + exactly one pending HTTP join → same attempt.
    if (openEntries.length == 1 && _isPlaceholderName(normalized)) {
      return openEntries.first;
    }

    return null;
  }

  GuestApprovalBeginResult _attachAndReuse(
    GuestApprovalEntry bridged, {
    required String guestPeerId,
    required String connectionAttemptId,
    required String displayName,
    required GuestApprovalSource source,
    required String httpKey,
  }) {
    _bindAlias(guestPeerId, bridged);
    _bindAlias(httpKey, bridged);
    _bindAlias(_peerAttemptAlias(guestPeerId, connectionAttemptId), bridged);
    if (source == GuestApprovalSource.http ||
        source == GuestApprovalSource.registration ||
        source == GuestApprovalSource.polling) {
      bridged.httpJoined = true;
    }
    if (bridged.displayName.trim().isEmpty ||
        _isPlaceholderName(bridged.displayName.trim().toLowerCase())) {
      bridged.displayName = displayName;
    }
    _log(
      'Approval | Bridged cross-source approval',
      details:
          'key=${bridged.key.value} aliasKey=$httpKey '
          'source=${source.label} state=${bridged.state.name} name=$displayName',
    );
    return _reuse(bridged, source: source, displayName: displayName);
  }

  static bool _isPlaceholderName(String lower) =>
      lower.isEmpty ||
      lower == 'unknown peer' ||
      lower == 'unknown device' ||
      lower == 'ble peer' ||
      lower == 'someone';

  bool _entryAcceptsAttempt(GuestApprovalEntry entry, String attemptId) {
    if (entry.key.connectionAttemptId == attemptId) return true;
    return entry.aliases.contains(_peerAttemptAlias(entry.key.guestPeerId, attemptId)) ||
        entry.aliases.any((a) => a.endsWith('|$attemptId'));
  }

  void _bindAlias(String alias, GuestApprovalEntry entry) {
    if (alias.trim().isEmpty) return;
    entry.aliases.add(alias);
    _aliasToKey[alias] = entry.key.value;
  }

  void _removeEntry(GuestApprovalEntry entry, {required String reason}) {
    if (entry.isPending && !entry.decision.isCompleted) {
      entry.decision.complete(false);
      entry.state = GuestApprovalState.denied;
    }
    entry.sessionActive = false;
    final token = entry.accessToken;
    if (token != null) {
      _byToken.remove(token);
      entry.accessToken = null;
    }
    _byKey.remove(entry.key.value);
    for (final alias in entry.aliases) {
      if (_aliasToKey[alias] == entry.key.value) {
        _aliasToKey.remove(alias);
      }
    }
    _aliasToKey.remove(entry.key.value);
    _log(
      'Approval | Pending entry removed',
      details: 'key=${entry.key.value} reason=$reason',
    );
  }

  static String _peerAttemptAlias(String peerId, String attemptId) =>
      '$peerId|$attemptId';

  static String _defaultToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return 'atk-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String _tokenPreview(String? token) {
    if (token == null || token.isEmpty) return '(none)';
    if (token.length <= 12) return token;
    return '${token.substring(0, 12)}…';
  }
}
