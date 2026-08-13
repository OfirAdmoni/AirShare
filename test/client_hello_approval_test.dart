import 'package:air_share/client_hello.dart';
import 'package:air_share/guest_approval_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClientHello identity payload', () {
    test('encodes guestPeerId and displayName', () {
      final json = ClientHello.encode(
        peerId: 'peer-abc',
        displayName: 'Rotem iPhone',
      );
      final parsed = ClientHello.tryParse(json);
      expect(parsed, isNotNull);
      expect(parsed!.peerId, 'peer-abc');
      expect(parsed.displayName, 'Rotem iPhone');
    });
  });

  group('one approval per connection attempt', () {
    late GuestApprovalRegistry registry;
    late List<String> logs;

    setUp(() {
      logs = <String>[];
      registry = GuestApprovalRegistry(
        log: (message, {details}) {
          logs.add(details == null ? message : '$message | $details');
        },
      );
      registry.startRoomSession('room-1');
    });

    int createdCount() =>
        logs.where((l) => l.contains('Created new approval')).length;

    test('BLE then HTTP join with name update emits UI only once', () {
      final ble = registry.begin(
        guestPeerId: 'ble:AA:BB',
        connectionAttemptId: 'ble-1',
        displayName: 'Unknown Peer',
        source: GuestApprovalSource.ble,
      );
      expect(ble.emitUiEvent, isTrue);
      expect(ble.kind, GuestApprovalOutcomeKind.createdNew);

      registry.resolve(
        entry: ble.entry,
        approved: true,
        reason: 'host_approved',
      );

      final http = registry.begin(
        guestPeerId: 'local-guest-1',
        connectionAttemptId: 'attempt-1001',
        displayName: 'Rotem iPhone',
        source: GuestApprovalSource.registration,
      );

      expect(http.emitUiEvent, isFalse);
      expect(http.kind, GuestApprovalOutcomeKind.alreadyApproved);
      expect(http.entry.key.connectionAttemptId, 'ble-1');
      expect(http.entry.displayName, 'Rotem iPhone');
      expect(createdCount(), 1);
      expect(
        logs.any((l) => l.contains('displayName updated in existing entry')),
        isTrue,
      );
      expect(
        logs.any((l) => l.contains('Approved entry metadata updated')),
        isTrue,
      );
      expect(registry.isAccessAllowed(
        accessToken: http.entry.accessToken,
        guestPeerId: 'local-guest-1',
        connectionAttemptId: 'attempt-1001',
      ), isTrue);
    });

    test('displayName update never creates a new connectionAttemptId', () {
      final first = registry.begin(
        guestPeerId: 'ble:AA',
        connectionAttemptId: 'ble-late',
        displayName: 'Unknown Peer',
        source: GuestApprovalSource.ble,
      );
      final second = registry.begin(
        guestPeerId: 'ble:AA',
        connectionAttemptId: 'ble-late',
        displayName: 'MacBook Pro',
        source: GuestApprovalSource.ble,
      );
      expect(second.emitUiEvent, isFalse);
      expect(second.entry.key.connectionAttemptId, first.entry.key.connectionAttemptId);
      expect(second.entry.displayName, 'MacBook Pro');
      expect(createdCount(), 1);
    });
  });
}
