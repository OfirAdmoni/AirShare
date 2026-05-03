import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:air_share/discovery_page.dart';
import 'package:air_share/hub_status.dart';
import 'package:air_share/local_hub_runtime.dart';

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

  @override
  Widget build(BuildContext context) {
    return HubStatusScope(
      status: _hubStatus,
      child: MaterialApp(
        title: 'AirShare',
        theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
        home: const ModeSelectionPage(),
      ),
    );
  }
}

class ModeSelectionPage extends StatelessWidget {
  const ModeSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AirShare Transfer Console')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const FileListScreen(
                          hubHost: '127.0.0.1',
                          modeTitle: 'Receive Files',
                          isHubMode: true,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.move_to_inbox),
                  label: const Text('Receive Files'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DiscoveryPage(
                          onHubSelected: (hubHost) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => FileListScreen(
                                  hubHost: hubHost,
                                  modeTitle: 'Send Files',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.send),
                  label: const Text('Send Files'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FileListScreen extends StatefulWidget {
  const FileListScreen({
    required this.hubHost,
    required this.modeTitle,
    this.isHubMode = false,
    super.key,
  });

  final String hubHost;
  final String modeTitle;
  final bool isHubMode;

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  List<dynamic> files = [];
  bool isDownloading = false;
  double downloadProgress = 0;
  String? downloadingFileName;
  bool isUploading = false;
  double uploadProgress = 0;
  String? uploadingFileName;
  StreamSubscription<String>? _ingressSubscription;

  String get baseUrl => 'http://${widget.hubHost}:8080';
  HubStatus get _hubStatus => HubStatusScope.of(context);

  // פונקציה שפונה למנוע ה-Go ומבקשת את רשימת הקבצים
  Future<void> fetchFiles() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/files'));
      if (response.statusCode == 200) {
        setState(() {
          files = json.decode(response.body);
        });
      }
    } catch (e) {
      debugPrint('Data directory query failed: $e');
    }
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      final airShareDir = Directory('/storage/emulated/0/Download/AirShare');
      if (!await airShareDir.exists()) {
        await airShareDir.create(recursive: true);
      }
      return airShareDir;
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

      final outputFile = File(
        '${targetDir.path}${Platform.pathSeparator}$fileName',
      );
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

  Future<void> pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || result.files.isEmpty) {
        return;
      }

      final picked = result.files.first;
      int totalBytes;
      Stream<List<int>> uploadStream;

      if (picked.path != null) {
        final sourceFile = File(picked.path!);
        totalBytes = await sourceFile.length();
        uploadStream = sourceFile.openRead();
      } else if (picked.bytes != null) {
        totalBytes = picked.bytes!.length;
        uploadStream = Stream.value(picked.bytes!);
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
        uploadingFileName = picked.name;
      });

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/upload'),
      );
      request.files.add(
        http.MultipartFile('file', uploadStream, totalBytes, filename: picked.name),
      );

      final streamedResponse = await request.send();
      if (streamedResponse.statusCode != 201) {
        throw Exception('Upload failed (${streamedResponse.statusCode})');
      }

      await fetchFiles();

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Uploaded: ${picked.name}')));
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
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (widget.isHubMode && (Platform.isAndroid || Platform.isIOS)) {
        await LocalHubRuntime.instance.ensureStarted(_hubStatus);
        _ingressSubscription = LocalHubRuntime.instance.ingressEvents.listen((_) {
          fetchFiles();
        });
      }
      await fetchFiles();
    });
  }

  @override
  void dispose() {
    _ingressSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = files.isEmpty
        ? const Center(child: Text('Active Directory is empty or service offline'))
        : ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              return ListTile(
                leading: const Icon(Icons.file_present),
                title: Text(files[index]),
                trailing: IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () => downloadFile(files[index] as String),
                ),
              );
            },
          );

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.modeTitle} • Peer ${widget.hubHost}'),
      ),
      body: Column(
        children: [
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