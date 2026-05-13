import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import 'connection_logger.dart';
import 'hub_status.dart';

/// IPv4 all-interfaces listen address. **Not** loopback — required so other phones
/// on the same LAN can open TCP to the hub (Android hub uses Dart [HttpServer]).
final InternetAddress _hubListenAllIPv4 = InternetAddress('0.0.0.0');

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

  bool get isRunning => _server != null;
  int get activePort => _activePort;
  Stream<String> get ingressEvents => _ingressEventsController.stream;
  Stream<void> get firstGuestConnected => _firstGuestController.stream;

  Future<void> ensureStarted(HubStatus status) async {
    if (isRunning) {
      status.setBroadcasting();
      return;
    }

    status.setStarting();

    try {
      _sharedDirPath ??= await _resolveSharedDirectoryPath();
      final sharedDir = Directory(_sharedDirPath!);
      if (!await sharedDir.exists()) {
        await sharedDir.create(recursive: true);
      }

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
      stdout.writeln('[HubRuntime] shared directory (serve from): ${sharedDir.path}');
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
      stdout.writeln('[HubRuntime] Sender HTTP server started on port $_activePort');
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
    await _server?.close(force: true);
    _server = null;
    _activePort = 8080;
    _loggedFirstInbound = false;
  }

  Future<String> _resolveSharedDirectoryPath() async {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/AirShare';
    }

    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return '${docs.path}${Platform.pathSeparator}AirShare';
    }

    // Windows/Linux/macOS: prefer Downloads/AirShare so hub files align with the
    // common "Downloads" workflow and match Android's Download/AirShare layout.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return '${downloads.path}${Platform.pathSeparator}AirShare';
      }
    }

    final fallback = await getApplicationDocumentsDirectory();
    return '${fallback.path}${Platform.pathSeparator}AirShare';
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
    final d = dir.endsWith(Platform.pathSeparator)
        ? dir.substring(0, dir.length - 1)
        : dir;
    return '$d${Platform.pathSeparator}$fileName';
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

  Future<void> _routeRequest(HttpRequest request, String sharedDirPath) async {
    if (!_loggedFirstInbound) {
      _loggedFirstInbound = true;
      final remote = request.connectionInfo?.remoteAddress;
      await ConnectionLogger.instance.log(
        'HTTP | First inbound (hub reachable for guest TCP)',
        details: 'method=${request.method} path=${request.uri.path} remote=$remote',
      );
      stdout.writeln(
        '[HubRuntime] First inbound request method=${request.method} path=${request.uri.path} remote=$remote',
      );
      _firstGuestController.add(null);
    }
    final method = request.method;
    final path = request.uri.path;

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

    request.response.statusCode = HttpStatus.notFound;
    request.response.write('Not found');
    await request.response.close();
  }

  Future<void> _handleFiles(HttpRequest request, String sharedDirPath) async {
    final dir = Directory(sharedDirPath);
    stdout.writeln('[HubRuntime] GET /files list sharedDirPath=$sharedDirPath');
    final entities = await dir.list().toList();
    final fileNames = entities
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList()
      ..sort();

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(fileNames));
    await request.response.close();
  }

  Future<void> _handleDownload(HttpRequest request, String sharedDirPath) async {
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
      debugPrint('[HubRuntime] GET /download name=$fileName size=$size path=$absolutePath');

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
        details: 'name=$fileName path=$absolutePath committed=$responseCommitted err=$error',
      );
      if (!responseCommitted) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentType = ContentType.text;
          request.response.write('Unable to read or stream file');
          await request.response.close();
        } catch (closeError) {
          stdout.writeln('[HubRuntime] Download error response failed: $closeError');
        }
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handleUpload(HttpRequest request, String sharedDirPath) async {
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

    final bodyBuilder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bodyBuilder.add(chunk);
    }
    final bodyBytes = bodyBuilder.takeBytes();

    final delimiter = ascii.encode('--$boundary');
    final headerSeparator = <int>[13, 10, 13, 10];
    final startBoundary = _indexOfSublist(bodyBytes, delimiter, 0);
    final headerEnd = _indexOfSublist(bodyBytes, headerSeparator, startBoundary);
    if (startBoundary < 0 || headerEnd < 0) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Missing file payload');
      await request.response.close();
      return;
    }

    final headersBytes = bodyBytes.sublist(startBoundary, headerEnd);
    final headersText = latin1.decode(headersBytes);
    String? fileName;
    final match = RegExp(r'filename="([^"]+)"').firstMatch(headersText);
    if (match != null) {
      fileName = match.group(1);
    }
    fileName ??= 'received_${DateTime.now().millisecondsSinceEpoch}.bin';
    fileName = fileName.split('/').last.split(r'\').last;
    final uploadSafe = _sanitizeClientFileName(fileName);
    if (uploadSafe == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid file name');
      await request.response.close();
      return;
    }
    fileName = uploadSafe;

    final contentStart = headerEnd + headerSeparator.length;
    final endDelimiter = ascii.encode('\r\n--$boundary');
    final contentEnd = _indexOfSublist(bodyBytes, endDelimiter, contentStart);
    if (contentEnd < 0 || contentEnd <= contentStart) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid multipart payload');
      await request.response.close();
      return;
    }

    final fileBytes = bodyBytes.sublist(contentStart, contentEnd);
    final outPath = _joinSharedPath(sharedDirPath, fileName);
    stdout.writeln('[HubRuntime] POST /upload name=$fileName outPath=$outPath bytes=${fileBytes.length}');
    final outFile = File(outPath);
    await outFile.writeAsBytes(fileBytes, flush: true);

    request.response.headers.contentType = ContentType.json;
    request.response.statusCode = HttpStatus.created;
    request.response.write(
      jsonEncode({
        'status': 'ok',
        'message': 'file uploaded',
        'fileName': fileName,
      }),
    );
    await request.response.close();
    _ingressEventsController.add(fileName);
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
