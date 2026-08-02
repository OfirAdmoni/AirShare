import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:air_share/connection_logger.dart';
import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/local_peer_identity.dart';
import 'package:air_share/session_teardown.dart';
import 'package:air_share/shared_file_entry.dart';
import 'package:air_share/wlan_link_manager.dart';

// ── File-type helpers ────────────────────────────────────────────────────────

IconData _fileTypeIcon(String name) {
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'};
  const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', 'flv', '3gp'};
  const audio = {'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'opus'};
  const docs = {'doc', 'docx', 'txt', 'rtf', 'odt', 'pages', 'md'};
  const sheets = {'xls', 'xlsx', 'csv', 'ods', 'numbers'};
  const slides = {'ppt', 'pptx', 'odp', 'key'};
  const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'};
  if (images.contains(ext)) return Icons.image_outlined;
  if (videos.contains(ext)) return Icons.videocam_outlined;
  if (audio.contains(ext)) return Icons.music_note_outlined;
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  if (docs.contains(ext)) return Icons.article_outlined;
  if (sheets.contains(ext)) return Icons.table_chart_outlined;
  if (slides.contains(ext)) return Icons.slideshow_outlined;
  if (archives.contains(ext)) return Icons.folder_zip_outlined;
  if (ext == 'apk') return Icons.android;
  return Icons.insert_drive_file_outlined;
}

Color _fileTypeColor(String name) {
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'};
  const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', 'flv', '3gp'};
  const audio = {'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'opus'};
  const sheets = {'xls', 'xlsx', 'csv', 'ods', 'numbers'};
  const slides = {'ppt', 'pptx', 'odp', 'key'};
  const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'};
  if (images.contains(ext)) return const Color(0xFFF59E0B);
  if (videos.contains(ext)) return const Color(0xFF8B5CF6);
  if (audio.contains(ext)) return const Color(0xFFEC4899);
  if (ext == 'pdf') return const Color(0xFFEF4444);
  if (sheets.contains(ext)) return const Color(0xFF10B981);
  if (slides.contains(ext)) return const Color(0xFFF97316);
  if (archives.contains(ext)) return const Color(0xFF6B7280);
  return const Color(0xFF3B82F6);
}

// ── Widget ───────────────────────────────────────────────────────────────────

class FileListScreen extends StatefulWidget {
  const FileListScreen({
    required this.hubHost,
    required this.hubPort,
    required this.modeTitle,
    this.isHubMode = false,
    this.connectionAttemptId,
    super.key,
  });

  final String hubHost;
  final int hubPort;
  final String modeTitle;
  final bool isHubMode;

  /// Guest-side nonce for this connection attempt (dedupes host approval).
  final String? connectionAttemptId;

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _StagedFile {
  const _StagedFile({
    required this.name,
    required this.sizeBytes,
    this.path,
    this.bytes,
  });

  final String name;
  final int sizeBytes;
  final String? path;
  final List<int>? bytes;
}

class _FileListScreenState extends State<FileListScreen> {
  List<SharedFileEntry> files = [];
  List<SharedFileEntry> _previousFiles = [];
  bool _initialFetchDone = false;

  String? _localPeerId;
  String _localDisplayName = 'You';
  late final String _connectionAttemptId = widget.connectionAttemptId?.trim().isNotEmpty == true
      ? widget.connectionAttemptId!.trim()
      : 'attempt-${DateTime.now().millisecondsSinceEpoch}';
  String? _accessToken;
  List<_StagedFile> _selectedFiles = [];

  // Download state
  bool isDownloading = false;
  double downloadProgress = 0;
  String? downloadingFileName;
  bool _downloadCompleted = false;
  int _batchDownloadTotal = 0;
  int _batchDownloadCompleted = 0;

  // Upload state
  bool isUploading = false;
  double uploadProgress = 0;
  String? uploadingFileName;

  // Selection state
  final Set<String> _selectedForDownload = {};
  bool _selectionMode = false;

  StreamSubscription<String>? _ingressSubscription;
  StreamSubscription<void>? _guestConnectedSub;
  StreamSubscription<String>? _guestJoinedSub;
  bool _guestConnected = false;
  bool _guestConnectionTimedOut = false;
  Timer? _guestConnectionTimer;
  Timer? _refreshTimer;

  bool _teardownConfirmed = false;
  http.Client? _activeDownloadClient;
  String? _activeDownloadPath;

  Timer? _approvalPollTimer;
  bool _approvalDialogShowing = false;

  bool _screenTeardownRan = false;
  int _consecutiveHostErrors = 0;
  bool _hostDisconnectShown = false;

  StreamSubscription<String>? _joinRequestSub;
  bool _joinDialogShowing = false;

  bool get _isTransferActive => isDownloading || isUploading;

  String get baseUrl => 'http://${widget.hubHost}:${widget.hubPort}';
  HubStatus get _hubStatus => HubStatusScope.of(context);

  Map<String, String> _roomRequestHeaders() => {
        // ignore: use_null_aware_elements
        if (_localPeerId != null)
          'x-airshare-requester-peer-id': _localPeerId!,
        'x-airshare-requester-role': widget.isHubMode ? 'host' : 'guest',
        'x-airshare-connection-attempt-id': _connectionAttemptId,
        // ignore: use_null_aware_elements
        if (_accessToken != null && _accessToken!.isNotEmpty)
          'x-airshare-access-token': _accessToken!,
      };

  Map<String, String> _uploadSenderHeaders() => {
        ..._roomRequestHeaders(),
        // ignore: use_null_aware_elements
        if (_localPeerId != null) 'x-airshare-sender-id': _localPeerId!,
        'x-airshare-sender-name': _localDisplayName,
      };

  // ── File list ─────────────────────────────────────────────────────────────

  Future<void> fetchFiles({bool silent = false}) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/files'),
        headers: _roomRequestHeaders(),
      );
      if (response.statusCode == 200) {
        _consecutiveHostErrors = 0;
        final decoded = json.decode(response.body);
        final parsed = <SharedFileEntry>[];
        if (decoded is List) {
          for (final item in decoded) {
            parsed.add(SharedFileEntry.fromJson(item));
          }
        }
        if (!mounted) return;
        if (!silent && _initialFetchDone && !widget.isHubMode) {
          _notifyFileListChanges(_previousFiles, parsed);
        }
        setState(() {
          _previousFiles = List.of(files);
          files = parsed;
          _initialFetchDone = true;
        });
      }
    } catch (e) {
      debugPrint('Data directory query failed: $e');
      if (!widget.isHubMode) {
        _consecutiveHostErrors++;
        if (_consecutiveHostErrors >= 3 && !_hostDisconnectShown) {
          _hostDisconnectShown = true;
          _handleHostDisconnected();
        }
      }
    }
  }

  void _notifyFileListChanges(
    List<SharedFileEntry> oldList,
    List<SharedFileEntry> newList,
  ) {
    final oldNames = {for (final f in oldList) f.name};
    final newNames = {for (final f in newList) f.name};

    for (final entry in newList) {
      if (!oldNames.contains(entry.name)) {
        final sender = (entry.senderName.isNotEmpty &&
                entry.senderName != 'Unknown')
            ? entry.senderName
            : 'Someone';
        _showEventSnackBar('$sender uploaded ${entry.name}');
      }
    }
    for (final name in oldNames) {
      if (!newNames.contains(name)) {
        _showEventSnackBar('"$name" was removed from the session');
      }
    }
  }

  void _handleHostDisconnected() {
    if (!mounted) return;
    _refreshTimer?.cancel();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Session Ended'),
        content: const Text(
          'Unfortunately, the host has left. The room is now closing.',
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              if (mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            child: const Text('Go Home'),
          ),
        ],
      ),
    );
  }

  void _showEventSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF0A2463),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showConnectionSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showErrorSnackBar(String message, {bool isWarning = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor:
            isWarning ? const Color(0xFFEA580C) : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  bool _canDelete(SharedFileEntry entry) {
    if (_localPeerId == null || _localPeerId!.isEmpty) return false;
    return entry.senderId.isNotEmpty && entry.senderId == _localPeerId;
  }

  Future<void> _confirmAndDelete(SharedFileEntry entry) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text(
          'Are you sure you want to delete "${entry.name}"?\n'
          'This will remove it for everyone in the session.',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0A2463).withValues(alpha: 0.55),
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _deleteFile(entry);
  }

  Future<void> _deleteFile(SharedFileEntry entry) async {
    if (!_canDelete(entry)) {
      _showErrorSnackBar('You can only delete files you shared', isWarning: true);
      return;
    }
    try {
      final uri = Uri.parse(
        '$baseUrl/files?name=${Uri.encodeComponent(entry.name)}',
      );
      final request = http.Request('DELETE', uri)
        ..headers.addAll(_roomRequestHeaders());
      final response = await request.send();
      if (response.statusCode != HttpStatus.ok) {
        final body = await response.stream.bytesToString();
        throw Exception(
          body.isNotEmpty ? body : 'Delete failed (${response.statusCode})',
        );
      }
      await fetchFiles(silent: true);
      if (!mounted) return;
      _showEventSnackBar('"${entry.name}" deleted');
    } catch (e) {
      if (!mounted) return;
      _showErrorSnackBar('Delete failed: $e');
    }
  }

  // ── Download directory resolution ─────────────────────────────────────────

  Future<void> _requestAndroidStoragePermission() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      // WRITE_EXTERNAL_STORAGE is only meaningful on API ≤ 32 (Android 12)
      if (info.version.sdkInt <= 32) {
        final status = await Permission.storage.status;
        if (status.isDenied) await Permission.storage.request();
      }
    } catch (_) {
      // Graceful fallback — proceed and let file write fail if needed
    }
  }

  // Returns (directory to save into, user-friendly path label for snackbar).
  Future<(Directory, String)> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      await _requestAndroidStoragePermission();
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          // path_provider returns .../Android/data/<pkg>/files — walk up 4 levels
          // to reach the device's primary external storage root (/storage/emulated/0)
          Directory root = ext;
          for (int i = 0; i < 4; i++) {
            root = root.parent;
          }
          final dir = Directory(p.join(root.path, 'Download', 'AirShare'));
          await dir.create(recursive: true);
          // Smoke-test write access before committing to this path
          final probe = File(p.join(dir.path, '.airshare_probe'));
          await probe.writeAsString('ok');
          await probe.delete();
          return (dir, 'Downloads/AirShare');
        }
      } catch (_) {
        // Android 11+ scoped storage may block direct access; fall through
      }
      // Fallback: app-specific external storage (always writable, visible in Files app)
      final fallback = (await getExternalStorageDirectory()) ??
          (await getApplicationDocumentsDirectory());
      final dir = Directory(p.join(fallback.path, 'AirShare'));
      await dir.create(recursive: true);
      return (dir, 'AirShare (Phone Storage)');

    } else if (Platform.isWindows) {
      final dl = await getDownloadsDirectory();
      final base = dl ?? await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'AirShare'));
      await dir.create(recursive: true);
      return (dir, 'Downloads\\AirShare');

    } else {
      // iOS / macOS / Linux
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'AirShare'));
      await dir.create(recursive: true);
      return (dir, 'Documents/AirShare');
    }
  }

  // ── Download: core HTTP fetch + file write ────────────────────────────────

  // Returns the absolute path of the saved file, or null on error.
  // Caller is responsible for managing isDownloading / UI state around this.
  Future<String?> _fetchAndSave(String fileName, Directory targetDir) async {
    final client = http.Client();
    _activeDownloadClient = client;
    IOSink? sink;

    try {
      final uri = Uri.parse(
        '$baseUrl/download?name=${Uri.encodeComponent(fileName)}',
      );
      await ConnectionLogger.instance.log(
        'Download start',
        details: 'url=$uri platform=${Platform.operatingSystem}',
      );

      final request = http.Request('GET', uri);
      request.headers.addAll(_roomRequestHeaders());
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 10));

      await ConnectionLogger.instance.log(
        'Download response',
        details:
            'status=${response.statusCode} content_length=${response.contentLength}',
      );

      if (response.statusCode != HttpStatus.ok) {
        final body = await response.stream.bytesToString();
        throw Exception(
          body.isNotEmpty
              ? body
              : 'Download failed (${response.statusCode})',
        );
      }

      final outputFile = File(p.join(targetDir.path, fileName));
      _activeDownloadPath = outputFile.path;
      sink = outputFile.openWrite();

      final totalBytes = response.contentLength;
      var receivedBytes = 0;

      await for (final chunk in response.stream.timeout(
        const Duration(minutes: 10),
      )) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (mounted && totalBytes != null && totalBytes > 0) {
          final fileProgress = receivedBytes / totalBytes;
          setState(() {
            if (_batchDownloadTotal > 1) {
              // Smooth overall batch progress blending file-level byte progress
              downloadProgress =
                  (_batchDownloadCompleted + fileProgress) / _batchDownloadTotal;
            } else {
              downloadProgress = fileProgress;
            }
          });
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      await ConnectionLogger.instance.log(
        'Download success',
        details: 'name=$fileName bytes=$receivedBytes path=${outputFile.path}',
      );

      return outputFile.path;

    } on TimeoutException {
      if (mounted) {
        _showErrorSnackBar('Download timed out. Check Wi‑Fi and try again.', isWarning: true);
      }
      return null;
    } catch (e) {
      await ConnectionLogger.instance.log(
        'Download error',
        details: 'name=$fileName err=$e',
      );
      if (mounted) _showErrorSnackBar('Download error: $e');
      return null;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      _activeDownloadClient = null;
      client.close();

      if (_teardownConfirmed) {
        final pathToDelete = _activeDownloadPath;
        _activeDownloadPath = null;
        if (pathToDelete != null) {
          try {
            final partial = File(pathToDelete);
            if (await partial.exists()) await partial.delete();
          } catch (_) {}
        }
      } else {
        _activeDownloadPath = null;
      }
    }
  }

  // ── Download: single file (called from card "Save" button) ────────────────

  Future<void> downloadFile(String fileName) async {
    Directory targetDir;
    String pathLabel;
    try {
      (targetDir, pathLabel) = await _resolveDownloadDirectory();
    } catch (e) {
      _showErrorSnackBar('Cannot access storage: $e');
      return;
    }

    setState(() {
      isDownloading = true;
      downloadProgress = 0;
      downloadingFileName = fileName;
      _batchDownloadTotal = 1;
      _batchDownloadCompleted = 0;
      _downloadCompleted = false;
    });

    try {
      final savedPath = await _fetchAndSave(fileName, targetDir);

      if (mounted && savedPath != null) {
        setState(() {
          _downloadCompleted = true;
          downloadProgress = 1.0;
        });
        await Future.delayed(const Duration(milliseconds: 1200));
        if (mounted) _showDownloadSuccessSnackbar(fileName, savedPath, pathLabel);
      }
    } finally {
      // Guarantee the overlay is removed regardless of success, failure, or
      // cancellation — prevents the progress bar from getting permanently stuck.
      if (mounted) {
        setState(() {
          isDownloading = false;
          downloadProgress = 0;
          downloadingFileName = null;
          _batchDownloadTotal = 0;
          _batchDownloadCompleted = 0;
          _downloadCompleted = false;
        });
      }
    }
  }

  // ── Download: batch (called from selection-mode "Download N files" button) ──

  Future<void> _downloadSelected() async {
    final toDownload = List<String>.from(_selectedForDownload);
    _exitSelectionMode();
    if (toDownload.isEmpty) return;

    Directory targetDir;
    String pathLabel;
    try {
      (targetDir, pathLabel) = await _resolveDownloadDirectory();
    } catch (e) {
      _showErrorSnackBar('Cannot access storage: $e');
      return;
    }

    setState(() {
      isDownloading = true;
      _batchDownloadTotal = toDownload.length;
      _batchDownloadCompleted = 0;
      downloadProgress = 0;
      downloadingFileName = toDownload.first;
      _downloadCompleted = false;
    });

    try {
      int successCount = 0;
      for (int i = 0; i < toDownload.length; i++) {
        if (!mounted || _teardownConfirmed) break;
        setState(() {
          downloadingFileName = toDownload[i];
          _batchDownloadCompleted = i;
        });
        final savedPath = await _fetchAndSave(toDownload[i], targetDir);
        if (savedPath != null) successCount++;
        if (mounted) setState(() => _batchDownloadCompleted = i + 1);
      }

      if (mounted) {
        setState(() {
          _downloadCompleted = true;
          downloadProgress = 1.0;
        });
        await Future.delayed(const Duration(milliseconds: 1200));
        if (mounted) {
          _showBatchSuccessSnackbar(successCount, toDownload.length, pathLabel);
        }
      }
    } finally {
      // Guarantee the overlay is removed regardless of success, failure, or
      // cancellation — prevents the progress bar from getting permanently stuck.
      if (mounted) {
        setState(() {
          isDownloading = false;
          downloadProgress = 0;
          downloadingFileName = null;
          _batchDownloadTotal = 0;
          _batchDownloadCompleted = 0;
          _downloadCompleted = false;
        });
      }
    }
  }

  // ── Download: success snackbars ───────────────────────────────────────────

  void _showDownloadSuccessSnackbar(
    String fileName,
    String savedPath,
    String pathLabel,
  ) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Completed! Saved to $pathLabel',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        action: SnackBarAction(
          label: 'Open',
          textColor: Colors.white,
          onPressed: () => OpenFilex.open(savedPath),
        ),
      ),
    );
  }

  void _showBatchSuccessSnackbar(int success, int total, String pathLabel) {
    if (!mounted) return;
    final label = success == total
        ? 'Downloaded $total file${total == 1 ? "" : "s"} to $pathLabel'
        : '$success of $total files downloaded to $pathLabel';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(label, style: const TextStyle(color: Colors.white)),
        backgroundColor: success == total
            ? const Color(0xFF16A34A)
            : const Color(0xFFEA580C),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Selection mode helpers ────────────────────────────────────────────────

  void _enterSelectionMode([String? firstFile]) {
    setState(() {
      _selectionMode = true;
      _selectedForDownload.clear();
      if (firstFile != null) _selectedForDownload.add(firstFile);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedForDownload.clear();
    });
  }

  void _toggleSelection(String fileName) {
    setState(() {
      if (_selectedForDownload.contains(fileName)) {
        _selectedForDownload.remove(fileName);
      } else {
        _selectedForDownload.add(fileName);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedForDownload
        ..clear()
        ..addAll(files.map((f) => f.name));
    });
  }

  // ── Upload ────────────────────────────────────────────────────────────────

  Future<int> _resolvePickedFileSize(PlatformFile picked) async {
    if (picked.size > 0) return picked.size;
    if (picked.path != null) return File(picked.path!).length();
    if (picked.bytes != null) return picked.bytes!.length;
    return 0;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _uploadStagedFile(_StagedFile staged) async {
    int totalBytes;
    Stream<List<int>> uploadStream;
    final ext = p.extension(staged.name).toLowerCase();

    if (staged.path != null) {
      final sourceFile = File(staged.path!);
      totalBytes = await sourceFile.length();
      uploadStream = sourceFile.openRead();
    } else if (staged.bytes != null) {
      totalBytes = staged.bytes!.length;
      uploadStream = Stream.value(staged.bytes!);
    } else {
      throw Exception('Could not read selected file');
    }

    await ConnectionLogger.instance.log(
      'Upload start',
      details:
          'name=${staged.name} bytes=$totalBytes ext=$ext path=${staged.path ?? "memory"} '
          'hub=$baseUrl',
    );

    var uploadedBytes = 0;
    uploadStream = uploadStream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          uploadedBytes += chunk.length;
          if (mounted && totalBytes > 0) {
            setState(() => uploadProgress = uploadedBytes / totalBytes);
          }
          sink.add(chunk);
        },
      ),
    );

    setState(() {
      isUploading = true;
      uploadProgress = 0;
      uploadingFileName = staged.name;
    });

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/upload'),
    );
    request.headers.addAll(_uploadSenderHeaders());
    request.files.add(
      http.MultipartFile(
        'file',
        uploadStream,
        totalBytes,
        filename: staged.name,
      ),
    );

    final streamedResponse = await request.send().timeout(
      const Duration(minutes: 30),
    );
    if (streamedResponse.statusCode != 201) {
      final body = await streamedResponse.stream.bytesToString();
      throw Exception(
        body.isNotEmpty
            ? body
            : 'Upload failed (${streamedResponse.statusCode})',
      );
    }
    await ConnectionLogger.instance.log(
      'Upload success',
      details: 'name=${staged.name} bytes=$totalBytes',
    );
  }

  Future<void> pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;

      final staged = <_StagedFile>[];
      for (final picked in result.files) {
        final sizeBytes = await _resolvePickedFileSize(picked);
        staged.add(
          _StagedFile(
            name: picked.name,
            sizeBytes: sizeBytes,
            path: picked.path,
            bytes: picked.bytes,
          ),
        );
      }
      if (!mounted) return;

      setState(() => _selectedFiles = staged);

      var uploadedCount = 0;
      for (final file in staged) {
        try {
          await _uploadStagedFile(file);
          await fetchFiles(silent: true);
          uploadedCount++;
        } catch (e, st) {
          await ConnectionLogger.instance.log(
            'Upload failure',
            details: 'name=${file.name} err=$e',
          );
          debugPrint('[FileList] Upload failed for ${file.name}:\n$st');
          if (mounted) {
            _showErrorSnackBar('Upload failed for ${file.name}: $e');
          }
        }
      }

      if (!mounted) return;
      if (uploadedCount == 0) {
        _showEventSnackBar('No files were uploaded');
        return;
      }
      final label = uploadedCount == 1
          ? 'Uploaded: ${staged.first.name}'
          : 'Uploaded $uploadedCount files';
      _showEventSnackBar(label);
    } catch (e, st) {
      await ConnectionLogger.instance.log('Upload error', details: '$e');
      debugPrint('[FileList] pickAndUploadFile error:\n$st');
      if (mounted) _showErrorSnackBar('Upload error: $e');
    } finally {
      if (mounted) {
        setState(() {
          isUploading = false;
          uploadProgress = 0;
          uploadingFileName = null;
          _selectedFiles = [];
        });
      }
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void _enforceFileZoneGate() {
    final notifier = FileZoneSessionScope.of(context);
    final session = notifier.value;
    if (session == null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    if (session.hubHost != widget.hubHost || session.hubPort != widget.hubPort) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) fetchFiles();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _enforceFileZoneGate();
      if (!mounted) return;
      final notifier = FileZoneSessionScope.of(context);
      final session = notifier.value;
      if (session == null) return;
      if (session.hubHost != widget.hubHost ||
          session.hubPort != widget.hubPort) {
        return;
      }
      _initAfterGate();
    });
  }

  Future<void> _initAfterGate() async {
    if (!mounted) return;
    final notifier = FileZoneSessionScope.of(context);
    if (notifier.value == null) return;

    try {
      final identity = await LocalPeerIdentity.resolve();
      if (mounted) {
        setState(() {
          _localPeerId = identity.peerId;
          _localDisplayName = identity.displayName;
        });
      }
    } catch (e) {
      debugPrint('Local peer identity unavailable: $e');
    }

    if (!widget.isHubMode) {
      _approvalPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted && !_approvalDialogShowing) _checkForPendingTransfer();
      });
      await _postJoinNotification();
    }

    if (widget.isHubMode) {
      _ingressSubscription =
          LocalHubRuntime.instance.ingressEvents.listen((eventJson) {
        fetchFiles(silent: true);
        try {
          final event = json.decode(eventJson) as Map<String, dynamic>;
          final type = event['type'] as String? ?? '';
          if (type == 'uploaded') {
            final sender = (event['senderName'] as String? ?? 'Someone').trim();
            final fileName = event['fileName'] as String? ?? 'a file';
            _showEventSnackBar(
              '${sender.isEmpty ? "Someone" : sender} uploaded $fileName',
            );
          } else if (type == 'deleted') {
            final fileName = event['fileName'] as String? ?? 'a file';
            _showEventSnackBar('"$fileName" was removed from the session');
          }
        } catch (_) {}
      });

      _guestConnectedSub =
          LocalHubRuntime.instance.firstGuestConnected.listen((_) {
        if (mounted) {
          setState(() {
            _guestConnected = true;
            _guestConnectionTimedOut = false;
          });
          _guestConnectionTimer?.cancel();
        }
      });

      _guestJoinedSub =
          LocalHubRuntime.instance.guestJoined.listen((guestName) {
        if (mounted) {
          _showConnectionSnackBar('$guestName joined the session');
        }
      });

      _guestConnectionTimer = Timer(const Duration(seconds: 120), () {
        if (mounted && !_guestConnected) {
          setState(() => _guestConnectionTimedOut = true);
        }
      });

      _joinRequestSub =
          LocalHubRuntime.instance.joinRequests.listen((guestName) {
        if (mounted && !_joinDialogShowing) {
          _showJoinApprovalDialog(guestName);
        }
      });
    }

    await fetchFiles(silent: true);
    if (mounted) setState(() => _initialFetchDone = true);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _approvalPollTimer?.cancel();
    _ingressSubscription?.cancel();
    _guestConnectedSub?.cancel();
    _guestJoinedSub?.cancel();
    _guestConnectionTimer?.cancel();
    _joinRequestSub?.cancel();
    if (!_screenTeardownRan) {
      _screenTeardownRan = true;
      if (widget.isHubMode) {
        unawaited(SessionTeardown.runSenderTeardown());
      } else {
        unawaited(_leaveRoomAndTeardown());
      }
    }
    super.dispose();
  }

  Future<void> _leaveRoomAndTeardown() async {
    await _postLeaveNotification();
    _accessToken = null;
    _approvalPollTimer?.cancel();
    _approvalPollTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await SessionTeardown.runReceiverTeardown();
  }

  Future<void> _postLeaveNotification() async {
    if (widget.isHubMode) return;
    try {
      await http
          .post(
            Uri.parse('$baseUrl/leave'),
            headers: {
              'Content-Type': 'application/json',
              ..._roomRequestHeaders(),
            },
            body: jsonEncode({
              'guestName': _localDisplayName,
              'guestPeerId': _localPeerId ?? '',
              'peerId': _localPeerId ?? '',
              'connectionAttemptId': _connectionAttemptId,
              'accessToken': _accessToken ?? '',
            }),
          )
          .timeout(const Duration(seconds: 3));
      await ConnectionLogger.instance.log(
        'HTTP | Guest leave notified',
        details:
            'peer=${_localPeerId ?? "?"} attempt=$_connectionAttemptId',
      );
    } catch (e) {
      await ConnectionLogger.instance.log(
        'HTTP | Guest leave notify failed',
        details: '$e',
      );
    }
  }

  // ── Transfer approval (receiver-side polling) ─────────────────────────────

  Future<void> _checkForPendingTransfer() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/pending-transfer'),
        headers: _roomRequestHeaders(),
      );
      if (!mounted || _approvalDialogShowing) return;
      if (response.statusCode == 200 && response.body.trim() != 'null') {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _showTransferApprovalDialog(
          senderName: (data['senderName'] as String?) ?? 'Unknown sender',
          fileCount: (data['fileCount'] as int?) ?? 1,
          totalBytes: (data['totalBytes'] as int?) ?? 0,
        );
      }
    } catch (_) {}
  }

  Future<void> _showTransferApprovalDialog({
    required String senderName,
    required int fileCount,
    required int totalBytes,
  }) async {
    if (_approvalDialogShowing || !mounted) return;
    _approvalDialogShowing = true;

    int countdown = 30;
    Timer? countdownTimer;

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (t) {
            setDialogState(() {
              countdown--;
              if (countdown <= 0) {
                t.cancel();
                if (ctx.mounted) Navigator.of(ctx).pop(false);
              }
            });
          });

          final sizeLabel = _formatFileSize(totalBytes);
          final filesLabel = fileCount == 1 ? '1 file' : '$fileCount files';

          return AlertDialog(
            title: const Text('Incoming Transfer'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$senderName wants to send you:',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text(filesLabel),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.data_usage_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text(sizeLabel),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Auto-rejecting in $countdown s…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: countdown <= 10
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            actionsPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            actions: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    countdownTimer?.cancel();
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('Approve'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor:
                        const Color(0xFF0A2463).withValues(alpha: 0.55),
                  ),
                  onPressed: () {
                    countdownTimer?.cancel();
                    Navigator.of(ctx).pop(false);
                  },
                  child: const Text('Reject'),
                ),
              ),
            ],
          );
        },
      ),
    );

    countdownTimer?.cancel();
    _approvalDialogShowing = false;

    try {
      await http.post(
        Uri.parse('$baseUrl/transfer-response'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'approved': approved ?? false}),
      );
    } catch (_) {}
  }

  // ── Join approval dialog (host only) ─────────────────────────────────────

  Future<void> _showJoinApprovalDialog(String guestName) async {
    if (_joinDialogShowing || !mounted) return;
    _joinDialogShowing = true;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Request'),
        content: Text('$guestName wants to join this session.'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0A2463).withValues(alpha: 0.55),
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
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
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    _joinDialogShowing = false;
    LocalHubRuntime.instance.respondToJoinRequest(approved ?? true);
  }

  // ── Cancel-during-transfer dialog ─────────────────────────────────────────

  Future<void> _showCancelDialog() async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel transfer?'),
        content: const Text(
          'A file transfer is in progress. Leaving now will leave it incomplete.',
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continue'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0A2463).withValues(alpha: 0.55),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel transfer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _teardownConfirmed = true;
    _activeDownloadClient?.close();
    _activeDownloadClient = null;
    _showEventSnackBar('Transfer canceled');
    if (mounted) Navigator.of(context).pop();
  }

  // ── AP-Isolation help dialog (Host side) ─────────────────────────────────

  void _showHostApIsolationHelp() {
    if (!mounted) return;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    Widget bullet(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0A2463))),
              Expanded(child: Text(text)),
            ],
          ),
        );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guests Can\'t Connect?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'If a Guest is on public Wi-Fi (campus, café, hotel), '
              'AP Isolation may be blocking their connection to this Hub.',
            ),
            const SizedBox(height: 12),
            const Text(
              'How to fix it:',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0A2463)),
            ),
            const SizedBox(height: 8),
            if (isMobile) ...[
              bullet('Enable this device\'s Mobile Hotspot in Settings.'),
              bullet('Ask the Guest to connect to that hotspot.'),
              bullet(
                  'The Guest should then open AirShare and Join again.'),
            ] else ...[
              bullet(
                  'Ask the Guest to enable their phone\'s Mobile Hotspot.'),
              bullet(
                  'Connect this computer to that hotspot via Wi-Fi settings.'),
              bullet(
                  'Both devices will then be on a private network without AP Isolation.'),
            ],
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor:
                  const Color(0xFF0A2463).withValues(alpha: 0.55),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
          if (isMobile)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  await WlanLinkManager.instance.openWirelessSettings();
                } catch (_) {}
              },
              child: const Text('Open Wi-Fi Settings'),
            ),
        ],
      ),
    );
  }

  Future<void> _postJoinNotification() async {
    try {
      // The hub blocks on /join until the host approves or declines (max 30 s).
      // We allow up to 35 s so the server's auto-approve has time to fire first.
      final response = await http
          .post(
            Uri.parse('$baseUrl/join'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'guestName': _localDisplayName,
              'guestPeerId': _localPeerId ?? '',
              'peerId': _localPeerId ?? '',
              'connectionAttemptId': _connectionAttemptId,
            }),
          )
          .timeout(const Duration(seconds: 35));

      if (!mounted) return;

      final body = json.decode(response.body) as Map<String, dynamic>?;
      final status = (body?['status'] as String?)?.trim() ?? 'approved';
      final token = (body?['accessToken'] as String?)?.trim();
      if (token != null && token.isNotEmpty && mounted) {
        setState(() => _accessToken = token);
      }

      if (status == 'declined') {
        _accessToken = null;
        // Stop all hub-polling timers immediately — no further requests should
        // be sent to this host after a decline.
        _refreshTimer?.cancel();
        _refreshTimer = null;
        _approvalPollTimer?.cancel();
        _approvalPollTimer = null;

        // Show the snackbar. Because MaterialApp provides a root-level
        // ScaffoldMessenger, this snackbar persists across the navigation below.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connection Declined by Host.'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 4),
          ),
        );
        // Navigate back immediately — no delay — to prevent any further
        // reconnect attempts or polling while waiting.
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        _showConnectionSnackBar(
          'Connection Approved! You are now joined to the room.',
        );
      }
    } catch (_) {
      // Network error or timeout — show a generic connected message.
      if (mounted) _showConnectionSnackBar('Connected to session successfully!');
    }
  }

  // ── Formatting helpers ────────────────────────────────────────────────────

  String _senderLabel(SharedFileEntry entry) {
    if (entry.senderName.isNotEmpty && entry.senderName != 'Unknown') {
      return entry.senderName;
    }
    if (entry.senderId.isNotEmpty) return entry.senderId;
    return 'Unknown';
  }

  String _formatTime(DateTime sharedAt) {
    if (sharedAt.millisecondsSinceEpoch == 0) return '--:--';
    final local = sharedAt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ── Status banners ────────────────────────────────────────────────────────

  Widget _buildLanBadge() {
    final tt = Theme.of(context).textTheme;
    return Material(
      color: const Color(0xFFDCFCE7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.wifi, size: 16, color: Color(0xFF16A34A)),
            const SizedBox(width: 8),
            Text(
              'Connected via Local Network',
              style: tt.bodySmall?.copyWith(
                color: const Color(0xFF15803D),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'LAN',
                style: tt.labelSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Download overlay ──────────────────────────────────────────────────────

  Widget _buildDownloadOverlay() {
    final isBatch = _batchDownloadTotal > 1;
    final String topLabel;
    final String fileNameLabel;
    final String percentLabel;

    if (_downloadCompleted) {
      topLabel = isBatch
          ? 'Completed! ✓  $_batchDownloadCompleted of $_batchDownloadTotal'
          : 'Completed! ✓';
      fileNameLabel = isBatch ? '$_batchDownloadCompleted files saved' : (downloadingFileName ?? 'file');
      percentLabel = '100%';
    } else if (isBatch) {
      topLabel = 'Downloading ${_batchDownloadCompleted + 1} of $_batchDownloadTotal';
      fileNameLabel = downloadingFileName ?? 'file';
      percentLabel = '${(downloadProgress * 100).toInt()}%';
    } else {
      topLabel = 'Downloading';
      fileNameLabel = downloadingFileName ?? 'file';
      percentLabel = '${(downloadProgress * 100).toInt()}%';
    }

    return Material(
      elevation: 10,
      borderRadius: BorderRadius.circular(20),
      shadowColor: const Color(0xFF1E40AF),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _downloadCompleted
                        ? Icons.check_circle_outline
                        : (isBatch ? Icons.download_for_offline_outlined : Icons.download_outlined),
                    size: 20,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        topLabel,
                        style: TextStyle(
                          color: _downloadCompleted
                              ? const Color(0xFF86EFAC)
                              : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        fileNameLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  percentLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _downloadCompleted
                    ? 1.0
                    : (downloadProgress > 0 ? downloadProgress : null),
                backgroundColor: Colors.white.withValues(alpha: 0.25),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                minHeight: 7,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Grid content ──────────────────────────────────────────────────────────

  Widget _buildGrid() {
    if (files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No files yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'Upload a file to share it with everyone in this session.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.4,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final entry = files[index];
        final isSelected = _selectedForDownload.contains(entry.name);
        return _FileCard(
          entry: entry,
          canDelete: _canDelete(entry) && !_selectionMode,
          senderLabel: _senderLabel(entry),
          sizeLabel: _formatFileSize(entry.sizeBytes),
          timeLabel: _formatTime(entry.sharedAt),
          isSelected: isSelected,
          isSelectionMode: _selectionMode,
          onDownload: () => downloadFile(entry.name),
          onDelete: () => _confirmAndDelete(entry),
          onToggleSelect: () => _toggleSelection(entry.name),
          onEnterSelectionMode: () => _enterSelectionMode(entry.name),
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final appBar = _selectionMode
        ? AppBar(
            backgroundColor: const Color(0xFFDBEAFE),
            foregroundColor: const Color(0xFF0A2463),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _exitSelectionMode,
              tooltip: 'Cancel selection',
            ),
            title: Text(
              '${_selectedForDownload.length} Selected',
              style: const TextStyle(
                color: Color(0xFF0A2463),
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              TextButton(
                onPressed: _selectAll,
                child: const Text(
                  'Select All',
                  style: TextStyle(
                    color: Color(0xFF2563EB),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          )
        : AppBar(
            title: Text(
              widget.modeTitle,
              style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            actions: [
              if (files.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.checklist_outlined),
                  tooltip: 'Select files',
                  onPressed: _enterSelectionMode,
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(height: 1, color: cs.outlineVariant),
            ),
          );

    final selectionBottomBar = (_selectionMode && _selectedForDownload.isNotEmpty)
        ? Container(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              12 + MediaQuery.of(context).padding.bottom,
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)],
              ),
            ),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1E3A8A),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: isDownloading ? null : _downloadSelected,
              icon: const Icon(Icons.download_outlined),
              label: Text(
                'Download ${_selectedForDownload.length} '
                'file${_selectedForDownload.length == 1 ? "" : "s"}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          )
        : null;

    return PopScope(
      canPop: !_isTransferActive && !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_selectionMode) {
            _exitSelectionMode();
          } else {
            _showCancelDialog();
          }
        } else {
          _screenTeardownRan = true;
        }
      },
      child: Scaffold(
        appBar: appBar,
        bottomNavigationBar: selectionBottomBar,
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton.extended(
                onPressed: isUploading ? null : pickAndUploadFile,
                backgroundColor: const Color(0xFF1E40AF),
                foregroundColor: Colors.white,
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload'),
              ),
        body: Column(
          children: [
            // Staged files preview
            if (_selectedFiles.isNotEmpty)
              Material(
                color: cs.surfaceContainerLow,
                child: SizedBox(
                  height: 100,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    itemCount: _selectedFiles.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final file = _selectedFiles[index];
                      return ListTile(
                        dense: true,
                        leading:
                            const Icon(Icons.upload_file, size: 20),
                        title: Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing:
                            Text(_formatFileSize(file.sizeBytes)),
                      );
                    },
                  ),
                ),
              ),

            // Upload progress
            if (isUploading)
              Material(
                color: const Color(0xFFEFF6FF),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Uploading: ${uploadingFileName ?? "file"}',
                        style: tt.bodyMedium?.copyWith(
                          color: const Color(0xFF0A2463),
                        ),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: uploadProgress,
                        color: const Color(0xFF2563EB),
                        backgroundColor: const Color(0xFFBFDBFE),
                      ),
                    ],
                  ),
                ),
              ),

            // LAN / waiting-for-guest banners
            if (!widget.isHubMode || _guestConnected) _buildLanBadge(),
            if (widget.isHubMode && !_guestConnected)
              Material(
                color: _guestConnectionTimedOut
                    ? const Color(0xFFFFEDED)
                    : const Color(0xFFEFF6FF),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      if (!_guestConnectionTimedOut)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF2563EB),
                          ),
                        )
                      else
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: Color(0xFFDC2626),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _guestConnectionTimedOut
                              ? 'No participant connected after 2 min — still waiting'
                              : 'Waiting for participants to connect…',
                          style: tt.bodyMedium?.copyWith(
                            color: _guestConnectionTimedOut
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF0A2463),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.help_outline,
                          size: 17,
                          color: Color(0xFF2563EB),
                        ),
                        tooltip: 'Guests can\'t connect?',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: _showHostApIsolationHelp,
                      ),
                    ],
                  ),
                ),
              ),

            // Hub status indicator (host only)
            if (widget.isHubMode)
              AnimatedBuilder(
                animation: _hubStatus,
                builder: (context, _) {
                  final isError =
                      _hubStatus.lifecycle == HubLifecycle.error;
                  final statusText =
                      isError && _hubStatus.lastError != null
                          ? '${_hubStatus.message}: ${_hubStatus.lastError}'
                          : _hubStatus.message;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isError
                                ? const Color(0xFFFFEDED)
                                : const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isError
                                  ? const Color(0xFFEF4444)
                                      .withValues(alpha: 0.35)
                                  : const Color(0xFF2563EB)
                                      .withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isError
                                    ? Icons.error_outline
                                    : Icons.radio_button_checked,
                                size: 13,
                                color: isError
                                    ? const Color(0xFFDC2626)
                                    : const Color(0xFF16A34A),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                statusText,
                                style: tt.labelSmall?.copyWith(
                                  color: isError
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFF0A2463),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

            // Download progress overlay
            if (isDownloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: _buildDownloadOverlay(),
              ),

            // Selection mode hint
            if (_selectionMode && _selectedForDownload.isEmpty)
              Material(
                color: const Color(0xFFEFF6FF),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: Color(0xFF2563EB)),
                      const SizedBox(width: 8),
                      Text(
                        'Tap files to select them for download',
                        style: tt.bodySmall?.copyWith(
                          color: const Color(0xFF0A2463),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // File grid
            Expanded(child: _buildGrid()),
          ],
        ),
      ),
    );
  }
}

