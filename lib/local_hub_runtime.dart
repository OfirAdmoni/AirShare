import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'connection_logger.dart';
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

  /// Guest HTTP (/files, /download, /upload, /delete) allowed only after BLE approve.
  bool _guestHttpAccessGranted = false;

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

  void resetGuestHttpSession({required String reason}) {
    _guestHttpAccessGranted = false;
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest session reset',
        details: reason,
      ),
    );
  }

  void grantGuestHttpAccess({required String reason}) {
    _guestHttpAccessGranted = true;
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest access token issued',
        details: reason,
      ),
    );
  }

  void revokeGuestHttpAccess({required String reason}) {
    _guestHttpAccessGranted = false;
    unawaited(
      ConnectionLogger.instance.log(
        'HTTP | Guest access revoked',
        details: reason,
      ),
    );
  }

  Future<void> ensureStarted(HubStatus status) async {
    resetGuestHttpSession(reason: 'sender_hub_ensureStarted');
    if (isRunning) {
      status.setBroadcasting();
      return;
    }

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
    _approvalTimeoutTimer?.cancel();
    _approvalTimeoutTimer = null;
    if (_decisionCompleter != null && !_decisionCompleter!.isCompleted) {
      _decisionCompleter!.complete(false);
    }
    _decisionCompleter = null;
    _pendingTransfer = null;
    await _server?.close(force: true);
    _server = null;
    _activePort = 8080;
    _loggedFirstInbound = false;
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

    // Windows/Linux/macOS: prefer Downloads/AirShare for desktop workflows.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return p.join(downloads.path, 'AirShare');
      }
    }

    final fallback = await getApplicationDocumentsDirectory();
    return p.join(fallback.path, 'AirShare');
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
    return _guestHttpAccessGranted;
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
    try {
      final body = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
      final raw = (body['guestName'] as String?)?.trim() ?? '';
      if (raw.isNotEmpty) guestName = raw;
    } catch (_) {}
    await ConnectionLogger.instance.log(
      'HTTP | Guest registered',
      details:
          'name=$guestName remote=${request.connectionInfo?.remoteAddress} '
          'http_approved=$_guestHttpAccessGranted',
    );
    _guestJoinedController.add(guestName);
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode({'status': 'ok'}));
    await request.response.close();
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
