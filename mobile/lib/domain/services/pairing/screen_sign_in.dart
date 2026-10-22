// What a big screen does with what arrives sealed on its pairing listener: the session a phone made for it, or the
// server, email and password of the browser page. It applies the phone's custom headers, tries the server addresses
// in order within a time the phone waits for (only a ping, which changes nothing), makes the first that answers the
// app's server, checks the token with the server, and answers how it went. A failed attempt leaves the screen as it
// was: its headers, its name, its server address, no token.
//
// Nothing here goes to the logs but the outcome: never the token, the password, a header value or an address.

import 'dart:async';

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';
import 'package:logging/logging.dart';

final _log = Logger('ScreenSignIn');

/// How a sign in with an email and a password went
enum PasswordSignInOutcome { signedIn, wrongCredentials, failed }

/// What the screen had before an attempt, put back when it fails
class ScreenSignInSnapshot {
  const ScreenSignInSnapshot({required this.headers, required this.label, this.serverUrl, this.serverEndpoint});
  final Map<String, String> headers;
  final String? label;

  /// StoreKey.serverUrl and StoreKey.serverEndpoint: the login form fills its address from them
  final String? serverUrl;
  final String? serverEndpoint;
}

/// The app's side of a sign in, replaced by a fake in the tests
abstract interface class ScreenSignInActions {
  Future<ScreenSignInSnapshot> snapshot();

  /// Puts [snapshot] back (the server address too) and forgets any token the attempt saved
  Future<void> restore(ScreenSignInSnapshot snapshot);
  Future<void> setCustomHeaders(Map<String, String> headers);

  /// The name of this screen in its device headers (StoreKey.pairingScreenLabel)
  Future<void> setLabel(String label);

  /// The API address of [endpoint] when it answers as an Immich server within [timeout], else null. Changes nothing:
  /// an address that answers after its time cannot become the server under the next one.
  Future<String?> tryServer(String endpoint, Duration timeout);

  /// Makes [apiUrl], an address [tryServer] gave, the app's server
  Future<void> useServer(String apiUrl);

  /// Saves [token] and checks it with the server (/users/me): false when the server refused it
  Future<bool> useToken(String token);

  /// Whether the server takes passwords, and the name of its OAuth button when it has OAuth
  Future<({bool passwordLogin, String? oauthProvider})> loginOptions();
  Future<PasswordSignInOutcome> login(String email, String password);

  /// The phone that signed the screen in, for the account dialog; null for the browser page
  Future<void> setSignedInBy(String? phone);

  /// The name of the account signed in now
  String? userName();
}

/// Who signed the screen in, for its toast
class ScreenSignedIn {
  const ScreenSignedIn({required this.user, this.phone});
  final String user;
  final String? phone;
}