// ── File card widget ─────────────────────────────────────────────────────────

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.entry,
    required this.canDelete,
    required this.senderLabel,
    required this.sizeLabel,
    required this.timeLabel,
    required this.onDownload,
    required this.onDelete,
    required this.onToggleSelect,
    required this.onEnterSelectionMode,
    this.isSelected = false,
    this.isSelectionMode = false,
  });

  final SharedFileEntry entry;
  final bool canDelete;
  final String senderLabel;
  final String sizeLabel;
  final String timeLabel;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onToggleSelect;
  final VoidCallback onEnterSelectionMode;
  final bool isSelected;
  final bool isSelectionMode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = _fileTypeColor(entry.name);
    final icon = _fileTypeIcon(entry.name);

    Widget card = Card(
      elevation: isSelected ? 3 : 1,
      shadowColor: isSelected
          ? const Color(0xFF2563EB).withValues(alpha: 0.4)
          : accent.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? const BorderSide(color: Color(0xFF2563EB), width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // ── Horizontal layout: left icon panel + right content ──────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left: accent-tinted icon strip (full card height)
              Container(
                width: 54,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      accent.withValues(alpha: 0.18),
                      accent.withValues(alpha: 0.10),
                    ],
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 20, color: accent),
                  ),
                ),
              ),

              // Right: filename, meta, action — centered vertically,
              // no Spacer/Expanded so height is driven by the grid ratio alone.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        senderLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '$sizeLabel · $timeLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.outline,
                        ),
                      ),
                      const SizedBox(height: 5),
                      if (!isSelectionMode)
                        Row(
                          children: [
                            Expanded(
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  foregroundColor: accent,
                                ),
                                onPressed: onDownload,
                                icon: const Icon(
                                    Icons.download_outlined,
                                    size: 13),
                                label: const Text(
                                  'Save',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ),
                            if (canDelete)
                              InkWell(
                                onTap: onDelete,
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.delete_outline,
                                    size: 15,
                                    color: cs.error,
                                  ),
                                ),
                              ),
                          ],
                        )
                      else
                        Text(
                          isSelected ? 'Selected' : 'Tap to select',
                          style: TextStyle(
                            fontSize: 10,
                            color: isSelected
                                ? const Color(0xFF2563EB)
                                : cs.onSurfaceVariant,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Blue tint overlay when selected
          if (isSelected)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xFF2563EB).withValues(alpha: 0.07),
                ),
              ),
            ),

          // Selection indicator circle (top-right corner)
          if (isSelectionMode)
            Positioned(
              top: 6,
              right: 6,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected
                      ? const Color(0xFF2563EB)
                      : Colors.white.withValues(alpha: 0.9),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : Colors.grey.shade400,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 13, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );

    return GestureDetector(
      onTap: isSelectionMode ? onToggleSelect : null,
      onLongPress: isSelectionMode ? null : onEnterSelectionMode,
      child: card,
    );
  }
}
