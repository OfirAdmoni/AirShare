import 'package:air_share/guest_approval_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late GuestApprovalRegistry registry;
  late List<String> logs;
  var tokenSeq = 0;

  setUp(() {
    logs = <String>[];
    tokenSeq = 0;
    registry = GuestApprovalRegistry(
      log: (message, {details}) {
        logs.add(details == null ? message : '$message | $details');
      },
      now: () => DateTime.utc(2026, 8, 2, 12, 0, 0),
      tokenFactory: () => 'tok-${++tokenSeq}',
    );
    registry.startRoomSession('room-test-1');
  });

  int createdApprovalCount() =>
      logs.where((l) => l.contains('Created new approval')).length;

  test('approval key is room|peer|attempt', () {
    final key = registry.composeKey(
      guestPeerId: 'ble:AA:BB',
      connectionAttemptId: 'ble-1',
    );
    expect(key.value, 'room-test-1|ble:AA:BB|ble-1');
  });

  group('Scenario A — fresh room, single guest', () {
    test('exactly one approval dialog for BLE then HTTP join', () {
      final ble = registry.begin(
        guestPeerId: 'ble:AA:BB:CC:DD:EE:FF',
        connectionAttemptId: 'ble-1',
        displayName: 'Guest Phone',
        source: GuestApprovalSource.ble,
      );
      expect(ble.emitUiEvent, isTrue);

      final bleDup = registry.begin(
        guestPeerId: 'ble:AA:BB:CC:DD:EE:FF',
        connectionAttemptId: 'ble-1',
        displayName: 'Guest Phone',
        source: GuestApprovalSource.ble,
      );
      expect(bleDup.emitUiEvent, isFalse);

      registry.resolve(entry: ble.entry, approved: true, reason: 'host_tap');

      final join = registry.begin(
        guestPeerId: 'local-guest-1',
        connectionAttemptId: 'attempt-1001',
        displayName: 'Guest Phone',
        source: GuestApprovalSource.registration,
      );
      expect(join.emitUiEvent, isFalse);
      expect(join.kind, GuestApprovalOutcomeKind.alreadyApproved);
      expect(createdApprovalCount(), 1);
    });
  });

  group('Scenario B — leave home and rejoin same room', () {
    test('requires a new approval after leave', () {
      final first = registry.begin(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-1',
        displayName: 'Mac',
        source: GuestApprovalSource.registration,
      );
      final grant = registry.resolve(
        entry: first.entry,
        approved: true,
        reason: 'ok',
      )!;

      registry.invalidateGuest(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-1',
        accessToken: grant.accessToken,
        reason: 'guest_returned_home',
      );

      expect(
        registry.isAccessAllowed(
          accessToken: grant.accessToken,
          guestPeerId: 'local-1',
          connectionAttemptId: 'attempt-1',
        ),
        isFalse,
      );

      final second = registry.begin(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-2',
        displayName: 'Mac',
        source: GuestApprovalSource.registration,
      );
      expect(second.emitUiEvent, isTrue);
      expect(second.kind, GuestApprovalOutcomeKind.createdNew);
      expect(createdApprovalCount(), 2);
    });
  });

  group('Scenario C — disconnect then reconnect', () {
    test('requires a new approval and rejects old token', () {
      final ble = registry.begin(
        guestPeerId: 'ble:AA',
        connectionAttemptId: 'ble-1',
        displayName: 'Mac',
        source: GuestApprovalSource.ble,
      );
      final grant = registry.resolve(
        entry: ble.entry,
        approved: true,
        reason: 'ok',
      )!;
      registry.bindHttpIdentity(
        entry: ble.entry,
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-1',
      );

      registry.invalidateGuest(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-1',
        accessToken: grant.accessToken,
        reason: 'guest_disconnect',
      );

      final reconnect = registry.begin(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-2',
        displayName: 'Mac',
        source: GuestApprovalSource.registration,
      );
      expect(reconnect.emitUiEvent, isTrue);
      expect(
        registry.isAccessAllowed(
          accessToken: grant.accessToken,
          guestPeerId: 'local-1',
          connectionAttemptId: 'attempt-2',
        ),
        isFalse,
      );
      expect(
        logs.where((l) => l.contains('Stale token rejected')),
        isNotEmpty,
      );
    });
  });

  group('Scenario D — two guests', () {
    test('two independent approval requests', () {
      final a = registry.begin(
        guestPeerId: 'peer-a',
        connectionAttemptId: 'a1',
        displayName: 'Guest A',
        source: GuestApprovalSource.registration,
      );
      final b = registry.begin(
        guestPeerId: 'peer-b',
        connectionAttemptId: 'b1',
        displayName: 'Guest B',
        source: GuestApprovalSource.registration,
      );
      expect(a.emitUiEvent, isTrue);
      expect(b.emitUiEvent, isTrue);
      expect(a.entry.key.value, isNot(b.entry.key.value));
      expect(registry.pendingCount, 2);
      expect(createdApprovalCount(), 2);
    });
  });

  group('Scenario E — repeated BLE + polling', () {
    test('only one approval exists', () {
      final ble = registry.begin(
        guestPeerId: 'ble:AA',
        connectionAttemptId: 'ble-1',
        displayName: 'Unknown Peer',
        source: GuestApprovalSource.ble,
      );
      expect(ble.emitUiEvent, isTrue);

      for (var i = 0; i < 5; i++) {
        final dup = registry.begin(
          guestPeerId: 'ble:AA',
          connectionAttemptId: 'ble-1',
          displayName: 'Unknown Peer',
          source: GuestApprovalSource.ble,
        );
        expect(dup.emitUiEvent, isFalse);
      }

      for (var i = 0; i < 5; i++) {
        final poll = registry.begin(
          guestPeerId: 'local-mac',
          connectionAttemptId: 'attempt-9',
          displayName: 'MacBook',
          source: GuestApprovalSource.polling,
        );
        expect(poll.emitUiEvent, isFalse);
        expect(
          poll.kind == GuestApprovalOutcomeKind.reusedPending ||
              poll.kind == GuestApprovalOutcomeKind.ignoredDuplicate,
          isTrue,
        );
      }

      expect(createdApprovalCount(), 1);
      expect(registry.pendingCount, 1);
    });
  });

  group('Scenario F — background/resume while pending', () {
    test('no duplicate approval on resume callbacks', () {
      final first = registry.begin(
        guestPeerId: 'peer-x',
        connectionAttemptId: 'x1',
        displayName: 'Guest X',
        source: GuestApprovalSource.registration,
      );
      expect(first.emitUiEvent, isTrue);

      // Simulate activity recreation / resume re-posting /join.
      for (var i = 0; i < 3; i++) {
        final resume = registry.begin(
          guestPeerId: 'peer-x',
          connectionAttemptId: 'x1',
          displayName: 'Guest X',
          source: GuestApprovalSource.registration,
        );
        expect(resume.emitUiEvent, isFalse);
        expect(identical(resume.entry, first.entry), isTrue);
      }
      expect(createdApprovalCount(), 1);
    });
  });

  group('Scenario G — Wi-Fi / Hotspot switch reconnect', () {
    test('new connection attempt creates exactly one new approval', () {
      final lan = registry.begin(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-lan',
        displayName: 'Phone',
        source: GuestApprovalSource.registration,
      );
      final grant = registry.resolve(
        entry: lan.entry,
        approved: true,
        reason: 'lan_ok',
      )!;

      // Network path changes → guest leaves and rejoins with new attempt id.
      registry.invalidateGuest(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-lan',
        accessToken: grant.accessToken,
        reason: 'network_path_changed',
      );

      final hotspot = registry.begin(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-hotspot',
        displayName: 'Phone',
        source: GuestApprovalSource.registration,
      );
      expect(hotspot.emitUiEvent, isTrue);
      expect(hotspot.kind, GuestApprovalOutcomeKind.createdNew);
      expect(createdApprovalCount(), 2);
      expect(
        registry.isAccessAllowed(
          accessToken: grant.accessToken,
          guestPeerId: 'local-1',
          connectionAttemptId: 'attempt-hotspot',
        ),
        isFalse,
      );
    });
  });

  test('BLE after HTTP pending bridges without a second dialog', () {
    final join = registry.begin(
      guestPeerId: 'local-1',
      connectionAttemptId: 'attempt-1',
      displayName: 'Mac',
      source: GuestApprovalSource.registration,
    );
    expect(join.emitUiEvent, isTrue);

    final ble = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-late',
      displayName: 'BLE Peer',
      source: GuestApprovalSource.ble,
    );
    expect(ble.emitUiEvent, isFalse);
    expect(identical(ble.entry, join.entry), isTrue);
    expect(createdApprovalCount(), 1);
  });

  test('different guests keep separate approvals after one leaves', () {
    final a = registry.begin(
      guestPeerId: 'peer-a',
      connectionAttemptId: 'a1',
      displayName: 'Guest A',
      source: GuestApprovalSource.registration,
    );
    final b = registry.begin(
      guestPeerId: 'peer-b',
      connectionAttemptId: 'b1',
      displayName: 'Guest B',
      source: GuestApprovalSource.registration,
    );
    final grantA = registry.resolve(entry: a.entry, approved: true, reason: 'a')!;
    final grantB = registry.resolve(entry: b.entry, approved: true, reason: 'b')!;

    registry.invalidateGuest(
      guestPeerId: 'peer-a',
      connectionAttemptId: 'a1',
      accessToken: grantA.accessToken,
      reason: 'guest_leave',
    );

    expect(
      registry.isAccessAllowed(
        accessToken: grantB.accessToken,
        guestPeerId: 'peer-b',
        connectionAttemptId: 'b1',
      ),
      isTrue,
    );
    expect(registry.activeSessionCount, 1);
  });

  test('placeholder BLE name still bridges to guest display name', () {
    final ble = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-1',
      displayName: 'Unknown Peer',
      source: GuestApprovalSource.ble,
    );
    registry.resolve(entry: ble.entry, approved: true, reason: 'ok');

    final join = registry.begin(
      guestPeerId: 'local-ios',
      connectionAttemptId: 'attempt-ios',
      displayName: "Rotem's iPhone",
      source: GuestApprovalSource.registration,
    );
    expect(join.emitUiEvent, isFalse);
    expect(join.kind, GuestApprovalOutcomeKind.alreadyApproved);
    expect(createdApprovalCount(), 1);
  });
}