/// See the top of this file
class ScreenSignIn implements PairingSignIn {
  ScreenSignIn(
    this._actions, {
    this.perServer = const Duration(seconds: 6),
    this.budget = const Duration(seconds: 12),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ScreenSignInActions _actions;

  /// How long one address may take to answer
  final Duration perServer;

  /// How long all of them may take: with the check of the token (up to 7 s) and the settings, well within the 35 s
  /// after which the phone gives up and deletes the session
  final Duration budget;
  final DateTime Function() _clock;

  static const maxEndpoints = 6;
  static const maxHeaders = 32;

  /// Who signed the screen in last, once it did
  ScreenSignedIn? signedIn;

  @override
  Future<PairingSignInResult> withSession(Map<String, Object?> payload) async {
    final token = payload['token'];
    final server = _url(payload['server']);
    final given = payload['endpoints'];
    final endpoints = <String>[
      if (given is List)
        for (final endpoint in given) ?_url(endpoint),
    ];
    if (endpoints.isEmpty && server != null) {
      endpoints.add(server);
    }
    if (token is! String || token.length < 8 || token.length > 2048 || endpoints.isEmpty) {
      _log.info('Pairing: the session of the phone is not complete');
      return const PairingSignInResult(answer: {'status': 'invalid'}, signedIn: false);
    }
    final headers = _headers(payload['headers']);
    final givenLabel = payload['label'];
    final label = givenLabel is String ? cleanPairingLabel(givenLabel) : null;
    final phone = _text(payload['phone']);

    final snapshot = await _actions.snapshot();
    try {
      if (headers.isNotEmpty) {
        await _actions.setCustomHeaders(headers);
      }
      if (label != null) {
        await _actions.setLabel(label);
      }
      final tried = await _reach(endpoints.take(maxEndpoints).toList());
      final reached = tried.reached;
      if (reached == null) {
        await _actions.restore(snapshot);
        _log.info('Pairing: no address of the server answered (${tried.count} tried)');
        return PairingSignInResult(
          answer: {'status': 'serverUnreachable', 'tried': tried.count},
          signedIn: false,
          notice: ScreenPairingNotice.serverUnreachable,
          detail: _hostOf(server ?? endpoints.first),
        );
      }
      await _actions.useServer(reached);
      if (!await _actions.useToken(token)) {
        await _actions.restore(snapshot);
        _log.info('Pairing: the server refused the session of the phone');
        return const PairingSignInResult(answer: {'status': 'tokenRejected'}, signedIn: false);
      }
      await _actions.setSignedInBy(phone);
    } catch (error) {
      _log.warning('Pairing: the sign in with the session of the phone failed: ${error.runtimeType}');
      await _actions.restore(snapshot).catchError((Object _) {});
      return const PairingSignInResult(answer: {'status': 'failed'}, signedIn: false);
    }
    final user = _actions.userName() ?? _text((payload['user'] as Map?)?['name']) ?? '';
    signedIn = ScreenSignedIn(user: user, phone: phone);
    _log.info('Pairing: signed in with the session of a phone');
    return PairingSignInResult(answer: {'status': 'signedIn', 'label': ?label}, signedIn: true);
  }

  @override
  Future<PairingSignInResult> withPassword(Map<String, Object?> credentials) async {
    final server = _url(credentials['server']);
    final email = credentials['email'];
    final password = credentials['password'];
    if (server == null || email is! String || password is! String || email.length > 320 || password.length > 1024) {
      return const PairingSignInResult(answer: {'status': 'invalid'}, signedIn: false, retry: true);
    }
    final snapshot = await _actions.snapshot();
    try {
      final tried = await _reach([server]);
      final reached = tried.reached;
      // A typo in the address: the page may correct it with the same code, as for a wrong password
      if (reached == null) {
        await _actions.restore(snapshot);
        return PairingSignInResult(
          answer: const {'status': 'serverUnreachable', 'tried': 1},
          signedIn: false,
          retry: true,
          notice: ScreenPairingNotice.serverUnreachable,
          detail: _hostOf(server),
        );
      }
      await _actions.useServer(reached);
      final options = await _actions.loginOptions();
      if (!options.passwordLogin) {
        await _actions.restore(snapshot);
        return PairingSignInResult(
          answer: {'status': 'oauthOnly', 'provider': options.oauthProvider ?? 'OAuth'},
          signedIn: false,
          retry: true,
        );
      }
      switch (await _actions.login(email.trim(), password)) {
        case PasswordSignInOutcome.wrongCredentials:
          _log.info('Pairing: the browser page gave a wrong email or password');
          await _actions.restore(snapshot);
          return const PairingSignInResult(answer: {'status': 'badCredentials'}, signedIn: false, retry: true);
        case PasswordSignInOutcome.failed:
          await _actions.restore(snapshot);
          return const PairingSignInResult(answer: {'status': 'failed'}, signedIn: false);
        case PasswordSignInOutcome.signedIn:
          await _actions.setSignedInBy(null);
      }
    } catch (error) {
      _log.warning('Pairing: the sign in of the browser page failed: ${error.runtimeType}');
      await _actions.restore(snapshot).catchError((Object _) {});
      return const PairingSignInResult(answer: {'status': 'failed'}, signedIn: false);
    }
    signedIn = ScreenSignedIn(user: _actions.userName() ?? '');
    _log.info('Pairing: signed in from the browser page');
    return const PairingSignInResult(answer: {'status': 'signedIn'}, signedIn: true);
  }

  /// The API address of the first of [endpoints] that answers, within [perServer] each and [budget] in all
  Future<({String? reached, int count})> _reach(List<String> endpoints) async {
    final start = _clock();
    var count = 0;
    for (final endpoint in endpoints) {
      final left = budget - _clock().difference(start);
      if (left <= Duration.zero) {
        break;
      }
      count++;
      final timeout = left < perServer ? left : perServer;
      final reached = await _actions.tryServer(endpoint, timeout).timeout(timeout, onTimeout: () => null);
      if (reached != null) {
        return (reached: reached, count: count);
      }
    }
    return (reached: null, count: count);
  }

  static String? _url(Object? value) {
    if (value is! String || value.length > 512) {
      return null;
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return null;
    }
    return value.trim();
  }

  static String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;

  static String? _text(Object? value) {
    if (value is! String) {
      return null;
    }
    final text = cleanPairingText(value);
    if (text.isEmpty) {
      return null;
    }
    return text.length > 64 ? text.substring(0, 64) : text;
  }

  /// The custom headers a phone sent, as an HTTP stack takes them: names of token characters, values on one line
  static Map<String, String> _headers(Object? value) {
    if (value is! Map) {
      return const {};
    }
    final headers = <String, String>{};
    for (final MapEntry(:key, value: headerValue) in value.entries) {
      if (headers.length >= maxHeaders) {
        break;
      }
      if (key is String &&
          headerValue is String &&
          RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$").hasMatch(key) &&
          headerValue.length <= 4096 &&
          !headerValue.contains(RegExp(r'[\r\n]'))) {
        headers[key] = headerValue;
      }
    }
    return headers;
  }
}
