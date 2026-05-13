import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'connection_logger.dart';

/// Structured logs for guest-side BLE + TCP handshake phases.
///
/// Phases map to debugging language from the product side:
/// - **ClientHello**: native BLE connect + service discovery + handshake read start
/// - **ServerHello**: handshake JSON received (logged separately after decode)
/// - **Auth**: endpoint characteristic read (`ip:port` for HTTP)
/// - **TCP verify**: TCP probe to hub HTTP port
class HandshakeTrace {
  HandshakeTrace._();

  static Future<T> run<T>(
    String phase,
    Future<T> Function() action, {
    String? extra,
    Duration? hardTimeout,
  }) async {
    final sw = Stopwatch()..start();
    final detail = (extra == null || extra.isEmpty) ? null : extra;
    await ConnectionLogger.instance.log('HS | $phase | START', details: detail);
    debugPrint('[HS] START $phase ${detail ?? ''}');
    try {
      var fut = action();
      if (hardTimeout != null) {
        fut = fut.timeout(
          hardTimeout,
          onTimeout: () => throw TimeoutException(
            'HS | $phase exceeded $hardTimeout',
            hardTimeout,
          ),
        );
      }
      final out = await fut;
      sw.stop();
      await ConnectionLogger.instance.log(
        'HS | $phase | OK',
        details: 'elapsed_ms=${sw.elapsedMilliseconds}',
      );
      debugPrint('[HS] OK $phase ${sw.elapsedMilliseconds}ms');
      return out;
    } on TimeoutException catch (e) {
      sw.stop();
      await ConnectionLogger.instance.log(
        'HS | $phase | TIMEOUT',
        details: 'elapsed_ms=${sw.elapsedMilliseconds} err=$e',
      );
      debugPrint('[HS] TIMEOUT $phase ${sw.elapsedMilliseconds}ms $e');
      rethrow;
    } on PlatformException catch (e) {
      sw.stop();
      await ConnectionLogger.instance.log(
        'HS | $phase | PLATFORM',
        details:
            'elapsed_ms=${sw.elapsedMilliseconds} code=${e.code} msg=${e.message} details=${e.details}',
      );
      debugPrint('[HS] PLATFORM $phase code=${e.code} msg=${e.message}');
      rethrow;
    } catch (e, st) {
      sw.stop();
      await ConnectionLogger.instance.log(
        'HS | $phase | ERROR',
        details: 'elapsed_ms=${sw.elapsedMilliseconds} err=$e',
      );
      debugPrint('[HS] ERROR $phase $e\n$st');
      rethrow;
    }
  }
}
