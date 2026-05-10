import 'package:flutter/widgets.dart';

/// Active session allowing access to file list / transfer UI (after BLE+WLAN link or local hub ready).
class FileZoneSession {
  const FileZoneSession({
    required this.hubHost,
    required this.hubPort,
    this.isLocalHub = false,
  });

  final String hubHost;
  final int hubPort;
  final bool isLocalHub;
}

/// Holds [ValueNotifier<FileZoneSession?>]; non-null means file zones are allowed.
class FileZoneSessionScope extends InheritedNotifier<ValueNotifier<FileZoneSession?>> {
  const FileZoneSessionScope({
    super.key,
    required ValueNotifier<FileZoneSession?> notifier,
    required super.child,
  }) : super(notifier: notifier);

  static ValueNotifier<FileZoneSession?> of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FileZoneSessionScope>();
    assert(scope != null, 'FileZoneSessionScope missing');
    return scope!.notifier!;
  }
}
