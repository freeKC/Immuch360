// What the user pastes in the token field of a Plex server: the token alone, or the whole address of the "View XML" tab
// of Plex Web, which also tells the server. A token gives full access to the server: it is never logged, and the
// toString of these classes leaves it out.

import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';

/// The forms of Plex tokens: the long lived one of the account or of a device (about 20 characters), and the JSON Web
/// Token of the newer sign in, which lasts days and is renewed through plex.tv, which this app never calls
enum PlexTokenKind { legacy, jwt, unknown }

/// What the user pasted, see [parsePastedPlexToken]
class PastedPlexToken {
  const PastedPlexToken({required this.token, this.server, required this.kind, this.expires});

  final String token;

  /// The server of the pasted address (scheme, host and port), when it was a plex.direct name or an IPv4 address; null
  /// for a token alone, and for an address of another kind (app.plex.tv), which tells nothing of the server
  final Uri? server;
  final PlexTokenKind kind;

  /// The "exp" claim of a JSON Web Token. Not checked further: the app has no key to check it with, the server does.
  final DateTime? expires;

  bool isExpired([DateTime? now]) {
    final expires = this.expires;
    return expires != null && !expires.isAfter(now ?? DateTime.now());
  }

  @override
  String toString() =>
      'PastedPlexToken(${kind.name}${server == null ? '' : ', with a server'}'
      '${expires == null ? '' : ', until ${expires!.toIso8601String()}'})';
}

final _whitespace = RegExp(r'\s+');
final _tokenParameter = RegExp(r'[?&#]X-Plex-Token=([^&#]*)', caseSensitive: false);

// The usual tokens are 20 characters; a margin both ways for the other generations
final _legacyPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
final _base64UrlPart = RegExp(r'^[A-Za-z0-9_-]+$');

/// Reads what was pasted: spaces and line breaks dropped, the X-Plex-Token parameter of an address taken (in its
/// query or its fragment). Null when nothing that could be a token is left. A text of no known form still gives a
/// token of kind unknown: the server decides.
PastedPlexToken? parsePastedPlexToken(String text) {
  final compact = text.replaceAll(_whitespace, '');
  if (compact.isEmpty) {
    return null;
  }
  var token = compact;
  Uri? server;
  final parameter = _tokenParameter.firstMatch(compact);
  if (parameter != null) {
    try {
      token = Uri.decodeQueryComponent(parameter.group(1)!);
    } on ArgumentError {
      token = parameter.group(1)!;
    }
    server = _serverOf(compact);
  } else if (compact.contains('://')) {
    // An address without a token
    return null;
  }
  if (token.isEmpty) {
    return null;
  }
  if (_legacyPattern.hasMatch(token)) {
    return PastedPlexToken(token: token, server: server, kind: PlexTokenKind.legacy);
  }
  final jwt = _jwtExpiry(token);
  if (jwt != null) {
    return PastedPlexToken(token: token, server: server, kind: PlexTokenKind.jwt, expires: jwt.expires);
  }
  return PastedPlexToken(token: token, server: server, kind: PlexTokenKind.unknown);
}

/// The server of a pasted address: only a plex.direct name or an IPv4 address tells which server it is
Uri? _serverOf(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final isServer =
      parsePlexDirectHost(host) != null || InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4;
  return isServer ? Uri(scheme: uri.scheme, host: host, port: uri.hasPort ? uri.port : null) : null;
}

/// Null when [token] is not a JSON Web Token: three base64url parts, the first a JSON object with "alg". The expiry is
/// null when the second part has no "exp".
({DateTime? expires})? _jwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length != 3 || !parts.every((part) => _base64UrlPart.hasMatch(part))) {
    return null;
  }
  final header = _decodePart(parts[0]);
  if (header is! Map || header['alg'] is! String) {
    return null;
  }
  final payload = _decodePart(parts[1]);
  final exp = payload is Map ? payload['exp'] : null;
  if (exp is! num) {
    return (expires: null);
  }
  return (expires: DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true));
}

Object? _decodePart(String part) {
  try {
    return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))));
  } on FormatException {
    return null;
  }
}
