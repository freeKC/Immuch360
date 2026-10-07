// What the page that adds or edits a Plex server does, apart from its widgets: read the address typed, look the server
// up without the token (the hash of its certificate, then its identity through the pinned client), test a token, and
// learn what the server tells of its address outside home. The page gets it through plexPairingProvider, which the
// tests replace.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_token.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart' show isLocalNetworkAddress;
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';

/// Why a typed address cannot be used
enum PlexAddressProblem { empty, ipv6, invalid }

class PlexAddressException implements Exception {
  const PlexAddressException(this.problem);

  final PlexAddressProblem problem;

  @override
  String toString() => 'PlexAddressException(${problem.name})';
}

/// What was typed in the address field, see [parsePlexAddress]
class PlexAddress {
  const PlexAddress({required this.host, this.port, this.hash, this.token});

  /// An IPv4 address, or a host name (a DynDNS name for outside home). The address written in a plex.direct name.
  final String host;
  final int? port;

  /// From a plex.direct name
  final String? hash;

  /// The token of a pasted "View XML" address
  final PastedPlexToken? token;

  bool get isName => InternetAddress.tryParse(host) == null;

  /// What the field keeps once a whole address was read: the server only
  String get text => port == null ? host : '$host:$port';

  @override
  String toString() => 'PlexAddress(${isName ? 'name' : 'address'}${hash == null ? '' : ', hash'})';
}

final _hostName = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.?$', caseSensitive: false);

/// Reads an address typed or pasted: a plex.direct URL, `IP[:port]`, `name[:port]` (DynDNS), or the whole "View XML"
/// address, whose token comes with it. Throws a [PlexAddressException] for nothing, an IPv6 address (the plex.direct
/// names of IPv6 were not checked) or anything else.
PlexAddress parsePlexAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw const PlexAddressException(PlexAddressProblem.empty);
  }
  String host;
  int? port;
  PastedPlexToken? token;
  if (trimmed.contains('://')) {
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
      throw const PlexAddressException(PlexAddressProblem.invalid);
    }
    host = uri.host;
    port = uri.hasPort ? uri.port : null;
    if (trimmed.toLowerCase().contains('x-plex-token=')) {
      token = parsePastedPlexToken(trimmed);
    }
  } else {
    final withoutPath = trimmed.split('/').first;
    if (withoutPath.startsWith('[') || ':'.allMatches(withoutPath).length > 1) {
      throw const PlexAddressException(PlexAddressProblem.ipv6);
    }
    final colon = withoutPath.lastIndexOf(':');
    host = colon < 0 ? withoutPath : withoutPath.substring(0, colon);
    if (colon >= 0) {
      port = int.tryParse(withoutPath.substring(colon + 1));
      if (port == null) {
        throw const PlexAddressException(PlexAddressProblem.invalid);
      }
    }
  }
  host = host.toLowerCase();
  if (port != null && (port <= 0 || port > 65535)) {
    throw const PlexAddressException(PlexAddressProblem.invalid);
  }
  final named = parsePlexDirectHost(host);
  if (named != null) {
    return PlexAddress(host: named.address.address, port: port, hash: named.hash, token: token);
  }
  final address = InternetAddress.tryParse(host);
  if (address != null && address.type != InternetAddressType.IPv4) {
    throw const PlexAddressException(PlexAddressProblem.ipv6);
  }
  if (address == null && !_hostName.hasMatch(host)) {
    throw const PlexAddressException(PlexAddressProblem.invalid);
  }
  return PlexAddress(host: host, port: port, token: token);
}

/// A Plex server the page found, by its address or on the network
class PlexServerFound {
  const PlexServerFound({
    required this.address,
    required this.port,
    required this.hash,
    required this.machineIdentifier,
    this.version,
    this.name,
    this.typedName,
  });

  /// The server as GDM found it, without any request: what it announces is checked by the pinned client at the test
  static PlexServerFound? fromDiscovery(DiscoveredServer server) {
    final address = InternetAddress.tryParse(server.host);
    final hash = server.plexHash?.toLowerCase();
    final id = server.discoveryId;
    if (server.type != NetworkSourceType.plex ||
        address == null ||
        address.type != InternetAddressType.IPv4 ||
        hash == null ||
        !isPlexHash(hash) ||
        id == null) {
      return null;
    }
    return PlexServerFound(
      address: address,
      port: server.port,
      hash: hash,
      machineIdentifier: id.toLowerCase(),
      version: server.version,
      name: server.displayName == server.host ? null : server.displayName,
    );
  }

  final InternetAddress address;
  final int port;
  final String hash;
  final String machineIdentifier;
  final String? version;

  /// The name the server announces on the network, null for an address typed until the token test tells it
  final String? name;

  /// The host name typed (a DynDNS name), kept as the address outside home so that it is resolved again each time
  final String? typedName;

  /// An address of the local network: kept as the address at home. Any other one is the address outside home.
  bool get isLocal => isLocalNetworkAddress(address);

  /// The first 8 digits of the machine identifier, enough to tell two servers apart
  String get shortId => machineIdentifier.length > 8 ? machineIdentifier.substring(0, 8) : machineIdentifier;

