import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ConnectionLogger {
  ConnectionLogger._();

  static final ConnectionLogger instance = ConnectionLogger._();

  final ValueNotifier<List<String>> entries = ValueNotifier<List<String>>(<String>[]);
  File? _logFile;
  Future<void> _writeChain = Future<void>.value();

  Future<File> _resolveLogFile() async {
    if (_logFile != null) return _logFile!;
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}${Platform.pathSeparator}connection_audit_log.txt');
    if (!await _logFile!.exists()) {
      await _logFile!.create(recursive: true);
    }
    return _logFile!;
  }

  Future<void> initialize() async {
    final file = await _resolveLogFile();
    final lines = await file.readAsLines();
    entries.value = List<String>.from(lines);
  }

  Future<void> log(String event, {String? details}) async {
    final stamp = DateTime.now().toIso8601String();
    final line = details == null || details.isEmpty
        ? '[$stamp] $event'
        : '[$stamp] $event | $details';

    entries.value = List<String>.from(entries.value)..add(line);
    _writeChain = _writeChain.then((_) async {
      final file = await _resolveLogFile();
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    });
    await _writeChain;
  }
}

