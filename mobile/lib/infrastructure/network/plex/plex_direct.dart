// The trust of a Plex Media Server is the plex.direct name of its certificate, not DNS. A claimed server with secure
// connections holds a certificate for *.<hash>.plex.direct from a public authority, and answers to the names
// "<a>-<b>-<c>-<d>.<hash>.plex.direct" of its IPv4 addresses. The app connects to the address written in the name
// itself (many routers drop the DNS answers that point to a private address, and the names depend on the DNS of Plex),
// lets TLS check the chain against the system roots and the name, then checks that the certificate is the one of the
// stored hash before a single HTTP byte leaves: the token only ever goes to the server that holds that certificate.
// Nothing is ever sent in clear, although the server accepts it, and no certificate the system refuses is accepted.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart' show isLocalNetworkAddress;

/// The port of a Plex Media Server that does not say another one
const plexDefaultPort = 32400;

/// Longest wait for a TCP connection to an address of the local network: on another network it does not answer at
/// all, and the address outside home is tried meanwhile
const plexLocalConnectTimeout = Duration(milliseconds: 2500);

/// Longest wait for a TCP connection to an address outside home, and for a TLS handshake
const plexPublicConnectTimeout = Duration(seconds: 15);
const plexHandshakeTimeout = Duration(seconds: 15);

final _hashPattern = RegExp(r'^[0-9a-f]{32}$');
final _hostPattern = RegExp(r'^(\d{1,3})-(\d{1,3})-(\d{1,3})-(\d{1,3})\.([0-9a-f]{32})\.plex\.direct$');

// dart:io prints the subject in the OpenSSL one line form ("/CN=*.<hash>.plex.direct") on Android and Linux; the
// comma form ("CN=..., O=...") is accepted too, CN being a whole attribute in both
final _subjectPattern = RegExp(r'(?:^|[/,\s])CN=\*\.([0-9a-f]{32})\.plex\.direct(?:$|[,/\s])');

/// Whether [text] is the 32 lower case hex digits of a plex.direct certificate
bool isPlexHash(String text) => _hashPattern.hasMatch(text);

/// `192-168-1-20.<hash>.plex.direct` for 192.168.1.20
String plexDirectHost(InternetAddress address, String hash) {
  if (address.type != InternetAddressType.IPv4) {
    throw ArgumentError.value(address.address, 'address', 'Not an IPv4 address');
  }
  if (!isPlexHash(hash)) {
    throw ArgumentError.value(hash, 'hash', 'Not the hash of a plex.direct certificate');
  }
  return '${address.address.replaceAll('.', '-')}.$hash.plex.direct';
}

/// `https://<ipv4-dashes>.<hash>.plex.direct:<port>`, the base of every request to a Plex server at [address]
Uri plexDirectUri(InternetAddress address, int port, String hash) =>
    Uri(scheme: 'https', host: plexDirectHost(address, hash), port: port);

/// The address and the hash a plex.direct host name holds, null for any other name, an octet out of range or written
/// with a leading zero, and a hash that is not lower case
({InternetAddress address, String hash})? parsePlexDirectHost(String host) {
  final match = _hostPattern.firstMatch(host);
  if (match == null) {
    return null;
  }
  final octets = <int>[];
  for (var i = 1; i <= 4; i++) {
    final text = match.group(i)!;
    final octet = int.parse(text);
    if (octet > 255 || (text.length > 1 && text.startsWith('0'))) {
      return null;
    }
    octets.add(octet);
  }
  return (address: InternetAddress(octets.join('.'), type: InternetAddressType.IPv4), hash: match.group(5)!);
}

/// The hash of a certificate [subject] (`/CN=*.<hash>.plex.direct`), null when the subject is not a plex.direct
/// wildcard
String? plexHashOfSubject(String subject) => _subjectPattern.firstMatch(subject)?.group(1);

