// The address of a Jellyfin or Emby server as the user types it: "192.168.1.20", "192.168.1.20:8096",
// "http://nas.local:8096", "https://media.example.org/jellyfin" (a reverse proxy with a base path).

import 'dart:io';

import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart' show isLocalNetworkAddress;

/// A typed address, read
class JellyfinAddress {
  const JellyfinAddress({required this.host, required this.port, required this.useTls, this.basePath = ''});

  final String host;
  final int port;
  final bool useTls;

  /// "" or "/jellyfin", without a slash at the end
  final String basePath;

  /// The port to store: null for the default of the scheme (8096, 8920)
  int? get storedPort => port == (useTls ? jellyfinDefaultTlsPort : jellyfinDefaultPort) ? null : port;

  Uri get base => Uri(scheme: useTls ? 'https' : 'http', host: host, port: port, path: basePath);

  /// As a browser would show it
  String get text => '$base';

  /// Whether the session would cross networks the user does not own in clear: http to an address that is not a
  /// private one (or a name that is not one of the home network)
  bool get isPlainOutsideHome {
    if (useTls) {
      return false;
    }
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      return !(address.isLoopback || isLocalNetworkAddress(address));
    }
    final name = host.toLowerCase();
    // A bare name ("nas") or a name of the home network
    return name.contains('.') && !const ['.local', '.lan', '.home', '.home.arpa', '.internal'].any(name.endsWith);
  }
}

/// [text] read as an address, null when it is not one. Without a scheme it is http on 8096 unless a port is written;
/// with a scheme and no port, the port of the scheme (80, 443): a server behind a reverse proxy.
JellyfinAddress? parseJellyfinAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(' ')) {
    return null;
  }
  final hasScheme = trimmed.contains('://');
  final Uri uri;
  try {
    uri = Uri.parse(hasScheme ? trimmed : 'http://$trimmed');
  } on FormatException {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  final useTls = scheme == 'https';
  final written = RegExp(
    r'^[a-z]+://(\[[^\]]+\]|[^/:]+):(\d+)',
    caseSensitive: false,
  ).hasMatch(hasScheme ? trimmed : 'http://$trimmed');
  final port = written ? uri.port : (hasScheme ? (useTls ? 443 : 80) : jellyfinDefaultPort);
  if (port <= 0 || port > 65535) {
    return null;
  }
  var path = uri.path;
  // The web page of the server, often pasted from the browser, is not its base path
  for (final page in ['/web/index.html', '/web/', '/web']) {
    if (path.toLowerCase().endsWith(page)) {
      path = path.substring(0, path.length - page.length);
      break;
    }
  }
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return JellyfinAddress(host: uri.host, port: port, useTls: useTls, basePath: path);
}
