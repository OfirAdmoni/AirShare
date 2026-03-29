import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
      home: const FileListScreen(),
    );
  }
}

class FileListScreen extends StatefulWidget {
  const FileListScreen({super.key});

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  List<dynamic> files = [];

  // פונקציה שפונה למנוע ה-Go ומבקשת את רשימת הקבצים
  Future<void> fetchFiles() async {
    try {
      final response = await http.get(Uri.parse('http://localhost:8080/files'));
      if (response.statusCode == 200) {
        setState(() {
          files = json.decode(response.body);
        });
      }
    } catch (e) {
      print("Error connecting to engine: $e");
    }
  }

  Future<void> downloadFile(String fileName) async {
    try {
      final uri = Uri.parse(
        'http://localhost:8080/download?name=${Uri.encodeComponent(fileName)}',
      );
      final response = await http.get(uri);

      if (response.statusCode != 200) {
        throw Exception('Download failed (${response.statusCode})');
      }

      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) {
        throw Exception('Could not access Downloads directory');
      }

      final outputFile = File('${downloadsDir.path}${Platform.pathSeparator}$fileName');
      await outputFile.writeAsBytes(response.bodyBytes);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to: ${outputFile.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download error: $e')));
    }
  }

  Future<void> pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || result.files.isEmpty) {
        return;
      }

      final picked = result.files.first;
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('http://localhost:8080/upload'),
      );

      if (picked.path != null) {
        request.files.add(await http.MultipartFile.fromPath('file', picked.path!));
      } else if (picked.bytes != null) {
        request.files.add(
          http.MultipartFile.fromBytes('file', picked.bytes!, filename: picked.name),
        );
      } else {
        throw Exception('Could not read selected file');
      }

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
    }
  }

  @override
  void initState() {
    super.initState();
    fetchFiles(); // נטען את הקבצים ברגע שהאפליקציה עולה
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AirShare - Shared Files')),
      body: files.isEmpty
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
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: pickAndUploadFile,
        child: const Icon(Icons.add),
      ),
    );
  }
}