/// An HttpClient that only ever talks to `https://<ipv4-dashes>.<hash>.plex.direct:<port>` for this [hash]: it connects
/// to the address written in the name (no DNS, no proxy), lets TLS validate the certificate against the name, and
/// checks its subject before the request is written. Any other address fails before a connection is made. Redirects
/// are the caller's to refuse (http.Request.followRedirects false). [context] replaces the system roots in the tests.
HttpClient pinnedPlexHttpClient(String hash, {SecurityContext? context}) {
  if (!isPlexHash(hash)) {
    throw ArgumentError.value(hash, 'hash', 'Not the hash of a plex.direct certificate');
  }
  return HttpClient(context: context)
    // Over the TCP connection and the TLS handshake, which have shorter limits of their own (see _connectPinned)
    ..connectionTimeout = plexPublicConnectTimeout + plexHandshakeTimeout
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 6
    ..findProxy = ((_) => 'DIRECT')
    ..badCertificateCallback = ((_, _, _) => false)
    ..connectionFactory = (uri, _, _) async {
      final target = parsePlexDirectHost(uri.host);
      if (!uri.isScheme('https') || target == null || target.hash != hash) {
        throw const HandshakeException('Not an address of this Plex server');
      }
      final socket = _connectPinned(target.address, uri.port, uri.host, hash, context);
      return ConnectionTask.fromSocket(socket, () => socket.then((s) => s.destroy(), onError: (_) {}));
    };
}

/// A plain client for the fake servers of the tests, on loopback over http (PlexFileSystem.open with its address
/// overrides): the only Plex client that is not [pinnedPlexHttpClient], kept here so that every client the Plex code
/// makes is in this file
HttpClient unpinnedPlexHttpClientForTests() => HttpClient()..connectionTimeout = const Duration(seconds: 5);

/// A TLS connection to [address]:[port] whose certificate is valid for [name] and is the one of [hash]
Future<SecureSocket> _connectPinned(
  InternetAddress address,
  int port,
  String name,
  String hash,
  SecurityContext? context,
) async {
  final raw = await Socket.connect(
    address,
    port,
    timeout: isLocalNetworkAddress(address) ? plexLocalConnectTimeout : plexPublicConnectTimeout,
  );
  final SecureSocket secure;
  try {
    secure = await SecureSocket.secure(
      raw,
      host: name,
      context: context,
      onBadCertificate: (_) => false,
    ).timeout(plexHandshakeTimeout);
  } catch (_) {
    raw.destroy();
    rethrow;
  }
  // TLS checked the name; the subject must also be the wildcard of the hash, as Plex issues it, so that a certificate
  // naming this one address only is not enough
  if (plexHashOfSubject(secure.peerCertificate?.subject ?? '') != hash) {
    secure.destroy();
    throw const HandshakeException('The certificate is not the one of this Plex server');
  }
  return secure;
}

/// The plex.direct hash of the server at [address]:[port], read from its certificate during a TLS handshake that the
/// app refuses once the certificate is seen, so that nothing is sent; null when the certificate is not a plex.direct
/// one (a server not claimed, secure connections off, another kind of server). Throws a [SocketException] or a
/// [TimeoutException] when nothing answers. This is trust on first use for an address typed without its hash: the user
/// confirms the server by its name, version and id before the token is given, and every later connection is checked
/// against the hash.
Future<String?> probePlexHash(
  InternetAddress address,
  int port, {
  Duration timeout = const Duration(seconds: 8),
  SecurityContext? context,
}) async {
  final raw = await Socket.connect(address, port, timeout: timeout);
  X509Certificate? seen;
  try {
    final secure = await SecureSocket.secure(
      raw,
      context: context,
      onBadCertificate: (certificate) {
        seen = certificate;
        return false;
      },
    ).timeout(timeout);
    // A certificate valid for a bare address: the handshake ended, and still nothing is written
    seen ??= secure.peerCertificate;
    secure.destroy();
  } on TlsException {
    // The refusal above, the expected end; also a server that speaks no TLS, whose certificate stays unseen
  } finally {
    raw.destroy();
  }
  final subject = seen?.subject;
  return subject == null ? null : plexHashOfSubject(subject);
}
