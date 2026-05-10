import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'connection_logger.dart';
import 'hub_status.dart';

class LocalHubRuntime {
  LocalHubRuntime._();

  static final LocalHubRuntime instance = LocalHubRuntime._();

  HttpServer? _server;
  int _activePort = 8080;
  String? _sharedDirPath;
  final StreamController<String> _ingressEventsController =
      StreamController<String>.broadcast();

  bool get isRunning => _server != null;
  int get activePort => _activePort;
  Stream<String> get ingressEvents => _ingressEventsController.stream;

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
        address: InternetAddress.anyIPv4,
        startingPort: 8080,
        maxAttempts: 10,
      );
      _activePort = _server!.port;
      await ConnectionLogger.instance.log(
        'HTTP Server Start',
        details: 'bound_port=$_activePort',
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
  }

  Future<String> _resolveSharedDirectoryPath() async {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/AirShare';
    }

    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return '${docs.path}${Platform.pathSeparator}AirShare';
    }

    final fallback = await getApplicationDocumentsDirectory();
    return '${fallback.path}${Platform.pathSeparator}AirShare';
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
    final fileName = request.uri.queryParameters['name'] ?? '';
    if (fileName.isEmpty || fileName != fileName.split(Platform.pathSeparator).last) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Invalid file name');
      await request.response.close();
      return;
    }

    final file = File('$sharedDirPath${Platform.pathSeparator}$fileName');
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('File not found');
      await request.response.close();
      return;
    }

    request.response.headers.set(
      'content-disposition',
      'attachment; filename="$fileName"',
    );
    await file.openRead().pipe(request.response);
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
    final outFile = File('$sharedDirPath${Platform.pathSeparator}$fileName');
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
