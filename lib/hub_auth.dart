import 'dart:io';



import 'package:cryptography/cryptography.dart';



import 'package:air_share/session_crypto.dart';

import 'package:air_share/wire_contract.dart';



enum HubAuthDecision { allow, unauthorized, registerGuest }



/// Result of evaluating an inbound hub HTTP request.

class HubAuthResult {

  const HubAuthResult._(this.decision, {this.message});



  final HubAuthDecision decision;

  final String? message;



  static const allow = HubAuthResult._(HubAuthDecision.allow);

  static const unauthorized = HubAuthResult._(

    HubAuthDecision.unauthorized,

    message: 'Missing or invalid Authorization bearer',

  );



  static HubAuthResult registerGuest(String guestPublicKeyBase64Url) =>

      HubAuthResult._(

        HubAuthDecision.registerGuest,

        message: guestPublicKeyBase64Url,

      );

}



/// One guest's ECDH-derived bearer bound to their public key (and optional IP).

class RegisteredGuestBinding {

  RegisteredGuestBinding({

    required this.guestPublicKeyBase64Url,

    required this.bearerToken,

    this.remoteAddress,

  });



  final String guestPublicKeyBase64Url;

  final String bearerToken;

  final String? remoteAddress;

}



/// Host-side session: one host key pair, many independent guest bearers.

class HostHubSession {

  HostHubSession({

    required this.hostKeyPair,

    required this.hostPublicKeyBase64Url,

  });



  final SimpleKeyPair hostKeyPair;

  final String hostPublicKeyBase64Url;



  final Map<String, RegisteredGuestBinding> _guestsByPublicKey = {};

  final Map<String, String> _guestPublicKeyByRemoteAddress = {};



  int get registeredGuestCount => _guestsByPublicKey.length;



  Iterable<RegisteredGuestBinding> get registeredGuests =>

      _guestsByPublicKey.values;



  bool isRegisteredGuest(String guestPublicKeyBase64Url) {

    final trimmed = guestPublicKeyBase64Url.trim();

    return trimmed.isNotEmpty && _guestsByPublicKey.containsKey(trimmed);

  }



  Future<void> registerGuestPublicKey(

    String guestPublicKeyBase64Url, {

    String? remoteAddress,

  }) async {

    final trimmed = guestPublicKeyBase64Url.trim();

    if (trimmed.isEmpty) return;

    final bearerToken = await SessionCrypto.deriveBearerToken(

      localKeyPair: hostKeyPair,

      remotePublicKeyBase64Url: trimmed,

    );

    _guestsByPublicKey[trimmed] = RegisteredGuestBinding(

      guestPublicKeyBase64Url: trimmed,

      bearerToken: bearerToken,

      remoteAddress: remoteAddress,

    );

    if (remoteAddress != null && remoteAddress.isNotEmpty) {

      _guestPublicKeyByRemoteAddress[remoteAddress] = trimmed;

    }

  }



  bool verifyBearer(String? token, {String? remoteAddress}) {

    if (token == null || token.isEmpty) return false;

    final remote = remoteAddress?.trim();

    if (remote != null && remote.isNotEmpty) {

      final guestPk = _guestPublicKeyByRemoteAddress[remote];

      if (guestPk != null) {

        final binding = _guestsByPublicKey[guestPk];

        if (binding != null &&

            SessionCrypto.constantTimeEquals(token, binding.bearerToken)) {

          return true;

        }

      }

    }

    for (final binding in _guestsByPublicKey.values) {

      if (SessionCrypto.constantTimeEquals(token, binding.bearerToken)) {

        return true;

      }

    }

    return false;

  }



  bool get requiresBearer => _guestsByPublicKey.isNotEmpty;

}



/// Guest-side credentials derived after BLE session release (post-Approve).

class GuestHubSession {

  GuestHubSession({

    required this.guestKeyPair,

    required this.guestPublicKeyBase64Url,

    required this.bearerToken,

  });



  final SimpleKeyPair guestKeyPair;

  final String guestPublicKeyBase64Url;

  final String bearerToken;



  static Future<GuestHubSession?> fromHostPublicKey(

    String hostPublicKeyBase64Url,

  ) async {

    final guestKeyPair = await SessionCrypto.generateKeyPair();

    return fromExistingKeyPair(

      guestKeyPair: guestKeyPair,

      hostPublicKeyBase64Url: hostPublicKeyBase64Url,

    );

  }



  /// Uses the same key pair written to BLE as [WireContract.guestPublicKeyBle].

  static Future<GuestHubSession?> fromExistingKeyPair({

    required SimpleKeyPair guestKeyPair,

    required String hostPublicKeyBase64Url,

  }) async {

    final trimmed = hostPublicKeyBase64Url.trim();

    if (trimmed.isEmpty) return null;

    final guestPublicKeyBase64Url =

        await SessionCrypto.publicKeyBase64Url(guestKeyPair);

    final bearerToken = await SessionCrypto.deriveBearerToken(

      localKeyPair: guestKeyPair,

      remotePublicKeyBase64Url: trimmed,

    );

    return GuestHubSession(

      guestKeyPair: guestKeyPair,

      guestPublicKeyBase64Url: guestPublicKeyBase64Url,

      bearerToken: bearerToken,

    );

  }

}



/// Parses and validates HTTPS Authorization + AirShare security headers.

abstract final class HubAuth {

  static String? parseBearer(HttpHeaders headers) {

    final raw = headers.value(WireContract.authorization);

    if (raw == null || raw.isEmpty) return null;

    final trimmed = raw.trim();

    final prefix = '${WireContract.bearerScheme} ';

    if (!trimmed.toLowerCase().startsWith(prefix.toLowerCase())) return null;

    return trimmed.substring(prefix.length).trim();

  }



  static String authorizationHeaderValue(String bearerToken) =>

      '${WireContract.bearerScheme} $bearerToken';



  static Map<String, String> guestSecurityHeaders(GuestHubSession session) => {

        WireContract.authorization: authorizationHeaderValue(session.bearerToken),

        WireContract.guestPublicKey: session.guestPublicKeyBase64Url,

      };



  static HubAuthResult evaluate({

    required HttpRequest request,

    required HostHubSession? hostSession,

  }) {

    final role =

        (request.headers.value(WireContract.requesterRole) ?? 'guest')

            .toLowerCase();

    final remote = request.connectionInfo?.remoteAddress.address;

    final isLoopback = request.connectionInfo?.remoteAddress.isLoopback ?? false;

    final bearer = parseBearer(request.headers);

    final guestPk =

        request.headers.value(WireContract.guestPublicKey)?.trim();



    if (hostSession == null) {

      return HubAuthResult.unauthorized;

    }



    if (guestPk != null &&

        guestPk.isNotEmpty &&

        bearer != null &&

        bearer.isNotEmpty &&

        !hostSession.isRegisteredGuest(guestPk)) {

      return HubAuthResult.registerGuest(guestPk);

    }



    if (hostSession.requiresBearer) {

      if (hostSession.verifyBearer(bearer, remoteAddress: remote)) {

        return HubAuthResult.allow;

      }

      if (isLoopback && role == 'host') {

        return HubAuthResult.allow;

      }

      return HubAuthResult.unauthorized;

    }



    if (isLoopback && role == 'host') {

      return HubAuthResult.allow;

    }



    return HubAuthResult.unauthorized;

  }

}

