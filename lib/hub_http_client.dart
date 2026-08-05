import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'hub_auth.dart';
import 'hub_guest_session.dart';

/// HTTP(S) client that trusts the hub self-signed cert (pin) and sends auth tokens.
class HubHttpClient {
  HubHttpClient._();

  static http.Client create({
    String? tlsCertSha256Pin,
    String? authToken,
  }) {
    if (kIsWeb) {
      return http.Client();
    }

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    final pin = tlsCertSha256Pin
        ?.replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim()
        .toLowerCase();
    if (pin != null && pin.isNotEmpty) {
      httpClient.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
        final der = cert.der;
        final hash = sha256
            .convert(der)
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        return hash == pin;
      };
    } else {
      // Local hub self-signed — allow when no pin yet (host loopback bootstrap).
      httpClient.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }

    return _AuthHttpClient(IOClient(httpClient), staticAuthToken: authToken);
  }

  static Map<String, String> authHeaders({String? authToken}) {
    final token = authToken
        ?.replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim();
    if (token == null || token.isEmpty) return {};
    return {HubAuth.headerName: token};
  }
}

class _AuthHttpClient extends http.BaseClient {
  _AuthHttpClient(this._inner, {this.staticAuthToken});

  final http.Client _inner;
  final String? staticAuthToken;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final token = (staticAuthToken ?? HubGuestSession.instance.authToken)
        ?.replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim();
    if (token != null && token.isNotEmpty) {
      request.headers.putIfAbsent(HubAuth.headerName, () => token);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
