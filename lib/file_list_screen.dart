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
import 'package:air_share/shared_file_entry.dart';

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
  bool _guestConnected = false;
  bool _guestConnectionTimedOut = false;
  Timer? _guestConnectionTimer;
  Timer? _refreshTimer;

  String get baseUrl => 'http://${widget.hubHost}:${widget.hubPort}';
  HubStatus get _hubStatus => HubStatusScope.of(context);

  Map<String, String> _roomRequestHeaders() => {
        if (_localPeerId != null)
          'x-airshare-requester-peer-id': _localPeerId!,
        'x-airshare-requester-role': widget.isHubMode ? 'host' : 'guest',
      };

  Map<String, String> _uploadSenderHeaders() => {
        if (_localPeerId != null) 'x-airshare-sender-id': _localPeerId!,
        'x-airshare-sender-name': _localDisplayName,
        'x-airshare-requester-role': widget.isHubMode ? 'host' : 'guest',
      };

  Future<void> fetchFiles() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/files'));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        final parsed = <SharedFileEntry>[];
        if (decoded is List) {
          for (final item in decoded) {
            parsed.add(SharedFileEntry.fromJson(item));
          }
        }
        if (!mounted) return;
        setState(() => files = parsed);
      }
    } catch (e) {
      debugPrint('Data directory query failed: $e');
    }
  }

  Future<void> deleteFile(SharedFileEntry entry) async {
    if (!_canDelete(entry)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You can only delete files you shared'),
        ),
      );
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
      await fetchFiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted: ${entry.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  bool _canDelete(SharedFileEntry entry) {
    if (widget.isHubMode) return true;
    if (_localPeerId == null || _localPeerId!.isEmpty) return false;
    return entry.senderId.isNotEmpty && entry.senderId == _localPeerId;
  }

  String _senderLabel(SharedFileEntry entry) {
    if (entry.senderName.isNotEmpty && entry.senderName != 'Unknown') {
      return entry.senderName;
    }
    if (entry.senderId.isNotEmpty) return entry.senderId;
    return 'Unknown sender';
  }

  String _formatSharedAt(DateTime sharedAt) {
    if (sharedAt.millisecondsSinceEpoch == 0) return 'Unknown time';
    final local = sharedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

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

    final fallbackDir = await getDownloadsDirectory();
    if (fallbackDir != null) {
      return fallbackDir;
    }
    return getApplicationDocumentsDirectory();
  }

  Future<void> downloadFile(String fileName) async {
    setState(() {
      isDownloading = true;
      downloadProgress = 0;
      downloadingFileName = fileName;
    });

    final client = http.Client();
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
      final sink = outputFile.openWrite();

      final totalBytes = response.contentLength;
      var receivedBytes = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        if (totalBytes != null && totalBytes > 0 && mounted) {
          setState(() {
            downloadProgress = receivedBytes / totalBytes;
          });
        }
      }

      await sink.flush();
      await sink.close();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to: ${outputFile.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Data egress error: $e')));
    } finally {
      client.close();
      if (!mounted) return;
      setState(() {
        isDownloading = false;
        downloadProgress = 0;
        downloadingFileName = null;
      });
    }
  }

  Future<int> _resolvePickedFileSize(PlatformFile picked) async {
    if (picked.size > 0) return picked.size;
    if (picked.path != null) return File(picked.path!).length();
    if (picked.bytes != null) return picked.bytes!.length;
    return 0;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
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
            setState(() {
              uploadProgress = uploadedBytes / totalBytes;
            });
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
      http.MultipartFile('file', uploadStream, totalBytes, filename: staged.name),
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
      if (result == null || result.files.isEmpty) {
        return;
      }

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
        await fetchFiles();
        uploadedCount++;
      }

      if (!mounted) return;
      final label = uploadedCount == 1
          ? 'Uploaded: ${staged.first.name}'
          : 'Uploaded $uploadedCount files';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Data ingress error: $e')));
    } finally {
      if (!mounted) return;
      setState(() {
        isUploading = false;
        uploadProgress = 0;
        uploadingFileName = null;
        _selectedFiles = [];
      });
    }
  }

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
      if (session.hubHost != widget.hubHost || session.hubPort != widget.hubPort) {
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

    if (widget.isHubMode) {
      _ingressSubscription = LocalHubRuntime.instance.ingressEvents.listen((_) {
        fetchFiles();
      });
      _guestConnectedSub = LocalHubRuntime.instance.firstGuestConnected.listen((_) {
        if (mounted) {
          setState(() {
            _guestConnected = true;
            _guestConnectionTimedOut = false;
          });
          _guestConnectionTimer?.cancel();
        }
      });
      _guestConnectionTimer = Timer(const Duration(seconds: 120), () {
        if (mounted && !_guestConnected) {
          setState(() => _guestConnectionTimedOut = true);
        }
      });
    }
    await fetchFiles();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _ingressSubscription?.cancel();
    _guestConnectedSub?.cancel();
    _guestConnectionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = files.isEmpty
        ? const Center(child: Text('Active Directory is empty or service offline'))
        : ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              final entry = files[index];
              final canDelete = _canDelete(entry);
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(
                        'From: ${_senderLabel(entry)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        'Received: ${_formatSharedAt(entry.sharedAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        'Size: ${_formatFileSize(entry.sizeBytes)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (!canDelete && !widget.isHubMode)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Only the sender or room host can delete this file',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ),
                    ],
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Download',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: () => downloadFile(entry.name),
                      ),
                      IconButton(
                        tooltip: canDelete
                            ? 'Delete'
                            : 'You can only delete files you shared',
                        icon: Icon(
                          Icons.delete_outline,
                          color: canDelete
                              ? null
                              : Theme.of(context).disabledColor,
                        ),
                        onPressed: canDelete ? () => deleteFile(entry) : null,
                      ),
                    ],
                  ),
                ),
              );
            },
          );

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.modeTitle} • ${widget.hubHost}:${widget.hubPort}'),
      ),
      body: Column(
        children: [
          if (_selectedFiles.isNotEmpty)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: SizedBox(
                height: 120,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  itemCount: _selectedFiles.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final file = _selectedFiles[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.upload_file, size: 20),
                      title: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(_formatFileSize(file.sizeBytes)),
                    );
                  },
                ),
              ),
            ),
          if (isUploading)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data Ingress: ${uploadingFileName ?? "file"}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: uploadProgress),
                  ],
                ),
              ),
            ),
          if (isDownloading)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data Egress: ${downloadingFileName ?? "file"}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: downloadProgress),
                  ],
                ),
              ),
            ),
          if (widget.isHubMode && !_guestConnected)
            Material(
              color: _guestConnectionTimedOut
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    if (!_guestConnectionTimedOut)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    const SizedBox(width: 12),
                    Text(
                      _guestConnectionTimedOut
                          ? 'No receiver connected after 2 min — still waiting'
                          : 'Waiting for receiver to connect…',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: _guestConnectionTimedOut
                                ? Theme.of(context).colorScheme.onErrorContainer
                                : Theme.of(context).colorScheme.onSecondaryContainer,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: content),
          if (widget.isHubMode)
            AnimatedBuilder(
              animation: _hubStatus,
              builder: (context, _) {
                final isError = _hubStatus.lifecycle == HubLifecycle.error;
                return Container(
                  width: double.infinity,
                  color: isError
                      ? Theme.of(context).colorScheme.errorContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text(
                    isError && _hubStatus.lastError != null
                        ? '${_hubStatus.message}: ${_hubStatus.lastError}'
                        : _hubStatus.message,
                  ),
                );
              },
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: pickAndUploadFile,
        child: const Icon(Icons.add),
      ),
    );
  }
}
