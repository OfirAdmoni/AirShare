import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:air_share/ble_transport.dart';
import 'package:air_share/connection_logger.dart';
import 'package:air_share/guest_approval_registry.dart';
import 'package:air_share/onboarding_page.dart';
import 'package:air_share/settings_page.dart';
import 'package:air_share/discovery_page.dart';
import 'package:air_share/file_list_screen.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_endpoint_state.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/sender_staging_page.dart';
import 'package:air_share/ux_prompts.dart';

/// 220 ms fade for all secondary screens, consistent across Android & Windows.
PageRouteBuilder<T> _fadeRoute<T>(Widget page) => PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );

void main() {
  runApp(const AirShareApp());
}

class AirShareApp extends StatefulWidget {
  const AirShareApp({super.key});

  @override
  State<AirShareApp> createState() => _AirShareAppState();
}

class _AirShareAppState extends State<AirShareApp> {
  final HubStatus _hubStatus = HubStatus();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<FileZoneSession?> _fileZoneSession =
      ValueNotifier<FileZoneSession?>(null);

  /// null = still loading; false = show onboarding; true = show home.
  bool? _onboardingDone;

  /// Prevents stacking multiple BLE Connection Request dialogs.
  bool _connectionRequestDialogOpen = false;

  @override
  void initState() {
    super.initState();
    ConnectionLogger.instance.initialize();
    ConnectionLogger.instance.log('Application Start');
    _checkOnboarding();
    BleTransport.instance.setUiHandler((call) async {
      if (call.method != 'notifyConnectionRequest') {
        return null;
      }
      final args = call.arguments as Map<dynamic, dynamic>? ?? {};
      final friendlyName = (args['friendlyName'] ?? 'Unknown Device')
          .toString();
      final deviceAddress = (args['deviceAddress'] ?? args['centralId'] ?? '')
          .toString()
          .trim();
      final connectionAttemptId =
          (args['connectionAttemptId'] ?? args['sessionId'] ?? '')
              .toString()
              .trim();

      final begin = LocalHubRuntime.instance.beginBleGuestApproval(
        bleDeviceId: deviceAddress.isEmpty ? friendlyName : deviceAddress,
        displayName: friendlyName,
        connectionAttemptId:
            connectionAttemptId.isEmpty ? null : connectionAttemptId,
      );

      await ConnectionLogger.instance.log(
        'Connection Request Prompted',
        details:
            'peer=$friendlyName key=${begin.entry.key.value} kind=${begin.kind.name}',
      );

      if (!begin.emitUiEvent) {
        await ConnectionLogger.instance.log(
          'BLE | Approval dialog suppressed (deduped)',
          details:
              'peer=$friendlyName key=${begin.entry.key.value} kind=${begin.kind.name}',
        );
        if (begin.kind == GuestApprovalOutcomeKind.alreadyApproved) {
          LocalHubRuntime.instance.grantGuestHttpAccess(
            reason: 'ble_already_approved key=${begin.entry.key.value}',
          );
          await BleTransport.instance.approveConnection(
            approved: true,
            lanIp: HubEndpointState.instance.rememberedLanIp.isNotEmpty
                ? HubEndpointState.instance.rememberedLanIp
                : (HubEndpointState.instance.pendingIp ?? ''),
          );
        }
        return null;
      }

      if (_connectionRequestDialogOpen) {
        await ConnectionLogger.instance.log(
          'Approval | Ignored duplicate approval event',
          details:
              'source=BLE reason=dialog_already_open key=${begin.entry.key.value}',
        );
        return null;
      }

      await ConnectionLogger.instance.log(
        'BLE | Approval dialog shown',
        details: 'peer=$friendlyName key=${begin.entry.key.value}',
      );
      if (!mounted) return null;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return null;
      _connectionRequestDialogOpen = true;
      final approved = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          // backgroundColor, shape and text styles from global DialogTheme.
          title: const Text('Connection Request'),
          content: Text('Device $friendlyName wants to connect. Allow?'),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF0A2463).withValues(alpha: 0.55),
              ),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Decline'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Approve'),
            ),
          ],
        ),
      );
      _connectionRequestDialogOpen = false;
      var lanForBle = '';
      final didApprove = approved == true;
      LocalHubRuntime.instance.resolveGuestApproval(
        entry: begin.entry,
        approved: didApprove,
        reason: didApprove
            ? 'ble_approved peer=$friendlyName'
            : 'ble_declined peer=$friendlyName',
      );
      if (didApprove) {
        final hubState = HubEndpointState.instance;
        final pendingIp = hubState.pendingIp;
        final pendingPort = hubState.pendingPort;
        lanForBle = hubState.rememberedLanIp.isNotEmpty
            ? hubState.rememberedLanIp
            : (pendingIp ?? '');
        await ConnectionLogger.instance.log(
          'HS | Host | Approve tapped',
          details:
              'pendingIp=${pendingIp ?? "(null)"} lan_ip=$lanForBle pendingPort=$pendingPort key=${begin.entry.key.value}',
        );
        if (lanForBle.isNotEmpty) {
          await BleTransport.instance.updateHubEndpoint(
            ip: lanForBle,
            port: pendingPort,
          );
          await BleTransport.instance.updateConnectionEndpoints(
            lanIp: lanForBle,
            p2pIp: hubState.rememberedP2pIp,
            p2pMac: hubState.rememberedP2pMac,
            hotspotSsid: hubState.rememberedHotspotSsid,
            hotspotPass: hubState.rememberedHotspotPass,
            hotspotHubIp: hubState.rememberedHotspotHubIp,
            hubPort: pendingPort,
          );
          await ConnectionLogger.instance.log(
            'HS | Host | BLE handshake refreshed for Approve',
            details: 'lan_ip=$lanForBle hub_port=$pendingPort',
          );
        } else {
          await ConnectionLogger.instance.log(
            'HS | Host | Approve BLE refresh SKIPPED',
            details: 'no LAN IP — handshake JSON may lack lan_ip',
          );
        }
      }
      await BleTransport.instance.approveConnection(
        approved: didApprove,
        lanIp: lanForBle,
      );
      await ConnectionLogger.instance.log(
        'Connection Request Decision',
        details: didApprove
            ? 'approved key=${begin.entry.key.value}'
            : 'declined key=${begin.entry.key.value}',
      );
      return null;
    });
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _onboardingDone = prefs.getBool('onboarding_done') ?? false;
    });
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (!mounted) return;
    setState(() => _onboardingDone = true);
  }

  @override
  void dispose() {
    _fileZoneSession.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show nothing while prefs load (usually < 1 frame).
    final Widget home = switch (_onboardingDone) {
      null => const SizedBox.shrink(),
      false => OnboardingPage(onComplete: _completeOnboarding),
      true => const ModeSelectionPage(),
    };

    return HubStatusScope(
      status: _hubStatus,
      child: FileZoneSessionScope(
        notifier: _fileZoneSession,
        child: MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'AirShare',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2563EB),
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFDBEAFE),
            // Global dialog theme — every AlertDialog inherits these automatically.
            dialogTheme: const DialogThemeData(
              backgroundColor: Color(0xFFF3E8FF),
              titleTextStyle: TextStyle(
                color: Color(0xFF0A2463),
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
              contentTextStyle: TextStyle(
                color: Color(0xFF0A2463),
                fontSize: 14,
                height: 1.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(20)),
              ),
            ),
            // Dark Navy is the neutral/info default; success and error callers
            // override backgroundColor explicitly.
            snackBarTheme: const SnackBarThemeData(
              backgroundColor: Color(0xFF0A2463),
              contentTextStyle: TextStyle(color: Colors.white),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ),
          home: home,
        ),
      ),
    );
  }
}

