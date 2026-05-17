/// Suppresses discovery / connectivity side-effects while a guest link is forming.
///
/// Wi‑Fi chip state changes (P2P, hotspot join) can restart BLE scan streams or
/// trigger code paths that reset [DiscoveryPage] to "searching". While active,
/// those paths must no-op.
class GuestConnectionGuard {
  GuestConnectionGuard._();

  static int _depth = 0;

  static bool get isActive => _depth > 0;

  static void enter() {
    _depth++;
  }

  static void exit() {
    if (_depth > 0) _depth--;
  }

  static void reset() {
    _depth = 0;
  }
}
