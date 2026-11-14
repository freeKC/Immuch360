// The addresses of the cameras of other brands than Tapo (ONVIF or a typed RTSP address): what the user pastes, what
// is stored, what each platform plays and what a log may show.
//
// A stream address is a secret as a whole, not only its user info: a UniFi Protect link carries its access token in
// the path (rtsps://nvr:7441/<token>), some cheap cameras put the account in the path itself
// (/user=admin_password=..._channel=1), others in the query. So the path and query of every stream and snapshot
// address live in the secure storage with the password (see IpCameraStreams), the source keeps the host and the port,
// and every text meant for a log or the screen goes through [maskCameraUrl], which keeps the scheme, host and port.

import 'dart:convert';

/// The RTSP port of a camera when the address has none
const rtspDefaultPort = 554;

/// The RTSPS port of a camera when the address has none (RFC 7826)
const rtspsDefaultPort = 322;

/// The ports of a UniFi Protect console: RTSPS and the plain RTSP of the same stream, same token
const unifiRtspsPort = 7441;
const unifiRtspPort = 7447;

/// What a pasted RTSP or RTSPS address is made of; the account taken out of it
class CameraStreamAddress {
  const CameraStreamAddress({
    required this.secure,
    required this.host,
    required this.port,
    required this.pathAndQuery,
    this.user,
    this.password,
  });

  /// rtsps://
  final bool secure;

  /// Without the brackets of an IPv6 address
  final String host;
  final int port;

  /// "/" at least; the query with it ("/cam/realmonitor?channel=1&subtype=0")
  final String pathAndQuery;

  /// The account found in the user info of the pasted address, decoded; null when it had none
  final String? user;
  final String? password;

  String get scheme => secure ? 'rtsps' : 'rtsp';

  /// The address without any account, as the players get it (they get the account apart)
  String get url => cameraStreamUrl(secure: secure, host: host, port: port, pathAndQuery: pathAndQuery);

  @override
  String toString() => 'CameraStreamAddress(${maskCameraUrl(url)})';
}

/// `rtsp://host:port/path?query`, an IPv6 host in brackets
String cameraStreamUrl({required bool secure, required String host, required int port, required String pathAndQuery}) {
  final path = pathAndQuery.startsWith('/') ? pathAndQuery : '/$pathAndQuery';
  return '${secure ? 'rtsps' : 'rtsp'}://${host.contains(':') ? '[$host]' : host}:$port$path';
}

/// Reads a pasted address: `rtsp://` or `rtsps://`, an account in the user info taken out (percent-decoded), the
/// default port of the scheme when none. Null for anything else (http, a bare host, an address without a host).
CameraStreamAddress? parseCameraStreamAddress(String text) {
  final trimmed = text.trim();
  final lower = trimmed.toLowerCase();
  final bool secure;
  if (lower.startsWith('rtsp://')) {
    secure = false;
  } else if (lower.startsWith('rtsps://')) {
    secure = true;
  } else {
    return null;
  }
  final rest = trimmed.substring(secure ? 8 : 7);
  final slash = rest.indexOf('/');
  final question = rest.indexOf('?');
  final end = [slash, question].where((index) => index >= 0).fold(rest.length, (a, b) => a < b ? a : b);
  var authority = rest.substring(0, end);
  var pathAndQuery = rest.substring(end);
  if (pathAndQuery.isEmpty || pathAndQuery.startsWith('?')) {
    pathAndQuery = '/$pathAndQuery';
  }
  String? user;
  String? password;
  // The last @ ends the user info: a password may hold one, percent-encoded or not
  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    final userInfo = authority.substring(0, at);
    authority = authority.substring(at + 1);
    final colon = userInfo.indexOf(':');
    user = _decode(colon < 0 ? userInfo : userInfo.substring(0, colon));
    password = colon < 0 ? null : _decode(userInfo.substring(colon + 1));
  }
  String host;
  int? port;
  if (authority.startsWith('[')) {
    final close = authority.indexOf(']');
    if (close < 0) {
      return null;
    }
    host = authority.substring(1, close);
    final after = authority.substring(close + 1);
    if (after.startsWith(':')) {
      port = int.tryParse(after.substring(1));
      if (port == null) {
        return null;
      }
    } else if (after.isNotEmpty) {
      return null;
    }
  } else {
    final colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      port = int.tryParse(authority.substring(colon + 1));
      if (port == null) {
        return null;
      }
      host = authority.substring(0, colon);
    } else {
      host = authority;
    }
  }
  if (host.isEmpty || host.contains(RegExp(r'[\s/@]')) || (port != null && (port <= 0 || port > 65535))) {
    return null;
  }
  return CameraStreamAddress(
    secure: secure,
    host: host,
    port: port ?? (secure ? rtspsDefaultPort : rtspDefaultPort),
    pathAndQuery: pathAndQuery,
    user: user == null || user.isEmpty ? null : user,
    password: password == null || password.isEmpty ? null : password,
  );
}

