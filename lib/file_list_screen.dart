import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:air_share/file_zone_session.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';
import 'package:air_share/local_peer_identity.dart';
import 'package:air_share/session_teardown.dart';
import 'package:air_share/shared_file_entry.dart';

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
    super.key,
  });

  final String hubHost;
  final int hubPort;
  final String modeTitle;
  final bool isHubMode;

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
  List<_StagedFile> _selectedFiles = [];
  bool isDownloading = false;
  double downloadProgress = 0;
  String? downloadingFileName;
  bool isUploading = false;
  double uploadProgress = 0;
  String? uploadingFileName;
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
  bool _downloadCompleted = false;

  bool get _isTransferActive => isDownloading || isUploading;

  String get baseUrl => 'http://${widget.hubHost}:${widget.hubPort}';
  HubStatus get _hubStatus => HubStatusScope.of(context);

  Map<String, String> _roomRequestHeaders() => {
        // ignore: use_null_aware_elements
        if (_localPeerId != null)
          'x-airshare-requester-peer-id': _localPeerId!,
        'x-airshare-requester-role': widget.isHubMode ? 'host' : 'guest',
      };

  Map<String, String> _uploadSenderHeaders() => {
        // ignore: use_null_aware_elements
        if (_localPeerId != null) 'x-airshare-sender-id': _localPeerId!,
        'x-airshare-sender-name': _localDisplayName,
        'x-airshare-requester-role': widget.isHubMode ? 'host' : 'guest',
      };

  // ── File list ─────────────────────────────────────────────────────────────

  Future<void> fetchFiles({bool silent = false}) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/files'));
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
        // Guest-side change detection: compare against previous snapshot.
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
        backgroundColor: const Color(0xFF2563EB),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  void _showConnectionSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.green.shade600,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
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
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
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
      _showEventSnackBar('You can only delete files you shared');
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
      _showEventSnackBar('Delete failed: $e');
    }
  }

  // ── Download ──────────────────────────────────────────────────────────────

  Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      final appDir = await getExternalStorageDirectory();
      final base = appDir ?? await getApplicationDocumentsDirectory();
      final receivedDir = Directory(p.join(base.path, 'AirShare', 'Received'));
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      return receivedDir;
    }
    if (Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    final fallback = await getDownloadsDirectory();
    if (fallback != null) return fallback;
    return getApplicationDocumentsDirectory();
  }

  Future<void> downloadFile(String fileName) async {
    setState(() {
      isDownloading = true;
      downloadProgress = 0;
      downloadingFileName = fileName;
    });

    final client = http.Client();
    _activeDownloadClient = client;
    IOSink? sink;

    try {
      final uri = Uri.parse(
        '$baseUrl/download?name=${Uri.encodeComponent(fileName)}',
      );
      final request = http.Request('GET', uri);
      final response = await client.send(request);

      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Download failed (${response.statusCode})');
      }

      final targetDir = await _resolveDownloadDirectory();
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final outputFile = File(p.join(targetDir.path, fileName));
      _activeDownloadPath = outputFile.path;
      sink = outputFile.openWrite();

      final totalBytes = response.contentLength;
      var receivedBytes = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes != null && totalBytes > 0 && mounted) {
          setState(() => downloadProgress = receivedBytes / totalBytes);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Lock progress at 100 % and show "Completed!" for 1.5 s.
      if (mounted) {
        setState(() {
          downloadProgress = 1.0;
          _downloadCompleted = true;
        });
        await Future.delayed(const Duration(milliseconds: 3500));
      }

      if (!mounted) return;
      _showEventSnackBar('Saved to: ${outputFile.path}');
    } catch (e) {
      if (!mounted) return;
      _showEventSnackBar('Download error: $e');
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

      if (mounted) {
        setState(() {
          isDownloading = false;
          downloadProgress = 0;
          downloadingFileName = null;
          _downloadCompleted = false;
        });
      }
    }
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

    final streamedResponse = await request.send();
    if (streamedResponse.statusCode != 201) {
      throw Exception('Upload failed (${streamedResponse.statusCode})');
    }
  }

  Future<void> pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
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
        await _uploadStagedFile(file);
        await fetchFiles(silent: true);
        uploadedCount++;
      }

      if (!mounted) return;
      final label = uploadedCount == 1
          ? 'Uploaded: ${staged.first.name}'
          : 'Uploaded $uploadedCount files';
      _showEventSnackBar(label);
    } catch (e) {
      if (mounted) _showEventSnackBar('Upload error: $e');
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
      _postJoinNotification();
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
        } catch (_) {
          // Legacy plain-string event — ignore, UI still refreshed above.
        }
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
    if (!_screenTeardownRan) {
      _screenTeardownRan = true;
      if (widget.isHubMode) {
        unawaited(SessionTeardown.runSenderTeardown());
      } else {
        unawaited(SessionTeardown.runReceiverTeardown());
      }
    }
    super.dispose();
  }

  // ── Transfer approval (receiver-side polling) ─────────────────────────────

  Future<void> _checkForPendingTransfer() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/pending-transfer'));
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
                child: OutlinedButton(
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
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continue'),
          ),
          TextButton(
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

  Future<void> _postJoinNotification() async {
    try {
      await http.post(
        Uri.parse('$baseUrl/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'guestName': _localDisplayName}),
      );
      if (mounted) {
        _showConnectionSnackBar('Connected to session successfully!');
      }
    } catch (_) {}
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
                        : Icons.download_outlined,
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
                        _downloadCompleted ? 'Completed! ✓' : 'Downloading',
                        style: TextStyle(
                          color: _downloadCompleted
                              ? const Color(0xFF86EFAC)
                              : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        downloadingFileName ?? 'file',
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
                  '${_downloadCompleted ? 100 : (downloadProgress * 100).toInt()}%',
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

  int _columnCount(double width) {
    if (width >= 900) return 4;
    if (width >= 600) return 3;
    return 2;
  }

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _columnCount(constraints.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.78,
          ),
          itemCount: files.length,
          itemBuilder: (context, index) {
            final entry = files[index];
            return _FileCard(
              entry: entry,
              canDelete: _canDelete(entry),
              senderLabel: _senderLabel(entry),
              sizeLabel: _formatFileSize(entry.sizeBytes),
              timeLabel: _formatTime(entry.sharedAt),
              onDownload: () => downloadFile(entry.name),
              onDelete: () => _confirmAndDelete(entry),
            );
          },
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return PopScope(
      canPop: !_isTransferActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _showCancelDialog();
        } else {
          _screenTeardownRan = true;
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.modeTitle,
            style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, color: cs.outlineVariant),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
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
                      Text(
                        _guestConnectionTimedOut
                            ? 'No participant connected after 2 min — still waiting'
                            : 'Waiting for participants to connect…',
                        style: tt.bodyMedium?.copyWith(
                          color: _guestConnectionTimedOut
                              ? const Color(0xFFDC2626)
                              : const Color(0xFF0A2463),
                        ),
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

            // Download progress
            if (isDownloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: _buildDownloadOverlay(),
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
  });

  final SharedFileEntry entry;
  final bool canDelete;
  final String senderLabel;
  final String sizeLabel;
  final String timeLabel;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final accent = _fileTypeColor(entry.name);
    final icon = _fileTypeIcon(entry.name);

    return Card(
      elevation: 1,
      shadowColor: accent.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Coloured icon header
          Container(
            height: 88,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.15),
                  accent.withValues(alpha: 0.08),
                ],
              ),
            ),
            child: Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 28, color: accent),
              ),
            ),
          ),

          // Metadata
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    senderLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$sizeLabel · $timeLabel',
                    style: tt.labelSmall?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
          ),

          // Action row
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      foregroundColor: accent,
                    ),
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: const Text('Save'),
                  ),
                ),
                if (canDelete) ...[
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: 'Delete',
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: cs.error,
                    ),
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: onDelete,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
