import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'shared_file_entry.dart';

/// Persists per-file metadata in the shared directory (`.airshare_manifest.json`).
class SharedRoomManifest {
  SharedRoomManifest({
    this.roomHostPeerId = '',
    this.roomHostName = '',
    Map<String, SharedFileEntry>? files,
  }) : files = files ?? {};

  static const String manifestFileName = '.airshare_manifest.json';

  String roomHostPeerId;
  String roomHostName;
  final Map<String, SharedFileEntry> files;

  static Future<SharedRoomManifest> load(String sharedDirPath) async {
    final file = File(_manifestPath(sharedDirPath));
    if (!await file.exists()) {
      return SharedRoomManifest();
    }
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return SharedRoomManifest();
      final filesMap = <String, SharedFileEntry>{};
      final filesRaw = raw['files'];
      if (filesRaw is Map) {
        for (final entry in filesRaw.entries) {
          final name = entry.key.toString();
          if (entry.value is! Map) continue;
          final meta = Map<String, dynamic>.from(entry.value as Map);
          meta['name'] = name;
          filesMap[name] = SharedFileEntry.fromJson(meta);
        }
      }
      return SharedRoomManifest(
        roomHostPeerId: (raw['roomHostPeerId'] ?? '').toString(),
        roomHostName: (raw['roomHostName'] ?? '').toString(),
        files: filesMap,
      );
    } catch (_) {
      return SharedRoomManifest();
    }
  }

  Future<void> save(String sharedDirPath) async {
    final file = File(_manifestPath(sharedDirPath));
    final payload = {
      'roomHostPeerId': roomHostPeerId,
      'roomHostName': roomHostName,
      'files': {
        for (final e in files.entries) e.key: e.value.toJson()..remove('name'),
      },
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
  }

  void setRoomHost({required String peerId, required String displayName}) {
    roomHostPeerId = peerId;
    roomHostName = displayName;
  }

  void upsertFile(SharedFileEntry entry) {
    files[entry.name] = entry;
  }

  void removeFile(String name) {
    files.remove(name);
  }

  SharedFileEntry? entryFor(String name) => files[name];

  static String _manifestPath(String sharedDirPath) {
    return p.join(sharedDirPath, manifestFileName);
  }

  static bool isManifestFileName(String name) =>
      name == manifestFileName || name.endsWith(manifestFileName);
}