String _decode(String text) {
  try {
    return Uri.decodeComponent(text);
  } on ArgumentError {
    return text;
  }
}

/// [url] for a log or the screen: the scheme, the host and the port, the user info and the path and query replaced
/// by "…" (they may hold an account or a token, see the top of this file). Anything that is not an address with a
/// scheme is masked whole.
String maskCameraUrl(String url) {
  final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*)(.*)$').firstMatch(url.trim());
  if (match == null) {
    return '…';
  }
  var authority = match.group(2)!;
  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    authority = '…@${authority.substring(at + 1)}';
  }
  final rest = match.group(3)!;
  return '${match.group(1)!.toLowerCase()}://$authority${rest.isEmpty || rest == '/' ? rest : '/…'}';
}

/// Every address inside [text] masked as [maskCameraUrl] does: for a message of a player or a library that quotes
/// the address it was given
String maskCameraUrlsIn(String text) =>
    text.replaceAllMapped(RegExp(r'''\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+'''), (match) => maskCameraUrl(match[0]!));

/// What a phone, a TV or the Quest plays for a stream: Media3 and the Dart client have no RTSPS, so a UniFi Protect
/// link (rtsps on 7441) plays on the console's plain RTSP port 7447 with the same token, without the SRTP request of
/// its query; null for another RTSPS address, which plays on a computer only (libmpv's FFmpeg has TLS).
CameraStreamAddress? phonePlayableAddress(CameraStreamAddress address) {
  if (!address.secure) {
    return address;
  }
  if (address.port != unifiRtspsPort) {
    return null;
  }
  return CameraStreamAddress(
    secure: false,
    host: address.host,
    port: unifiRtspPort,
    pathAndQuery: _withoutQueryParameter(address.pathAndQuery, 'enableSrtp'),
    user: address.user,
    password: address.password,
  );
}

String _withoutQueryParameter(String pathAndQuery, String name) {
  final question = pathAndQuery.indexOf('?');
  if (question < 0) {
    return pathAndQuery;
  }
  final kept = pathAndQuery
      .substring(question + 1)
      .split('&')
      .where((pair) => pair.isNotEmpty && pair.split('=').first.toLowerCase() != name.toLowerCase())
      .toList();
  final path = pathAndQuery.substring(0, question);
  return kept.isEmpty ? path : '$path?${kept.join('&')}';
}

/// The stream addresses of a camera, kept in the secure storage under the cameraSecretKey of its source (see the top
/// of this file): the path and query of its main stream (HD) and sub stream (SD), and its snapshot address, without
/// any account
class IpCameraStreams {
  const IpCameraStreams({required this.main, this.sub, this.snapshot});

  /// "/Streaming/Channels/101": the path and query of the main stream on the host and RTSP port of the source
  final String main;

  /// The sub stream, null when the camera has one stream only
  final String? sub;

  /// The whole snapshot address the camera gave (http or https), without an account; null without one
  final String? snapshot;

  /// The path of the stream to play: the sub stream on a phone when there is one
  String pathFor({required bool hd}) => hd ? main : (sub ?? main);

  String encode() => jsonEncode({'v': 1, 'main': main, 'sub': ?sub, 'snapshot': ?snapshot});

  /// Null for anything this build cannot read
  static IpCameraStreams? decode(String? text) {
    if (text == null || text.isEmpty) {
      return null;
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['main'] is! String || (json['main'] as String).isEmpty) {
        return null;
      }
      final sub = json['sub'];
      final snapshot = json['snapshot'];
      return IpCameraStreams(
        main: json['main'] as String,
        sub: sub is String && sub.isNotEmpty ? sub : null,
        snapshot: snapshot is String && snapshot.isNotEmpty ? snapshot : null,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is IpCameraStreams && other.main == main && other.sub == sub && other.snapshot == snapshot;

  @override
  int get hashCode => Object.hash(main, sub, snapshot);

  // The paths may hold a token: never in a log
  @override
  String toString() => 'IpCameraStreams(${sub == null ? 'one stream' : 'two streams'})';
}
