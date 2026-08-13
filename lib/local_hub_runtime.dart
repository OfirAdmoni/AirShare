import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'connection_logger.dart';
import 'guest_approval_registry.dart';
import 'hub_status.dart';
import 'shared_file_entry.dart';
import 'shared_room_manifest.dart';

/// IPv4 all-interfaces listen address. **Not** loopback — required so other phones
/// on the same LAN can open TCP to the hub (Android hub uses Dart [HttpServer]).
final InternetAddress _hubListenAllIPv4 = InternetAddress('0.0.0.0');

/// Metadata sent by the sender before starting a file upload batch.
class TransferApprovalRequest {
  const TransferApprovalRequest({
    required this.senderName,
    required this.fileCount,
    required this.totalBytes,
  });

  final String senderName;
  final int fileCount;
  final int totalBytes;

  Map<String, dynamic> toJson() => {
        'senderName': senderName,
        'fileCount': fileCount,
        'totalBytes': totalBytes,
      };
}

class LocalHubRuntime {
  LocalHubRuntime._();

  static final LocalHubRuntime instance = LocalHubRuntime._();

  HttpServer? _server;
  int _activePort = 8080;
  String? _sharedDirPath;
  bool _loggedFirstInbound = false;
  final StreamController<String> _ingressEventsController =
      StreamController<String>.broadcast();
  final StreamController<void> _firstGuestController =
      StreamController<void>.broadcast();
  final StreamController<String> _guestJoinedController =
      StreamController<String>.broadcast();

  // Transfer approval state — one pending request at a time.
  TransferApprovalRequest? _pendingTransfer;
  Completer<bool>? _decisionCompleter;
  Timer? _approvalTimeoutTimer;

  // Join approval state — one pending join request at a time.
  String? _pendingJoinGuestName;
  Completer<bool>? _joinDecisionCompleter;
  Timer? _joinTimeoutTimer;
  final StreamController<String> _joinRequestController =
      StreamController<String>.broadcast();

  /// Ensures at most one host approval dialog is emitted for a room at a time.
  String? _hostApprovalUiKey;

  /// Room-scoped guest approval dedupe (BLE + HTTP /join share one logical gate).
  late final GuestApprovalRegistry _guestApprovals = GuestApprovalRegistry(
    log: (message, {details}) {
      unawaited(ConnectionLogger.instance.log(message, details: details));
      if (details != null) {
        stdout.writeln('[HubRuntime] $message | $details');
      } else {
        stdout.writeln('[HubRuntime] $message');
      }
    },
  );

  /// Active room/session id used in approval keys (null when hub is stopped).
  String? get roomSessionId => _guestApprovals.roomSessionId;

  /// Test/harness access to the approval registry.
  @visibleForTesting
  GuestApprovalRegistry get guestApprovalRegistry => _guestApprovals;

  TransferApprovalRequest? get pendingTransfer => _pendingTransfer;

  bool get isRunning => _server != null;
  int get activePort => _activePort;
  String? get sharedDirPath => _sharedDirPath;

  /// Ensures [sharedDirPath] exists before any manifest or file I/O.
  Future<void> _ensureSharedDirectoryExists(String sharedDirPath) async {
    final dir = Directory(sharedDirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// Records the room creator on the hub (host-only).
  Future<void> setRoomHostIdentity({
    required String peerId,
    required String displayName,
  }) async {
    final dir = _sharedDirPath ?? await _resolveSharedDirectoryPath();
    await _ensureSharedDirectoryExists(dir);
    final manifest = await SharedRoomManifest.load(dir);
    manifest.setRoomHost(peerId: peerId, displayName: displayName);
    await manifest.save(dir);
  }

  Stream<String> get ingressEvents => _ingressEventsController.stream;
  Stream<void> get firstGuestConnected => _firstGuestController.stream;
  Stream<String> get guestJoined => _guestJoinedController.stream;

  /// Emits the guest's display name whenever a new join request arrives.
  /// The host UI listens to this and calls [respondToJoinRequest] with its decision.
  Stream<String> get joinRequests => _joinRequestController.stream;

  /// Called by the host UI to resolve a pending [joinRequests] event.
  void respondToJoinRequest(bool approved) {
    if (_joinDecisionCompleter != null &&
        !_joinDecisionCompleter!.isCompleted) {
      _joinDecisionCompleter!.complete(approved);
    }
  }

  void resetGuestHttpSession({required String reason}) {
    _guestApprovals.clearAll(reason: reason);
    _hostApprovalUiKey = null;
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest session reset',
        details: reason,
      ),
    );
  }

