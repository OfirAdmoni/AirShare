import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:air_share/discovery_page.dart';

void main() {
  runApp(const AirShareApp());
}

class AirShareApp extends StatelessWidget {
  const AirShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirShare',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: Builder(
        builder: (navigatorContext) => DiscoveryPage(
          onServerSelected: (host) {
            Navigator.of(navigatorContext).pushReplacement(
              MaterialPageRoute(
                builder: (_) => FileListScreen(serverHost: host),
              ),
            );
          },
        ),
      ),
    );
  }
}

class FileListScreen extends StatefulWidget {
  const FileListScreen({required this.serverHost, super.key});

  final String serverHost;

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

  String get baseUrl => 'http://${widget.serverHost}:8080';

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
      print("Error connecting to engine: $e");
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
      ).showSnackBar(SnackBar(content: Text('Download error: $e')));
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
      ).showSnackBar(SnackBar(content: Text('Upload error: $e')));
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
    fetchFiles(); // נטען את הקבצים ברגע שהאפליקציה עולה
  }

  @override
  Widget build(BuildContext context) {
    final content = files.isEmpty
        ? const Center(child: Text("No files shared or Engine is offline"))
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
      appBar: AppBar(title: Text('AirShare - ${widget.serverHost}')),
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
                      'Uploading ${uploadingFileName ?? "file"}...',
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
                      'Downloading ${downloadingFileName ?? "file"}...',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: downloadProgress),
                  ],
                ),
              ),
            ),
          Expanded(child: content),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: pickAndUploadFile,
        child: const Icon(Icons.add),
      ),
    );
  }
}