class ModeSelectionPage extends StatefulWidget {
  const ModeSelectionPage({super.key});

  @override
  State<ModeSelectionPage> createState() => _ModeSelectionPageState();
}

class _ModeSelectionPageState extends State<ModeSelectionPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UxPrompts.promptBluetoothOnLaunch(context);
    });
  }

  Future<void> _openJoin() async {
    final btReady =
        await UxPrompts.promptBluetoothRequiredForTransfer(context);
    if (!btReady) return;
    ConnectionLogger.instance.log('Join Session Flow Opened');
    if (!mounted) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (discoveryContext) => DiscoveryPage(
          onEndpointReady: (endpoint) async {
            if (!discoveryContext.mounted) return;
            final n = FileZoneSessionScope.of(discoveryContext);
            final navigator = Navigator.of(discoveryContext);
            await ConnectionLogger.instance.log(
              'Connection | Triggering auto-connect',
              details: 'hub=${endpoint.ip}:${endpoint.port}',
            );
            if (!navigator.mounted) return;
            n.value = FileZoneSession(
              hubHost: endpoint.ip,
              hubPort: endpoint.port,
            );
            await navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => FileListScreen(
                  hubHost: endpoint.ip,
                  hubPort: endpoint.port,
                  modeTitle: 'Join Session',
                  isHubMode: false,
                ),
              ),
            );
            n.value = null;
          },
        ),
      ),
    );
  }

  Future<void> _openHost() async {
    final btReady =
        await UxPrompts.promptBluetoothRequiredForTransfer(context);
    if (!btReady) return;
    ConnectionLogger.instance.log('Host Session Flow Opened');
    if (!mounted) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SenderStagingPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        foregroundColor: const Color(0xFF0A2463),
        iconTheme: const IconThemeData(color: Color(0xFF0A2463)),
        actionsIconTheme: const IconThemeData(color: Color(0xFF0A2463)),
        title: Text(
          'AirShare',
          style: tt.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: const Color(0xFF0A2463),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            iconSize: 28,
            icon: const Icon(
              Icons.settings_outlined,
              color: Color(0xFF0A2463),
            ),
            onPressed: () => Navigator.of(context)
                .push<void>(_fadeRoute(const SettingsPage())),
          ),
          PopupMenuButton<_HomeMenuAction>(
            tooltip: 'More options',
            onSelected: (action) {
              switch (action) {
                case _HomeMenuAction.history:
                  Navigator.of(context)
                      .push<void>(_fadeRoute(const ConnectionLogPage()));
                case _HomeMenuAction.manual:
                  Navigator.of(context)
                      .push<void>(_fadeRoute(const ManualConnectionPage()));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _HomeMenuAction.history,
                child: ListTile(
                  leading: Icon(Icons.history_outlined),
                  title: Text('Transfer History'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _HomeMenuAction.manual,
                child: ListTile(
                  leading: Icon(Icons.link_outlined),
                  title: Text('Connect Manually'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: const Alignment(0, -0.85),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    children: [
                      Text(
                        'Air it, Share it',
                        textAlign: TextAlign.center,
                        style: tt.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: const Color(0xFF0A2463),
                          fontSize: 40,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Join an existing session or start a new one with nearby devices.',
                        textAlign: TextAlign.center,
                        style: tt.bodyLarge?.copyWith(
                          color: const Color(0xFF1E40AF),
                          fontSize: 17,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 40),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isCompact = constraints.maxWidth < 560;
                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _SessionCard(
                                icon: Icons.sensors,
                                title: 'Join a Session',
                                description: 'Connect to a friend',
                                ctaLabel: 'Join Now',
                                gradientColors: const [
                                  Color(0xFF1E40AF),
                                  Color(0xFF3B82F6),
                                ],
                                onTap: _openJoin,
                                isCompact: isCompact,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _SessionCard(
                                icon: Icons.wifi_tethering,
                                title: 'Start Sharing',
                                description: 'Share with anyone nearby',
                                ctaLabel: 'Host Now',
                                gradientColors: const [
                                  Color(0xFF5B21B6),
                                  Color(0xFF8B5CF6),
                                ],
                                onTap: _openHost,
                                isCompact: isCompact,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _HomeMenuAction { history, manual }

class _SessionCard extends StatefulWidget {
  const _SessionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.ctaLabel,
    required this.gradientColors,
    required this.onTap,
    this.isCompact = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String ctaLabel;
  final List<Color> gradientColors;
  final VoidCallback onTap;
  final bool isCompact;

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final accentColor = widget.gradientColors.last;
    final hPad = widget.isCompact ? 14.0 : 28.0;
    final vPad = widget.isCompact ? 20.0 : 30.0;
    final iconBoxSize = widget.isCompact ? 48.0 : 64.0;
    final iconSize = widget.isCompact ? 26.0 : 34.0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.gradientColors,
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(
                  alpha: _pressed ? 0.15 : (_hovered ? 0.50 : 0.32),
                ),
                blurRadius: _pressed ? 4 : (_hovered ? 26 : 16),
                spreadRadius: _pressed ? -2 : (_hovered ? 2 : 0),
                offset: Offset(0, _pressed ? 2 : (_hovered ? 10 : 6)),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                widget.onTap();
              },
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              borderRadius: BorderRadius.circular(24),
              splashColor: Colors.white.withValues(alpha: 0.18),
              highlightColor: Colors.white.withValues(alpha: 0.06),
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: iconBoxSize,
                        height: iconBoxSize,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          widget.icon,
                          size: iconSize,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: widget.isCompact ? 12 : 20),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.title,
                          style: (widget.isCompact
                                  ? tt.titleLarge
                                  : tt.headlineSmall)
                              ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            height: 1.2,
                          ),
                        ),
                      ),
                      SizedBox(height: widget.isCompact ? 6 : 10),
                      Text(
                        widget.description,
                        style: (widget.isCompact ? tt.bodySmall : tt.bodyMedium)
                            ?.copyWith(
                          color: Colors.white.withValues(alpha: 0.78),
                          height: 1.55,
                        ),
                        maxLines: widget.isCompact ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: widget.isCompact ? 12 : 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.20),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.ctaLabel,
                                  style: tt.labelMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.arrow_forward_ios,
                                  size: 13,
                                  color: Colors.white,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ManualConnectionPage extends StatefulWidget {
  const ManualConnectionPage({super.key});

  @override
  State<ManualConnectionPage> createState() => _ManualConnectionPageState();
}

class _ManualConnectionPageState extends State<ManualConnectionPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController(
    text: '8080',
  );
  bool _connecting = false;

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (ip.isEmpty || port == null || port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid IP and port'),
          backgroundColor: Color(0xFFDC2626),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    setState(() => _connecting = true);
    await ConnectionLogger.instance.log(
      'Socket Connection Attempt',
      details: 'manual target=$ip:$port',
    );
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 3),
      );
      await socket.close();
      await ConnectionLogger.instance.log(
        'Socket Connection Success',
        details: '$ip:$port',
      );
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Socket Connection Failed',
        details: e.toString(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection check failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 4),
        ),
      );
      setState(() => _connecting = false);
      return;
    }

    if (!mounted) return;
    final notifier = FileZoneSessionScope.of(context);
    final navigator = Navigator.of(context);
    notifier.value = FileZoneSession(hubHost: ip, hubPort: port);
    await ConnectionLogger.instance.log(
      'Manual Session Initialized',
      details: '$ip:$port',
    );
    if (!navigator.mounted) {
      notifier.value = null;
      return;
    }
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FileListScreen(
          hubHost: ip,
          hubPort: port,
          modeTitle: 'Manual Connection',
          isHubMode: false,
        ),
      ),
    );
    notifier.value = null;
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manual Connection')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'IP Address',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: const Icon(Icons.power),
              label: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

class ConnectionLogPage extends StatefulWidget {
  const ConnectionLogPage({super.key});

  @override
  State<ConnectionLogPage> createState() => _ConnectionLogPageState();
}

class _ConnectionLogPageState extends State<ConnectionLogPage> {
  bool _clearing = false;
  bool _sharing = false;
  bool _returningToMainMenu = false;

  @override
  void dispose() {
    unawaited(ConnectionLogger.instance.log('Logs | Screen disposed'));
    super.dispose();
  }

  Future<void> _returnToMainMenu() async {
    if (_returningToMainMenu) return;
    _returningToMainMenu = true;
    await ConnectionLogger.instance.log('Logs | Return to main menu requested');
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await ConnectionLogger.instance.log(
      'Navigation | Return to main menu completed',
      details: 'from=logs',
    );
  }

  Future<void> _shareLogs() async {
    final lines = ConnectionLogger.instance.entries.value;
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No logs to share'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _sharing = true);
    try {
      if (Platform.isWindows) {
        await Clipboard.setData(ClipboardData(text: lines.join('\n')));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Log copied to clipboard'),
            backgroundColor: Color(0xFF16A34A),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        await ConnectionLogger.instance.shareDisplayedLogs();
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not share logs: ${e.message ?? e.code}'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _clearLogs() async {
    if (!mounted) return;
    setState(() => _clearing = true);
    try {
      await ConnectionLogger.instance.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Logs cleared'),
          backgroundColor: Color(0xFF16A34A),
          duration: Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_returnToMainMenu());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to Main Menu',
            icon: const Icon(Icons.arrow_back),
            onPressed: _returningToMainMenu ? null : _returnToMainMenu,
          ),
          title: const Text('Connection Audit Log'),
          actions: [
            IconButton(
              tooltip: 'Share Logs',
              onPressed: _sharing || _clearing || _returningToMainMenu
                  ? null
                  : _shareLogs,
              icon: _sharing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share_outlined),
            ),
            IconButton(
              tooltip: 'Clear Logs',
              onPressed: _clearing || _sharing || _returningToMainMenu
                  ? null
                  : _clearLogs,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: ValueListenableBuilder<List<String>>(
          valueListenable: ConnectionLogger.instance.entries,
          builder: (context, lines, _) {
            if (lines.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_outlined,
                        size: 72,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'No transfer history yet.',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your sent and received files will appear here.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: lines.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(lines[index], style: const TextStyle(fontSize: 12)),
              ),
            );
          },
        ),
      ),
    );
  }
}
