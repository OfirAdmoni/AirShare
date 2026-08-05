import 'package:air_share/connection_logger.dart';
import 'package:air_share/guest_connection_guard.dart';
import 'package:air_share/host_network_tier.dart';
import 'package:air_share/hub_auth.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_guest_session.dart';

/// Monotonic session generation — bumps on every full wipe so stale tokens die.
class SessionContext {
  SessionContext._();

  static int _epoch = 0;
  static HostSenderNetworkPlan? _liveNetworkPlan;

  static int get epoch => _epoch;

  /// Sender tier plan from the latest live interface scan for this session.
  static HostSenderNetworkPlan? get liveNetworkPlan => _liveNetworkPlan;

  /// Queries [NetworkInterface] list right now — never reuses a prior plan.
  static Future<HostSenderNetworkPlan> refreshLiveNetworkPlan({
    required String reason,
  }) async {
    HubEndpointState.instance.clear();
    _liveNetworkPlan = await HostNetworkTier.planSenderStartup();
    final plan = _liveNetworkPlan!;
    await ConnectionLogger.instance.log(
      'Session | Live network tier plan',
      details: 'epoch=$_epoch reason=$reason '
          '${plan.useTier1Only ? "Tier 1 only — ${plan.tier1LanIp} on ${plan.pickedInterface ?? "?"}" : "no pre-connected LAN — Tier 2/3 eligible"}',
    );
    return plan;
  }

  /// Guest-side singletons (TLS pin, auth token, connection guard).
  static Future<void> wipeGuestSide({required String reason}) async {
    HubGuestSession.instance.clear();
    GuestConnectionGuard.reset();
    await ConnectionLogger.instance.log(
      'Session | Guest state wiped',
      details: 'epoch=$_epoch reason=$reason',
    );
  }

  /// Host-side auth memory (does not stop the HTTP server).
  /// Attempt-scoped approvals are cleared by [LocalHubRuntime.resetGuestHttpSession].
  static Future<void> wipeHostAuthState({required String reason}) async {
    HubAuth.bindToSessionEpoch(_epoch);
    HubAuth.revokeAll();
    await ConnectionLogger.instance.log(
      'Session | Host auth state wiped',
      details: 'epoch=$_epoch reason=$reason',
    );
  }

  /// Full logical session boundary — call before any new host/guest flow.
  static Future<void> beginNewSession({required String reason}) async {
    _epoch++;
    HubGuestSession.instance.clear();
    GuestConnectionGuard.reset();
    HubAuth.bindToSessionEpoch(_epoch);
    HubAuth.revokeAll();
    await ConnectionLogger.instance.log(
      'Session | New session epoch',
      details: 'epoch=$_epoch reason=$reason',
    );
    await refreshLiveNetworkPlan(reason: reason);
  }
}
