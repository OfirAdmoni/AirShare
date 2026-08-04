import 'dart:convert';
import 'dart:io';

/// Syncs BLE pre-approval to the standalone Go engine when it is serving HTTPS
/// on localhost (Dart hub not running on the same process).
class HubGoPreApprovalSync {
  HubGoPreApprovalSync._();

  static Future<void> notify({
    required int port,
    String? peerId,
    String? displayName,
  }) async {
    try {
      final client = HttpClient();
      client.badCertificateCallback = (_, __, ___) => true;
      final request = await client.postUrl(
        Uri.parse('https://127.0.0.1:$port/host/pre-approve'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          if (displayName != null && displayName.trim().isNotEmpty)
            'guestName': displayName.trim(),
          if (peerId != null && peerId.trim().isNotEmpty)
            'guestPeerId': peerId.trim(),
        }),
      );
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
    } catch (_) {
      // Go engine may not be running — Dart hub handles pre-approval in-process.
    }
  }
}