  /// Legacy helper — prefer [resolveGuestApproval] / registry tokens.
  /// Kept for call sites that only need a log breadcrumb after BLE approve.
  void grantGuestHttpAccess({required String reason}) {
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest access token issued',
        details: reason,
      ),
    );
  }

  void revokeGuestHttpAccess({required String reason}) {
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest access revoked',
        details: reason,
      ),
    );
  }

  /// Invalidate one guest's active connection attempt (leave / disconnect).
  bool invalidateGuestConnection({
    String? guestPeerId,
    String? connectionAttemptId,
    String? accessToken,
    required String reason,
  }) {
    final ok = _guestApprovals.invalidateGuest(
      guestPeerId: guestPeerId,
      connectionAttemptId: connectionAttemptId,
      accessToken: accessToken,
      reason: reason,
    );
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest connection invalidated',
        details:
            'ok=$ok guestPeerId=$guestPeerId '
            'connectionAttemptId=$connectionAttemptId reason=$reason',
      ),
    );
    return ok;
  }

  Future<void> ensureStarted(HubStatus status) async {
    if (isRunning) {
      status.setBroadcasting();
      return;
    }

    resetGuestHttpSession(reason: 'sender_hub_ensureStarted');
    status.setStarting();

    try {
      _sharedDirPath ??= await _resolveSharedDirectoryPath();
      await _ensureSharedDirectoryExists(_sharedDirPath!);
      final sharedDir = Directory(_sharedDirPath!);

      _server = await _bindWithPortFallback(
        address: _hubListenAllIPv4,
        startingPort: 8080,
        maxAttempts: 10,
      );
      _activePort = _server!.port;
      if (_guestApprovals.roomSessionId == null) {
        _guestApprovals.startRoomSession(
          'room-${DateTime.now().millisecondsSinceEpoch}-$_activePort',
        );
      }
      final boundAddr = _server!.address.address;
      await ConnectionLogger.instance.log(
        'HTTP Server Start',
        details:
            'bind=$boundAddr port=$_activePort shared_dir=${sharedDir.path} '
            '(expect bind=0.0.0.0 for LAN guests)',
      );
      await _logHubIpv4Interfaces(bindAddress: boundAddr, port: _activePort);
      stdout.writeln(
        '[HubRuntime] shared directory (serve from): ${sharedDir.path}',
      );
      _server!.listen((request) async {
        try {
          await _routeRequest(request, sharedDir.path);
        } catch (error, stackTrace) {
          stdout.writeln('[HubRuntime] Request handler error: $error');
          stdout.writeln(stackTrace);
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('Internal server error');
          await request.response.close();
        }
      });

      status.setBroadcasting();
      stdout.writeln(
        '[HubRuntime] Sender HTTP server started on port $_activePort',
      );
    } on SocketException catch (error) {
      status.setError('Port binding failed after retries: $error');
      stdout.writeln('[HubRuntime] Port binding issue: $error');
      await stop();
    } on OSError catch (error) {
      status.setError('Permission denied or OS error: $error');
      stdout.writeln('[HubRuntime] OS-level startup issue: $error');
      await stop();
    } catch (error, stackTrace) {
      status.setError('Hub initialization failed: $error');
      stdout.writeln('[HubRuntime] Startup failure: $error');
      stdout.writeln(stackTrace);
      await stop();
    }
  }

  Future<void> stop() async {
    resetGuestHttpSession(reason: 'hub_stop');
    _guestApprovals.clearAll(reason: 'room_closed');
    _hostApprovalUiKey = null;
    _approvalTimeoutTimer?.cancel();
    _approvalTimeoutTimer = null;
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(false);
    }
    _decisionCompleter = null;
    _pendingTransfer = null;
    // Reject any pending join so the guest's HTTP request unblocks.
    _joinTimeoutTimer?.cancel();
    _joinTimeoutTimer = null;
    if (_joinDecisionCompleter != null && !_joinDecisionCompleter!.isCompleted) {
      _joinDecisionCompleter!.complete(false);
    }
    _joinDecisionCompleter = null;
    _pendingJoinGuestName = null;
    await _server?.close(force: true);
    _server = null;
    _activePort = 8080;
    _loggedFirstInbound = false;
  }

  /// BLE host path: register (or reuse) a pending approval before showing UI.
  GuestApprovalBeginResult beginBleGuestApproval({
    required String bleDeviceId,
    required String displayName,
    String? connectionAttemptId,
  }) {
    if (_guestApprovals.roomSessionId == null) {
      // Hub may not be bound yet — start a transient session so BLE can dedupe.
      _guestApprovals.startRoomSession(
        'room-ble-${DateTime.now().millisecondsSinceEpoch}',
      );
    }
    final peerId = bleDeviceId.trim().isEmpty
        ? 'ble-unknown'
        : (bleDeviceId.startsWith('ble:') ? bleDeviceId : 'ble:$bleDeviceId');

    // Temporary BLE drop while HTTP session is still active → no new approval.
    final active = _guestApprovals.findActiveSessionForBleDevice(peerId);
    if (active != null) {
      unawaited(
        ConnectionLogger.instance.log(
          'Approval | BLE blip ignored (HTTP session still active)',
          details:
              'key=${active.key.value} guestPeerId=$peerId '
              'connectionAttemptId=${active.key.connectionAttemptId}',
        ),
      );
      return GuestApprovalBeginResult(
        kind: GuestApprovalOutcomeKind.alreadyApproved,
        entry: active,
        emitUiEvent: false,
      );
    }

    final attemptId = (connectionAttemptId != null &&
            connectionAttemptId.trim().isNotEmpty)
        ? connectionAttemptId.trim()
        : 'ble-${DateTime.now().millisecondsSinceEpoch}';
    if (connectionAttemptId == null || connectionAttemptId.trim().isEmpty) {
      unawaited(
        ConnectionLogger.instance.log(
          'Approval | New connectionAttemptId created',
          details:
              'reason=ble_missing_attempt_id connectionAttemptId=$attemptId '
              'guestPeerId=$peerId',
        ),
      );
    }
    final begin = _guestApprovals.begin(
      guestPeerId: peerId,
      connectionAttemptId: attemptId,
      displayName: displayName,
      source: GuestApprovalSource.ble,
    );
    return _withHostUiClaim(begin);
  }

  /// Resolve a BLE (or bridged) approval after the host taps Approve/Decline.
  GuestAccessGrant? resolveGuestApproval({
    required GuestApprovalEntry entry,
    required bool approved,
    required String reason,
  }) {
    final grant = _guestApprovals.resolve(
      entry: entry,
      approved: approved,
      reason: reason,
    );
    _releaseHostApprovalUi(entry.key.value);
    if (approved) {
      grantGuestHttpAccess(reason: reason);
    } else {
      revokeGuestHttpAccess(reason: reason);
    }
    return grant;
  }

  /// Claim the single host approval UI slot for [key]. Returns false if another
  /// dialog is already showing for a different key.
  bool claimHostApprovalUi(String key) {
    if (_hostApprovalUiKey != null && _hostApprovalUiKey != key) {
      unawaited(
        ConnectionLogger.instance.log(
          'Approval | Ignored duplicate approval event',
          details:
              'reason=host_ui_busy activeKey=$_hostApprovalUiKey newKey=$key',
        ),
      );
      return false;
    }
    if (_hostApprovalUiKey == key) {
      return false;
    }
    _hostApprovalUiKey = key;
    return true;
  }

  void _releaseHostApprovalUi(String key) {
    if (_hostApprovalUiKey == key) {
      _hostApprovalUiKey = null;
    }
  }

  GuestApprovalBeginResult _withHostUiClaim(GuestApprovalBeginResult begin) {
    if (!begin.emitUiEvent) return begin;
    if (claimHostApprovalUi(begin.entry.key.value)) return begin;
    return GuestApprovalBeginResult(
      kind: GuestApprovalOutcomeKind.ignoredDuplicate,
      entry: begin.entry,
      emitUiEvent: false,
    );
  }

  Future<String> _resolveSharedDirectoryPath() async {
    if (Platform.isAndroid) {
      final appDir = await getExternalStorageDirectory();
      final base = appDir ?? await getApplicationDocumentsDirectory();
      return p.join(base.path, 'AirShare');
    }

    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'AirShare');
    }

    // Windows/Linux/macOS: use a hidden temp directory so the host staging area
    // never collides with Downloads/AirShare, which is the guest's persistent
    // download destination. The teardown sequence clears this directory on exit.
    final temp = await getTemporaryDirectory();
    return p.join(temp.path, 'AirShare_Session');
  }

  /// Single path segment only; normalizes mixed slashes before validation.
  String? _sanitizeClientFileName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final norm = trimmed.replaceAll(r'\', '/');
    final parts = norm.split('/')..removeWhere((p) => p.isEmpty);
    if (parts.length != 1) return null;
    final seg = parts.single;
    if (seg == '.' || seg == '..') return null;
    return seg;
  }

  String _joinSharedPath(String dir, String fileName) {
    return p.join(dir, fileName);
  }

  Future<HttpServer> _bindWithPortFallback({
    required InternetAddress address,
    required int startingPort,
    required int maxAttempts,
  }) async {
    var attempt = 0;
    var port = startingPort;
    Object? lastError;

    while (attempt < maxAttempts) {
      try {
        return await HttpServer.bind(address, port, shared: true);
      } catch (error) {
        lastError = error;
        stdout.writeln(
          '[HubRuntime] Port $port unavailable, trying ${port + 1}...',
        );
        attempt++;
        port++;
      }
    }
    throw SocketException('Unable to bind server port: $lastError');
  }

  Future<void> _logHubIpv4Interfaces({
    required String bindAddress,
    required int port,
  }) async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      await ConnectionLogger.instance.log(
        'HTTP Server | Bind Address',
        details: 'bind=$bindAddress:$port',
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          await ConnectionLogger.instance.log(
            'HTTP Server | Android IPv4 Interface',
            details: '${iface.name}: ${addr.address}',
          );
        }
      }
    } catch (e) {
      await ConnectionLogger.instance.log(
        'HTTP Server | Interface dump failed',
        details: '$e',
      );
    }
  }

  Future<void> _routeRequest(HttpRequest request, String sharedDirPath) async {
    if (!_loggedFirstInbound) {
      _loggedFirstInbound = true;
      final remote = request.connectionInfo?.remoteAddress;
      await ConnectionLogger.instance.log(
        'HTTP | First inbound (hub reachable for guest TCP)',
        details:
            'method=${request.method} path=${request.uri.path} remote=$remote',
      );
      stdout.writeln(
        '[HubRuntime] First inbound request method=${request.method} path=${request.uri.path} remote=$remote',
      );
      _firstGuestController.add(null);
    }
    final method = request.method;
    final path = request.uri.path;

    if (path == '/health' && method == 'GET') {
      await _handleHealth(request);
      return;
    }

    if (path == '/files' && method == 'GET') {
      await _handleFiles(request, sharedDirPath);
      return;
    }

    if (path == '/download' && method == 'GET') {
      await _handleDownload(request, sharedDirPath);
      return;
    }

    if (path == '/upload' && method == 'POST') {
      await _handleUpload(request, sharedDirPath);
      return;
    }

    if (path == '/files' && method == 'DELETE') {
      await _handleDelete(request, sharedDirPath);
      return;
    }

    if (path == '/transfer-request' && method == 'POST') {
      await _handleTransferRequest(request);
      return;
    }

    if (path == '/pending-transfer' && method == 'GET') {
      await _handlePendingTransfer(request);
      return;
    }

    if (path == '/transfer-response' && method == 'POST') {
      await _handleTransferResponse(request);
      return;
    }

    if (path == '/join' && method == 'POST') {
      await _handleGuestJoin(request);
      return;
    }

    if (path == '/leave' && method == 'POST') {
      await _handleGuestLeave(request);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    request.response.write('Not found');
    await request.response.close();
  }

  Future<void> _handleHealth(HttpRequest request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'status': 'ok',
        'port': _activePort,
        'bind': _server?.address.address ?? 'unknown',
      }),
    );
    await request.response.close();
  }

  String? _headerValue(HttpRequest request, String name) {
    final values = request.headers[name];
    if (values == null || values.isEmpty) return null;
    final trimmed = values.first.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool _isHostHttpRequester(HttpRequest request) {
    final role =
        (_headerValue(request, 'x-airshare-requester-role') ?? 'guest')
            .toLowerCase();
    return role == 'host';
  }

  bool _isGuestHttpRequestAllowed(HttpRequest request) {
    if (_isHostHttpRequester(request)) return true;
    final token = _headerValue(request, 'x-airshare-access-token');
    final peerId = _headerValue(request, 'x-airshare-requester-peer-id');
    final attemptId =
        _headerValue(request, 'x-airshare-connection-attempt-id');
    if (_guestApprovals.isAccessAllowed(
      accessToken: token,
      guestPeerId: peerId,
      connectionAttemptId: attemptId,
    )) {
      return true;
    }
    // Soft allow: BLE already approved an active session before /join returns
    // an access token to the guest.
    return _guestApprovals.activeSessionCount > 0;
  }

  Future<void> _rejectGuestHttpNotApproved(
    HttpRequest request, {
    required String path,
  }) async {
    final remote = request.connectionInfo?.remoteAddress;
    await ConnectionLogger.instance.log(
      'HTTP | Guest request rejected (not approved)',
      details: 'path=$path remote=$remote',
    );
    stdout.writeln(
      '[HubRuntime] $path rejected — guest HTTP not approved remote=$remote',
    );
    request.response.statusCode = HttpStatus.forbidden;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'error': 'not_approved', 'message': 'Host has not approved this guest'}),
    );
    await request.response.close();
  }

  Future<void> _handleFiles(HttpRequest request, String sharedDirPath) async {
    if (!_isGuestHttpRequestAllowed(request)) {
      await _rejectGuestHttpNotApproved(request, path: 'GET /files');
      return;
    }
    final dir = Directory(sharedDirPath);
    stdout.writeln('[HubRuntime] GET /files list sharedDirPath=$sharedDirPath');
    await ConnectionLogger.instance.log(
      'HTTP | GET /files accepted',
      details: 'remote=${request.connectionInfo?.remoteAddress}',
    );
    final manifest = await SharedRoomManifest.load(sharedDirPath);
    final entities = await dir.list().toList();
    final entries = <SharedFileEntry>[];

    for (final entity in entities) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (SharedRoomManifest.isManifestFileName(name)) continue;

      final stat = await entity.stat();
      var meta = manifest.entryFor(name);
      if (meta == null) {
        meta = SharedFileEntry(
          name: name,
          senderId: manifest.roomHostPeerId,
          senderName: manifest.roomHostName.isNotEmpty
              ? manifest.roomHostName
              : 'Room host',
          sharedAt: stat.modified,
          sizeBytes: stat.size,
        );
        manifest.upsertFile(meta);
      } else if (meta.sizeBytes <= 0) {
        meta = SharedFileEntry(
          name: meta.name,
          senderId: meta.senderId,
          senderName: meta.senderName,
          sharedAt: meta.sharedAt,
          sizeBytes: stat.size,
        );
        manifest.upsertFile(meta);
      }
      entries.add(meta);
    }

    entries.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
    await manifest.save(sharedDirPath);

    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode(entries.map((e) => e.toJson()).toList()));
    await request.response.close();
  }

  Future<void> _handleDelete(HttpRequest request, String sharedDirPath) async {
    if (!_isGuestHttpRequestAllowed(request)) {
      await _rejectGuestHttpNotApproved(request, path: 'DELETE /files');
      return;
    }
    final rawName = request.uri.queryParameters['name'] ?? '';
    final fileName = _sanitizeClientFileName(rawName);
    if (fileName == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid file name');
      await request.response.close();
      return;
    }

    final requesterPeerId =
        _headerValue(request, 'x-airshare-requester-peer-id') ?? '';
    final requesterRole =
        (_headerValue(request, 'x-airshare-requester-role') ?? 'guest')
            .toLowerCase();
    final isHostRequester = requesterRole == 'host';

    final manifest = await SharedRoomManifest.load(sharedDirPath);
    final meta = manifest.entryFor(fileName);
    final senderId = meta?.senderId ?? '';

    final allowed =
        isHostRequester ||
        (requesterPeerId.isNotEmpty &&
            senderId.isNotEmpty &&
            requesterPeerId == senderId);
    if (!allowed) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('You can only delete files you shared');
      await request.response.close();
      return;
    }

    final file = File(_joinSharedPath(sharedDirPath, fileName));
    if (await file.exists()) {
      await file.delete();
    }
    manifest.removeFile(fileName);
    await manifest.save(sharedDirPath);

    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode({'status': 'ok', 'fileName': fileName}));
    await request.response.close();
    _ingressEventsController.add(
      jsonEncode({'type': 'deleted', 'fileName': fileName}),
    );
  }

  Future<void> _handleDownload(
    HttpRequest request,
    String sharedDirPath,
  ) async {
    if (!_isGuestHttpRequestAllowed(request)) {
      await _rejectGuestHttpNotApproved(request, path: 'GET /download');
      return;
    }
    final rawName = request.uri.queryParameters['name'] ?? '';
    stdout.writeln(
      '[HubRuntime] GET /download remote=${request.connectionInfo?.remoteAddress} '
      'raw_name=$rawName sharedDirPath=$sharedDirPath',
    );

    final fileName = _sanitizeClientFileName(rawName);
    if (fileName == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid file name');
      await request.response.close();
      return;
    }

    final file = File(_joinSharedPath(sharedDirPath, fileName));
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('File not found');
      await request.response.close();
      return;
    }

    final absolutePath = file.absolute.path;
    var responseCommitted = false;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Not a file');
        await request.response.close();
        return;
      }

      final size = stat.size;
      await ConnectionLogger.instance.log(
        'HTTP Download start',
        details: 'name=$fileName bytes=$size path=$absolutePath',
      );
      debugPrint(
        '[HubRuntime] GET /download name=$fileName size=$size path=$absolutePath',
      );

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.binary;
      final safeName = fileName.replaceAll('"', '');
      request.response.headers.set(
        'content-disposition',
        'attachment; filename="$safeName"',
      );
      request.response.contentLength = size;
      responseCommitted = true;

      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (error, stackTrace) {
      stdout.writeln(
        '[HubRuntime] Download failed name=$fileName path=$absolutePath committed=$responseCommitted: $error',
      );
      stdout.writeln('$stackTrace');
      await ConnectionLogger.instance.log(
        'HTTP Download error',
        details:
            'name=$fileName path=$absolutePath committed=$responseCommitted err=$error',
      );
      if (!responseCommitted) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentType = ContentType.text;
          request.response.write('Unable to read or stream file');
          await request.response.close();
        } catch (closeError) {
          stdout.writeln(
            '[HubRuntime] Download error response failed: $closeError',
          );
        }
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handleUpload(HttpRequest request, String sharedDirPath) async {
    if (!_isGuestHttpRequestAllowed(request)) {
      await _rejectGuestHttpNotApproved(request, path: 'POST /upload');
      return;
    }
    final contentType = request.headers.contentType;
    if (contentType == null || contentType.mimeType != 'multipart/form-data') {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Expected multipart form-data');
      await request.response.close();
      return;
    }

    final boundary = contentType.parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Missing multipart boundary');
      await request.response.close();
      return;
    }

    final contentLength = request.headers.contentLength;
    await ConnectionLogger.instance.log(
      'HTTP Upload start',
      details:
          'content_length=$contentLength boundary_len=${boundary.length} '
          'shared_dir=$sharedDirPath',
    );
    stdout.writeln(
      '[HubRuntime] POST /upload start contentLength=$contentLength '
      'sharedDirPath=$sharedDirPath',
    );

    try {
      final transformer = MimeMultipartTransformer(boundary);
      String? fileName;
      var sizeBytes = 0;
      File? outFile;

      await for (final part
          in request.cast<List<int>>().transform(transformer)) {
        final disposition = part.headers['content-disposition'] ?? '';
        final match = RegExp(r'filename="([^"]*)"').firstMatch(disposition);
        final partName = match?.group(1);
        if (partName == null || partName.isEmpty) {
          await part.forEach((_) {});
          continue;
        }

        fileName = partName.split('/').last.split(r'\').last;
        final uploadSafe = _sanitizeClientFileName(fileName);
        if (uploadSafe == null) {
          await part.forEach((_) {});
          continue;
        }
        fileName = uploadSafe;

        final outPath = _joinSharedPath(sharedDirPath, fileName);
        outFile = File(outPath);
        final sink = outFile.openWrite();
        try {
          await for (final chunk in part) {
            sink.add(chunk);
            sizeBytes += chunk.length;
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        stdout.writeln(
          '[HubRuntime] POST /upload streamed name=$fileName outPath=$outPath '
          'bytes=$sizeBytes',
        );
        break;
      }

      if (fileName == null || outFile == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Missing file payload');
        await request.response.close();
        return;
      }

      final senderId = _headerValue(request, 'x-airshare-sender-id') ?? '';
      final senderName =
          _headerValue(request, 'x-airshare-sender-name') ?? 'Unknown';
      final manifest = await SharedRoomManifest.load(sharedDirPath);
      if (manifest.roomHostPeerId.isEmpty &&
          _headerValue(request, 'x-airshare-requester-role') == 'host' &&
          senderId.isNotEmpty) {
        manifest.setRoomHost(peerId: senderId, displayName: senderName);
      }
      manifest.upsertFile(
        SharedFileEntry(
          name: fileName,
          senderId: senderId,
          senderName: senderName,
          sharedAt: DateTime.now().toUtc(),
          sizeBytes: sizeBytes,
        ),
      );
      await manifest.save(sharedDirPath);

      await ConnectionLogger.instance.log(
        'HTTP Upload success',
        details: 'name=$fileName bytes=$sizeBytes sender=$senderName',
      );

      request.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      request.response.statusCode = HttpStatus.created;
      request.response.write(
        jsonEncode({
          'status': 'ok',
          'message': 'file uploaded',
          'fileName': fileName,
        }),
      );
      await request.response.close();
      _ingressEventsController.add(
        jsonEncode({
          'type': 'uploaded',
          'senderName': senderName,
          'fileName': fileName,
        }),
      );
    } catch (error, stackTrace) {
      stdout.writeln('[HubRuntime] POST /upload failed: $error\n$stackTrace');
      await ConnectionLogger.instance.log(
        'HTTP Upload error',
        details: '$error',
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('Upload failed');
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<Uint8List> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Sender calls this before uploading. Blocks up to 30 s waiting for the
  /// receiver to approve or reject. Returns {"approved": true/false}.
  Future<void> _handleTransferRequest(HttpRequest request) async {
    if (_decisionCompleter != null) {
      request.response.statusCode = HttpStatus.conflict;
      request.response.write('Another transfer request is already pending');
      await request.response.close();
      return;
    }

    final bodyBytes = await _readBody(request);
    Map<String, dynamic> body;
    try {
      body = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Expected JSON body');
      await request.response.close();
      return;
    }

    _pendingTransfer = TransferApprovalRequest(
      senderName: (body['senderName'] as String?) ?? 'Unknown sender',
      fileCount: (body['fileCount'] as int?) ?? 1,
      totalBytes: (body['totalBytes'] as int?) ?? 0,
    );
    _decisionCompleter = Completer<bool>();

    // Auto-reject after 30 s if receiver does not respond.
    _approvalTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
        _decisionCompleter!.complete(false);
      }
    });

    final approved = await _decisionCompleter!.future;

    _approvalTimeoutTimer?.cancel();
    _approvalTimeoutTimer = null;
    _pendingTransfer = null;
    _decisionCompleter = null;

    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode({'approved': approved}));
    await request.response.close();
  }

  /// Receiver polls this to discover a pending transfer request.
  Future<void> _handlePendingTransfer(HttpRequest request) async {
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    if (_pendingTransfer != null) {
      request.response.write(jsonEncode(_pendingTransfer!.toJson()));
    } else {
      request.response.write('null');
    }
    await request.response.close();
  }

  /// Receiver posts {"approved": true/false} to resolve the pending request.
  Future<void> _handleTransferResponse(HttpRequest request) async {
    final bodyBytes = await _readBody(request);
    Map<String, dynamic> body;
    try {
      body = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Expected JSON body');
      await request.response.close();
      return;
    }

    final approved = (body['approved'] as bool?) ?? false;
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(approved);
    }

    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode({'status': 'ok'}));
    await request.response.close();
  }

  Future<void> _handleGuestJoin(HttpRequest request) async {
    final bodyBytes = await _readBody(request);
    String guestName = 'Someone';
    String guestPeerId = '';
    String connectionAttemptId = '';
    try {
      final body = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
      final raw = (body['guestName'] as String?)?.trim() ?? '';
      if (raw.isNotEmpty) guestName = raw;
      guestPeerId = (body['guestPeerId'] as String?)?.trim() ??
          (body['peerId'] as String?)?.trim() ??
          '';
      connectionAttemptId =
          (body['connectionAttemptId'] as String?)?.trim() ?? '';
    } catch (_) {}

    if (guestPeerId.isEmpty) {
      guestPeerId = 'name:${guestName.toLowerCase()}';
    }
    if (connectionAttemptId.isEmpty) {
      connectionAttemptId =
          'join-${DateTime.now().millisecondsSinceEpoch}';
      await ConnectionLogger.instance.log(
        'Approval | New connectionAttemptId created',
        details:
            'reason=http_join_missing_attempt_id '
            'connectionAttemptId=$connectionAttemptId guestPeerId=$guestPeerId',
      );
    }

    if (_guestApprovals.roomSessionId == null) {
      _guestApprovals.startRoomSession(
        'room-${DateTime.now().millisecondsSinceEpoch}-$_activePort',
      );
    }

    final begin = _withHostUiClaim(
      _guestApprovals.begin(
        guestPeerId: guestPeerId,
        connectionAttemptId: connectionAttemptId,
        displayName: guestName,
        source: GuestApprovalSource.registration,
      ),
    );

    _guestApprovals.bindHttpIdentity(
      entry: begin.entry,
      guestPeerId: guestPeerId,
      connectionAttemptId: connectionAttemptId,
    );

    // Already approved via BLE (same active attempt) — no second dialog.
    if (begin.kind == GuestApprovalOutcomeKind.alreadyApproved) {
      final grant = _guestApprovals.grantForEntry(begin.entry) ??
          _guestApprovals.resolve(
            entry: begin.entry,
            approved: true,
            reason: 'reused_approved_join',
          );
      grantGuestHttpAccess(
        reason:
            'reused_approved_join key=${begin.entry.key.value} name=$guestName',
      );
      _guestJoinedController.add(guestName);
      await ConnectionLogger.instance.log(
        'HTTP | Guest join reused approved approval',
        details: 'key=${begin.entry.key.value} name=$guestName',
      );
      await _writeJoinResponse(
        request,
        status: 'approved',
        guestName: guestName,
        grant: grant,
      );
      return;
    }

    if (begin.kind == GuestApprovalOutcomeKind.alreadyDenied) {
      await ConnectionLogger.instance.log(
        'HTTP | Guest join reused denied approval',
        details: 'key=${begin.entry.key.value} name=$guestName',
      );
      await _writeJoinResponse(
        request,
        status: 'declined',
        guestName: guestName,
        grant: null,
      );
      return;
    }

    // Pending from BLE (or duplicate HTTP): wait on the same decision — no UI.
    if (begin.kind == GuestApprovalOutcomeKind.reusedPending ||
        begin.kind == GuestApprovalOutcomeKind.ignoredDuplicate) {
      await ConnectionLogger.instance.log(
        'HTTP | Guest join awaiting existing pending approval',
        details:
            'key=${begin.entry.key.value} name=$guestName kind=${begin.kind.name}',
      );
      final approved = await _awaitApprovalWithTimeout(begin.entry);
      await _respondToJoinDecision(
        request,
        guestName: guestName,
        guestPeerId: guestPeerId,
        connectionAttemptId: connectionAttemptId,
        approved: approved,
        entry: begin.entry,
      );
      return;
    }

    // Brand-new HTTP join (e.g. BLE payload already released on reconnect).
    // If another join dialog is already open, auto-approve concurrent guests.
    if (_joinDecisionCompleter != null) {
      final grant = _guestApprovals.resolve(
        entry: begin.entry,
        approved: true,
        reason: 'auto_approve_concurrent_$guestName',
      );
      grantGuestHttpAccess(reason: 'auto_approve_concurrent_$guestName');
      _guestJoinedController.add(guestName);
      await ConnectionLogger.instance.log(
        'HTTP | Guest join auto-approved (another approval in progress)',
        details: 'name=$guestName key=${begin.entry.key.value}',
      );
      await _writeJoinResponse(
        request,
        status: 'approved',
        guestName: guestName,
        grant: grant,
      );
      return;
    }

    _pendingJoinGuestName = guestName;
    _joinDecisionCompleter = Completer<bool>();
    if (begin.emitUiEvent) {
      _joinRequestController.add(guestName);
      await ConnectionLogger.instance.log(
        'Approval | New approval requested',
        details:
            'key=${begin.entry.key.value} source=registration name=$guestName',
      );
    }
    await ConnectionLogger.instance.log(
      'HTTP | Guest join awaiting host approval',
      details:
          'name=$guestName key=${begin.entry.key.value} '
          'remote=${request.connectionInfo?.remoteAddress} emitUi=${begin.emitUiEvent}',
    );

    _joinTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_joinDecisionCompleter != null &&
          !_joinDecisionCompleter!.isCompleted) {
        _joinDecisionCompleter!.complete(true);
      }
      if (begin.entry.isPending) {
        _guestApprovals.resolve(
          entry: begin.entry,
          approved: true,
          reason: 'join_timeout_auto_approve',
        );
      }
      _releaseHostApprovalUi(begin.entry.key.value);
    });

    // Prefer registry decision (BLE may resolve first); also watch UI completer.
    final approved = await Future.any<bool>([
      begin.entry.decision.future,
      _joinDecisionCompleter!.future,
    ]);

    if (begin.entry.isPending) {
      _guestApprovals.resolve(
        entry: begin.entry,
        approved: approved,
        reason: approved ? 'host_approved_join' : 'host_declined_join',
      );
    }
    if (_joinDecisionCompleter != null &&
        !_joinDecisionCompleter!.isCompleted) {
      _joinDecisionCompleter!.complete(approved);
    }

    _joinTimeoutTimer?.cancel();
    _joinTimeoutTimer = null;
    _pendingJoinGuestName = null;
    _joinDecisionCompleter = null;

    await _respondToJoinDecision(
      request,
      guestName: guestName,
      guestPeerId: guestPeerId,
      connectionAttemptId: connectionAttemptId,
      approved: approved,
      entry: begin.entry,
    );
  }

  Future<void> _handleGuestLeave(HttpRequest request) async {
    final bodyBytes = await _readBody(request);
    String guestPeerId = '';
    String connectionAttemptId = '';
    String accessToken = '';
    try {
      final body = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
      guestPeerId = (body['guestPeerId'] as String?)?.trim() ??
          (body['peerId'] as String?)?.trim() ??
          '';
      connectionAttemptId =
          (body['connectionAttemptId'] as String?)?.trim() ?? '';
      accessToken = (body['accessToken'] as String?)?.trim() ?? '';
    } catch (_) {}

    final headerPeer =
        _headerValue(request, 'x-airshare-requester-peer-id') ?? '';
    final headerAttempt =
        _headerValue(request, 'x-airshare-connection-attempt-id') ?? '';
    final headerToken =
        _headerValue(request, 'x-airshare-access-token') ?? '';
    if (guestPeerId.isEmpty) guestPeerId = headerPeer;
    if (connectionAttemptId.isEmpty) connectionAttemptId = headerAttempt;
    if (accessToken.isEmpty) accessToken = headerToken;

    final ok = invalidateGuestConnection(
      guestPeerId: guestPeerId.isEmpty ? null : guestPeerId,
      connectionAttemptId:
          connectionAttemptId.isEmpty ? null : connectionAttemptId,
      accessToken: accessToken.isEmpty ? null : accessToken,
      reason: 'guest_leave',
    );

    // Authorization for the next entry is forced by session lifecycle:
    // invalidateGuestConnection + a new connectionAttemptId on reconnect.
    // No BleTransport API is required — transport stays BLE-only.
    await ConnectionLogger.instance.log(
      'HTTP | Guest leave complete',
      details:
          'invalidated=$ok activeSessions=${_guestApprovals.activeSessionCount}',
    );

    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(
      jsonEncode({'status': ok ? 'left' : 'unknown', 'invalidated': ok}),
    );
    await request.response.close();
  }

  Future<bool> _awaitApprovalWithTimeout(GuestApprovalEntry entry) async {
    _joinTimeoutTimer?.cancel();
    final timeout = Completer<bool>();
    final timer = Timer(const Duration(seconds: 30), () {
      if (!timeout.isCompleted) timeout.complete(true);
      if (entry.isPending) {
        _guestApprovals.resolve(
          entry: entry,
          approved: true,
          reason: 'bridged_join_timeout_auto_approve',
        );
      }
    });
    try {
      return await Future.any<bool>([entry.decision.future, timeout.future]);
    } finally {
      timer.cancel();
    }
  }

  Future<void> _respondToJoinDecision(
    HttpRequest request, {
    required String guestName,
    required String guestPeerId,
    required String connectionAttemptId,
    required bool approved,
    required GuestApprovalEntry entry,
  }) async {
    await ConnectionLogger.instance.log(
      'HTTP | Guest join decision',
      details:
          'name=$guestName approved=$approved key=${entry.key.value} '
          'guestPeerId=$guestPeerId connectionAttemptId=$connectionAttemptId',
    );

    GuestAccessGrant? grant;
    if (approved) {
      grant = _guestApprovals.grantForEntry(entry);
      if (grant == null && entry.isApproved) {
        // Decision completed elsewhere without token (shouldn't happen).
        grant = _guestApprovals.resolve(
          entry: entry,
          approved: true,
          reason: 'host_approved_join_$guestName',
        );
      } else if (grant == null && entry.isPending) {
        grant = _guestApprovals.resolve(
          entry: entry,
          approved: true,
          reason: 'host_approved_join_$guestName',
        );
      }
      grantGuestHttpAccess(reason: 'host_approved_join_$guestName');
      _guestJoinedController.add(guestName);
    } else {
      if (entry.isPending) {
        _guestApprovals.resolve(
          entry: entry,
          approved: false,
          reason: 'host_declined_join_$guestName',
        );
      }
      revokeGuestHttpAccess(reason: 'host_declined_join_$guestName');
    }
    _releaseHostApprovalUi(entry.key.value);

    await _writeJoinResponse(
      request,
      status: approved ? 'approved' : 'declined',
      guestName: guestName,
      grant: grant,
    );
  }

  Future<void> _writeJoinResponse(
    HttpRequest request, {
    required String status,
    required String guestName,
    required GuestAccessGrant? grant,
  }) async {
    try {
      request.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      request.response.write(
        jsonEncode({
          'status': status,
          'guestName': guestName,
          if (grant != null) 'accessToken': grant.accessToken,
          if (grant != null) 'roomSessionId': grant.roomSessionId,
          if (grant != null) 'connectionAttemptId': grant.connectionAttemptId,
        }),
      );
      await request.response.close();
    } catch (e) {
      await ConnectionLogger.instance.log(
        'HTTP | Guest join response failed (server closing)',
        details: '$e',
      );
    }
  }

  int _indexOfSublist(List<int> source, List<int> target, int start) {
    if (target.isEmpty || source.isEmpty || start < 0) return -1;
    for (var i = start; i <= source.length - target.length; i++) {
      var match = true;
      for (var j = 0; j < target.length; j++) {
        if (source[i + j] != target[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