  /// What the field shows for it
  String get addressText => '${typedName ?? address.address}:$port';

  @override
  String toString() => 'PlexServerFound(${isLocal ? 'at home' : 'outside home'}, port $port)';
}

/// What a successful token test learned
class PlexTokenCheck {
  const PlexTokenCheck({required this.sections, this.serverName, this.version, this.learned});

  /// The libraries the app shows
  final List<PlexSection> sections;
  final String? serverName;
  final String? version;

  /// What the server tells of its address outside home, asked at home only
  final PlexLearnedAddress? learned;
}

/// The page logic, see the top of this file
class PlexPairing {
  PlexPairing({
    this._probeHash = _defaultProbeHash,
    this._lookupIPv4 = _defaultLookupIPv4,
    http.Client Function(String hash)? clientFor,
    Uri Function(PlexServerFound server)? baseOf,
    Future<String> Function()? clientIdentifier,
  }) : _clientFor = clientFor ?? ((hash) => IOClient(pinnedPlexHttpClient(hash))),
       _baseOf = baseOf ?? ((server) => plexDirectUri(server.address, server.port, server.hash)),
       _clientIdentifier = clientIdentifier ?? plexClientIdentifier;

  final Future<String?> Function(InternetAddress address, int port) _probeHash;
  final Future<InternetAddress> Function(String host) _lookupIPv4;
  final http.Client Function(String hash) _clientFor;
  final Uri Function(PlexServerFound server) _baseOf;
  final Future<String> Function() _clientIdentifier;

  static Future<String?> _defaultProbeHash(InternetAddress address, int port) => probePlexHash(address, port);

  static Future<InternetAddress> _defaultLookupIPv4(String host) async {
    final found = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 8));
    if (found.isEmpty) {
      throw const SocketException('No IPv4 address');
    }
    return found.first;
  }

  /// The server at [typed], without the token: the hash of its certificate (the one of the plex.direct name typed,
  /// [knownHash] for a server already paired, else read from the certificate it shows), then its identity through the
  /// pinned client. Throws a [PlexFileSystemException]: unreachable, notPlex, wrongCertificate, failed.
  Future<PlexServerFound> lookUp(PlexAddress typed, {String? knownHash}) async {
    final port = typed.port ?? plexDefaultPort;
    final InternetAddress address;
    String? hash = typed.hash ?? knownHash;
    try {
      address = typed.isName ? await _lookupIPv4(typed.host) : InternetAddress(typed.host);
      hash ??= await _probeHash(address, port);
    } catch (error) {
      throw plexErrorOf(error);
    }
    if (hash == null) {
      throw const PlexFileSystemException('This address answers without a Plex certificate', PlexFailure.notPlex);
    }
    final found = PlexServerFound(
      address: address,
      port: port,
      hash: hash,
      machineIdentifier: '',
      typedName: typed.isName ? typed.host : null,
    );
    final client = await _client(found, null);
    try {
      final identity = await client.getJson(_baseOf(found).resolve('/identity'), parsePlexIdentity, withToken: false);
      if (identity == null) {
        throw const FormatException('No identity');
      }
      return PlexServerFound(
        address: address,
        port: port,
        hash: hash,
        machineIdentifier: identity.machineIdentifier.toLowerCase(),
        version: identity.version,
        typedName: found.typedName,
      );
    } catch (error) {
      throw plexErrorOf(error, outsideHome: !found.isLocal);
    } finally {
      client.close();
    }
  }

  /// Tests [token] on [server]: its identity again (another server behind the same certificate is refused), its
  /// libraries, its name, and at home what it tells of its address outside home. Throws a [PlexFileSystemException]:
  /// tokenRefused (401), tokenForbidden (403), otherServer, unreachable, wrongCertificate, failed.
  Future<PlexTokenCheck> testToken(PlexServerFound server, String token) async {
    final client = await _client(server, token);
    final base = _baseOf(server);
    try {
      final identity = await client.getJson(base.resolve('/identity'), parsePlexIdentity, withToken: false);
      if (identity == null) {
        throw const FormatException('No identity');
      }
      if (server.machineIdentifier.isNotEmpty && identity.machineIdentifier.toLowerCase() != server.machineIdentifier) {
        throw const PlexFileSystemException('Another Plex server answers at this address', PlexFailure.otherServer);
      }
      final sections = await client.getJson(base.resolve('/library/sections'), parsePlexSections);
      String? name;
      try {
        name = await client.getJson(base.resolve('/'), parsePlexServerName);
      } on PlexHttpStatus {
        // The name is only the default of the name field
      }
      final learned = server.isLocal ? await client.learnPublicAddress(base, server.hash) : null;
      return PlexTokenCheck(sections: sections, serverName: name, version: identity.version, learned: learned);
    } catch (error) {
      throw plexErrorOf(error, outsideHome: !server.isLocal);
    } finally {
      client.close();
    }
  }

  Future<PlexClient> _client(PlexServerFound server, String? token) async => PlexClient(
    _clientFor(server.hash),
    token: token,
    clientIdentifier: await _clientIdentifier(),
    appVersion: await plexAppVersion(),
    answerTimeout: const Duration(seconds: 15),
  );
}
