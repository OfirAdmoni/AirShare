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
      now: () => DateTime.utc(2026, 7, 31, 12, 0, 0),
      tokenFactory: () => 'tok-${++tokenSeq}',
    );
    registry.startRoomSession('room-test-1');
  });

  test('approval key is room|peer|attempt', () {
    final key = registry.composeKey(
      guestPeerId: 'ble:AA:BB',
      connectionAttemptId: 'ble-1',
    );
    expect(key.value, 'room-test-1|ble:AA:BB|ble-1');
  });

  test(
    'first macOS connection: BLE read+notify then HTTP /join → one UI event',
    () async {
      final ble = registry.begin(
        guestPeerId: 'ble:AA:BB:CC:DD:EE:FF',
        connectionAttemptId: 'ble-1',
        displayName: "Tamir's MacBook Pro",
        source: GuestApprovalSource.ble,
      );
      expect(ble.kind, GuestApprovalOutcomeKind.createdNew);
      expect(ble.emitUiEvent, isTrue);

      final bleDup = registry.begin(
        guestPeerId: 'ble:AA:BB:CC:DD:EE:FF',
        connectionAttemptId: 'ble-1',
        displayName: "Tamir's MacBook Pro",
        source: GuestApprovalSource.ble,
      );
      expect(bleDup.kind, GuestApprovalOutcomeKind.ignoredDuplicate);
      expect(bleDup.emitUiEvent, isFalse);

      final grant = registry.resolve(
        entry: ble.entry,
        approved: true,
        reason: 'ble_approved',
      );
      expect(grant, isNotNull);
      expect(ble.entry.sessionActive, isTrue);

      final join = registry.begin(
        guestPeerId: 'local-mac-peer-1',
        connectionAttemptId: 'attempt-1001',
        displayName: "Tamir's MacBook Pro",
        source: GuestApprovalSource.registration,
      );
      expect(join.emitUiEvent, isFalse);
      expect(join.kind, GuestApprovalOutcomeKind.alreadyApproved);

      final joinAgain = registry.begin(
        guestPeerId: 'local-mac-peer-1',
        connectionAttemptId: 'attempt-1001',
        displayName: "Tamir's MacBook Pro",
        source: GuestApprovalSource.polling,
      );
      expect(joinAgain.emitUiEvent, isFalse);
      expect(joinAgain.kind, GuestApprovalOutcomeKind.alreadyApproved);

      expect(
        logs.where((l) => l.contains('Created new approval')),
        hasLength(1),
      );
    },
  );

  test(
    'Scenario A: exit then reconnect requires new approval; old token rejected',
    () {
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

      expect(
        registry.isAccessAllowed(
          accessToken: grant.accessToken,
          guestPeerId: 'local-1',
          connectionAttemptId: 'attempt-1',
        ),
        isTrue,
      );

      // Guest exits the room.
      registry.invalidateGuest(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-1',
        accessToken: grant.accessToken,
        reason: 'guest_leave',
      );

      expect(
        registry.isAccessAllowed(
          accessToken: grant.accessToken,
          guestPeerId: 'local-1',
          connectionAttemptId: 'attempt-1',
        ),
        isFalse,
      );
      expect(
        logs.where((l) => l.contains('Stale token rejected')),
        isNotEmpty,
      );
      expect(
        logs.where((l) => l.contains('Token invalidated')),
        isNotEmpty,
      );

      // Reconnect with a new connection attempt.
      final reconnect = registry.begin(
        guestPeerId: 'local-1',
        connectionAttemptId: 'attempt-2',
        displayName: 'Mac',
        source: GuestApprovalSource.registration,
      );
      expect(reconnect.kind, GuestApprovalOutcomeKind.createdNew);
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
        logs.where((l) => l.contains('Created new approval')),
        hasLength(2),
      );
    },
  );

  test(
    'Scenario B: disconnecting one guest keeps the other approved',
    () {
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
      final grantA = registry.resolve(
        entry: a.entry,
        approved: true,
        reason: 'a',
      )!;
      final grantB = registry.resolve(
        entry: b.entry,
        approved: true,
        reason: 'b',
      )!;

      registry.invalidateGuest(
        guestPeerId: 'peer-a',
        connectionAttemptId: 'a1',
        accessToken: grantA.accessToken,
        reason: 'guest_leave',
      );

      expect(
        registry.isAccessAllowed(
          accessToken: grantA.accessToken,
          guestPeerId: 'peer-a',
          connectionAttemptId: 'a1',
        ),
        isFalse,
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
    },
  );

  test(
    'Scenario C: retries while pending produce exactly one approval prompt',
    () {
      final first = registry.begin(
        guestPeerId: 'peer-x',
        connectionAttemptId: 'x1',
        displayName: 'Guest X',
        source: GuestApprovalSource.registration,
      );
      expect(first.emitUiEvent, isTrue);

      for (var i = 0; i < 5; i++) {
        final retry = registry.begin(
          guestPeerId: 'peer-x',
          connectionAttemptId: 'x1',
          displayName: 'Guest X',
          source: GuestApprovalSource.polling,
        );
        expect(retry.emitUiEvent, isFalse);
        expect(
          retry.kind == GuestApprovalOutcomeKind.reusedPending ||
              retry.kind == GuestApprovalOutcomeKind.ignoredDuplicate ||
              retry.kind == GuestApprovalOutcomeKind.alreadyApproved,
          isTrue,
        );
      }

      expect(
        logs.where((l) => l.contains('Created new approval')),
        hasLength(1),
      );
    },
  );

  test('different guests get separate approval requests', () {
    final a = registry.begin(
      guestPeerId: 'ble:111',
      connectionAttemptId: 'ble-1',
      displayName: 'Phone A',
      source: GuestApprovalSource.ble,
    );
    final b = registry.begin(
      guestPeerId: 'ble:222',
      connectionAttemptId: 'ble-2',
      displayName: 'Phone B',
      source: GuestApprovalSource.ble,
    );
    expect(a.emitUiEvent, isTrue);
    expect(b.emitUiEvent, isTrue);
    expect(registry.pendingCount, 2);
  });

  test('room/session reset requires a new approval', () {
    final first = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-1',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );
    registry.resolve(entry: first.entry, approved: true, reason: 'ok');

    registry.startRoomSession('room-test-2');
    final second = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-1',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );
    expect(second.kind, GuestApprovalOutcomeKind.createdNew);
    expect(second.emitUiEvent, isTrue);
  });

  test('pending entry stays until approved so later requests dedupe', () async {
    final ble = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-1',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );

    final join = registry.begin(
      guestPeerId: 'local-1',
      connectionAttemptId: 'attempt-9',
      displayName: 'Mac',
      source: GuestApprovalSource.http,
    );
    expect(join.emitUiEvent, isFalse);
    expect(join.kind, GuestApprovalOutcomeKind.reusedPending);

    registry.resolve(entry: ble.entry, approved: true, reason: 'host_tap');
    expect(await join.entry.decision.future, isTrue);
  });

  test('same attempt denied is reused; new attempt asks again', () {
    final ble = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-1',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );
    registry.resolve(entry: ble.entry, approved: false, reason: 'declined');

    final sameAttempt = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-1',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );
    expect(sameAttempt.kind, GuestApprovalOutcomeKind.alreadyDenied);
    expect(sameAttempt.emitUiEvent, isFalse);

    final newAttempt = registry.begin(
      guestPeerId: 'ble:AA',
      connectionAttemptId: 'ble-2',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );
    expect(newAttempt.kind, GuestApprovalOutcomeKind.createdNew);
    expect(newAttempt.emitUiEvent, isTrue);
  });

  test('active BLE session can be found for temporary radio blips', () {
    final ble = registry.begin(
      guestPeerId: 'ble:AA:BB',
      connectionAttemptId: 'ble-9',
      displayName: 'Mac',
      source: GuestApprovalSource.ble,
    );
    registry.resolve(entry: ble.entry, approved: true, reason: 'ok');
    final active = registry.findActiveSessionForBleDevice('AA:BB');
    expect(active, isNotNull);
    expect(active!.sessionActive, isTrue);

    registry.invalidateEntry(entry: ble.entry, reason: 'guest_leave');
    expect(registry.findActiveSessionForBleDevice('AA:BB'), isNull);
  });
}
