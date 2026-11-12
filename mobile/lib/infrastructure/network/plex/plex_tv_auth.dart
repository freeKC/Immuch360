// The optional "Sign in with Plex" of the page that adds a Plex server: the PIN flow of plex.tv, then the list of the
// servers of the account. The app talks to plex.tv only while the user goes through these steps; once a server is
// picked, its own token and address fill the page as if they had been typed, and nothing else of plex.tv is kept: the
// token of the account is dropped once the list is read. The manual entry stays the default way.
//
// The flow (https://plex.tv/api/v2): POST /pins gives a PIN; the user allows the app on plex.tv (the auth page opened
// with the PIN's code, or the 4 character code typed at plex.tv/link from another device); GET /pins/{id} gives the
// account token once allowed; GET /resources with that token lists the servers and their connections. A token travels
// in the X-Plex-Token header only, never in a URL, and no message or log line holds one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexTvAuth');

/// The base of the plex.tv API the app calls
final plexTvApi = Uri.parse('https://plex.tv/api/v2/');

/// Where a 4 character code is typed, from any device with a browser
final plexTvLinkUrl = Uri.parse('https://plex.tv/link');

/// What went wrong with plex.tv
enum PlexTvFailure {
  /// plex.tv does not answer: no network, or not in time
  unreachable,

  /// plex.tv refused the request (an account token that is not valid any more)
  refused,

  /// Any other answer
  failed,
}

class PlexTvException implements Exception {
  const PlexTvException(this.failure, [this.status]);

  final PlexTvFailure failure;

  /// The HTTP status of an answer, null for a failure of the network
  final int? status;

  /// A failure that may pass by itself: the network, plex.tv too busy or down for a moment
  bool get isTransient => failure == PlexTvFailure.unreachable || status == 429 || (status ?? 0) >= 500;

  @override
  String toString() => 'PlexTvException(${failure.name}${status == null ? '' : ', HTTP $status'})';
}

/// A PIN of plex.tv: [code] is the 4 characters typed at plex.tv/link, or with [strong] the 25 characters of the auth
/// page, which lives longer and is never typed
class PlexTvPin {
  const PlexTvPin({required this.id, required this.code, required this.expiresAt, required this.strong});

  final int id;
  final String code;

  /// When plex.tv forgets the PIN, on the clock of this device (from the "expiresIn" of the answer, so that a device
  /// whose clock is wrong still waits the right time)
  final DateTime expiresAt;
  final bool strong;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  @override
  String toString() => 'PlexTvPin(${strong ? 'strong' : 'short'}, until ${expiresAt.toIso8601String()})';
}

/// The PIN in the answer to POST /pins, received at [now]. Throws a [FormatException] when it is not one.
PlexTvPin parsePlexTvPin(Object? json, {required DateTime now, required bool strong}) {
  if (json is! Map) {
    throw const FormatException('Not a PIN');
  }
  final id = json['id'];
  final code = json['code'];
  final expiresIn = json['expiresIn'];
  if (id is! int || code is! String || code.isEmpty) {
    throw const FormatException('Not a PIN');
  }
  // A PIN lives 15 minutes (30 when strong); an answer without its life gets the shorter one
  final seconds = expiresIn is num && expiresIn > 0 ? expiresIn.toInt() : 900;
  return PlexTvPin(
    id: id,
    code: code,
    expiresAt: now.add(Duration(seconds: seconds)),
    strong: strong,
  );
}

/// The account token of an answer to GET /pins/{id}, null while the user has not allowed the app yet
String? plexTvPinToken(Object? json) {
  if (json is! Map) {
    throw const FormatException('Not a PIN');
  }
  final token = json['authToken'];
  return token is String && token.trim().isNotEmpty ? token.trim() : null;
}

/// A way to reach a server, as plex.tv lists it
class PlexTvConnection {
  const PlexTvConnection({required this.uri, this.local = false, this.relay = false, this.ipv6 = false});

  /// `https://<ipv4-dashes>.<hash>.plex.direct:<port>` for the servers with secure connections
  final String uri;

  /// An address of the server's own network
  final bool local;

  /// Through the relay of Plex, slow and capped: the last resort
  final bool relay;
  final bool ipv6;

  /// local first, then the other direct ones, the relay last
  int get rank => local ? 0 : (relay ? 2 : 1);

  @override
  String toString() => 'PlexTvConnection(${local ? 'local' : (relay ? 'relay' : 'remote')})';
}

/// A Plex Media Server of the account, from GET /resources
class PlexTvServer {
  const PlexTvServer({
    required this.name,
    required this.clientIdentifier,
    required this.owned,
    required this.accessToken,
    required this.connections,
  });

  final String name;

  /// The machine identifier of the server, the one its /identity tells
  final String clientIdentifier;

  /// The user's own server, rather than one shared with them
  final bool owned;

  /// The token for this server: the account's own for a server of the account, a token of its own for a shared
  /// server. Null when plex.tv gave none.
  final String? accessToken;

  /// In the order they are tried, see [orderPlexTvConnections]
  final List<PlexTvConnection> connections;

  @override
  String toString() =>
      'PlexTvServer(${owned ? 'owned' : 'shared'}, ${connections.length} connections'
      '${accessToken == null ? ', no token' : ''})';
}

/// [connections] in the order the app tries them: those of the server's network first, then the other direct ones,
/// the relay last, each kind in the order plex.tv gave; IPv6 ones left out (the app reaches Plex servers over IPv4
/// only, see parsePlexAddress)
List<PlexTvConnection> orderPlexTvConnections(Iterable<PlexTvConnection> connections) {
  final kept = connections.where((connection) => !connection.ipv6).toList();
  // List.sort is not stable: the index keeps the order of plex.tv within a kind
  final indexed = [for (var i = 0; i < kept.length; i++) (i, kept[i])];
  indexed.sort((a, b) => a.$2.rank != b.$2.rank ? a.$2.rank.compareTo(b.$2.rank) : a.$1.compareTo(b.$1));
  return [for (final (_, connection) in indexed) connection];
}

bool _flag(Object? value) => value == true || value == 1 || value == '1' || value == 'true';

/// The Plex Media Servers of an answer to GET /resources: the devices that provide "server" with a machine identifier,
/// their connections ordered. Players and other clients of the account are left out. Throws a [FormatException]
/// when the answer is no list.
List<PlexTvServer> parsePlexTvResources(Object? json) {
  if (json is! List) {
    throw const FormatException('Not a list of resources');
  }
  final servers = <PlexTvServer>[];
  for (final item in json) {
    if (item is! Map) {
      continue;
    }
    final provides = item['provides'];
    final id = item['clientIdentifier'];
    if (provides is! String || !provides.split(',').map((part) => part.trim()).contains('server')) {
      continue;
    }
    if (id is! String || id.isEmpty) {
      continue;
    }
    final connections = <PlexTvConnection>[];
    final listed = item['connections'];
    if (listed is List) {
      for (final connection in listed) {
        if (connection is! Map || connection['uri'] is! String) {
          continue;
        }
        connections.add(
          PlexTvConnection(
            uri: connection['uri'] as String,
            local: _flag(connection['local']),
            relay: _flag(connection['relay']),
            ipv6: _flag(connection['IPv6']),
          ),
        );
      }
    }
    final name = item['name'];
    final token = item['accessToken'];
    servers.add(
      PlexTvServer(
        name: name is String && name.trim().isNotEmpty ? name.trim() : id,
        clientIdentifier: id.toLowerCase(),
        owned: _flag(item['owned']),
        accessToken: token is String && token.isNotEmpty ? token : null,
        connections: orderPlexTvConnections(connections),
      ),
    );
  }
  // The user's own servers first, each group by name
  servers.sort((a, b) {
    if (a.owned != b.owned) {
      return a.owned ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return servers;
}

/// The auth page of plex.tv for a strong [pin], opened in the browser: the user signs in there and allows the app
Uri plexTvAuthUrl(PlexTvPin pin, String clientIdentifier) {
  String query(Map<String, String> parameters) => parameters.entries
      .map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
      .join('&');
  return Uri.parse(
    'https://app.plex.tv/auth#?${query({'clientID': clientIdentifier, 'code': pin.code, 'context[device][product]': plexProduct})}',
  );
}

/// Where the sign in with plex.tv stands, see [PlexTvAuth.signIn]
sealed class PlexTvSignInState {
  const PlexTvSignInState();
}

/// Asking plex.tv for a PIN
class PlexTvRequesting extends PlexTvSignInState {
  const PlexTvRequesting();
}

/// Waiting for the user to allow the app on plex.tv
class PlexTvWaiting extends PlexTvSignInState {
  const PlexTvWaiting(this.pin);

  final PlexTvPin pin;
}

/// The user allowed the app: [token] is the token of the account, to read the list of servers with, then dropped
class PlexTvAuthorised extends PlexTvSignInState {
  const PlexTvAuthorised(this.token);

  final String token;

  @override
  String toString() => 'PlexTvAuthorised()';
}

/// The PIN ended before the user allowed the app: a new one is needed
class PlexTvExpired extends PlexTvSignInState {
  const PlexTvExpired();
}

/// plex.tv could not be used
class PlexTvFailed extends PlexTvSignInState {
  const PlexTvFailed(this.error);

  final PlexTvException error;
}

/// The requests to plex.tv. [client] makes the HTTP client of each request (a fake one in the tests).
class PlexTvAuth {
  PlexTvAuth({
    http.Client Function()? client,
    Future<String> Function()? clientIdentifier,
    Future<String?> Function()? appVersion,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? _defaultClient,
       _clientIdentifier = clientIdentifier ?? plexClientIdentifier,
       _appVersion = appVersion ?? plexAppVersion,
       _now = now ?? DateTime.now;

  final http.Client Function() _client;
  final Future<String> Function() _clientIdentifier;
  final Future<String?> Function() _appVersion;
  final DateTime Function() _now;

  /// Longest wait for an answer of plex.tv
  final Duration timeout;

  /// Largest answer read: a list of resources of a few servers takes some kB
  static const maxAnswerSize = 4 * 1024 * 1024;

  static http.Client _defaultClient() => IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 15));

  static String get _platform => Platform.isIOS
      ? 'iOS'
      : Platform.isAndroid
      ? 'Android'
      : Platform.operatingSystem;

  /// The X-Plex-Client-Identifier of the requests, the same as the one sent to the servers
  Future<String> clientIdentifier() => _clientIdentifier();

  /// The headers of every request to plex.tv; the token only for the list of servers
  Future<Map<String, String>> headers({String? token}) async {
    final version = await _appVersion();
    return {
      'accept': 'application/json',
      'x-plex-token': ?token,
      'x-plex-client-identifier': await _clientIdentifier(),
      'x-plex-product': plexProduct,
      'x-plex-version': ?version,
      'x-plex-platform': _platform,
      'x-plex-device-name': plexProduct,
    };
  }

  /// A new PIN: [strong] for the auth page opened in a browser, else a 4 character code for plex.tv/link
  Future<PlexTvPin> requestPin({required bool strong}) async {
    final json = await _json('POST', plexTvApi.resolve(strong ? 'pins?strong=true' : 'pins'), expect: const {200, 201});
    try {
      return parsePlexTvPin(json, now: _now(), strong: strong);
    } on FormatException {
      throw const PlexTvException(PlexTvFailure.failed);
    }
  }

  /// The account token once the user allowed the app, null until then. Throws a [PlexTvException] with status 404
  /// once plex.tv forgot the PIN.
  Future<String?> checkPin(PlexTvPin pin) async {
    final json = await _json('GET', plexTvApi.resolve('pins/${pin.id}'));
    try {
      return plexTvPinToken(json);
    } on FormatException {
      throw const PlexTvException(PlexTvFailure.failed);
    }
  }

  /// The Plex Media Servers [accountToken] reaches, with their connections over HTTPS and the relay
  Future<List<PlexTvServer>> servers(String accountToken) async {
    final json = await _json(
      'GET',
      plexTvApi.resolve('resources?includeHttps=1&includeRelay=1&includeIPv6=0'),
      token: accountToken,
    );
    try {
      return parsePlexTvResources(json);
    } on FormatException {
      throw const PlexTvException(PlexTvFailure.failed);
    }
  }

  /// Asks for a PIN, then asks plex.tv every [interval] whether the user allowed the app, until they did
  /// ([PlexTvAuthorised], the last state), the PIN ended ([PlexTvExpired]) or plex.tv cannot be used ([PlexTvFailed]):
  /// a failure that may pass is only one after [maxTransientErrors] in a row. [PlexTvWaiting] comes again after each
  /// question still pending. Cancelling the subscription stops the questions. [wait] replaces the timer in the tests.
  Stream<PlexTvSignInState> signIn({
    required bool strong,
    Duration interval = const Duration(seconds: 2),
    int maxTransientErrors = 3,
    Future<void> Function(Duration)? wait,
  }) async* {
    final pause = wait ?? (duration) => Future<void>.delayed(duration);
    yield const PlexTvRequesting();
    final PlexTvPin pin;
    try {
      pin = await requestPin(strong: strong);
    } on PlexTvException catch (error) {
      _log.info('plex.tv gave no PIN: $error');
      yield PlexTvFailed(error);
      return;
    }
    yield PlexTvWaiting(pin);
    var errors = 0;
    while (true) {
      await pause(interval);
      if (pin.isExpired(_now())) {
        yield const PlexTvExpired();
        return;
      }
      try {
        final token = await checkPin(pin);
        errors = 0;
        if (token != null) {
          yield PlexTvAuthorised(token);
          return;
        }
      } on PlexTvException catch (error) {
        if (error.status == 404) {
          yield const PlexTvExpired();
          return;
        }
        if (!error.isTransient || ++errors >= maxTransientErrors) {
          _log.info('The sign in with plex.tv stopped: $error');
          yield PlexTvFailed(error);
          return;
        }
      }
      // Still waiting. Also where a cancelled subscription stops the generator: an async* function only stops at a
      // yield, and without this one the questions would go on after the page was left.
      yield PlexTvWaiting(pin);
    }
  }

  /// Sends one request and gives its JSON; any status out of [expect] throws a [PlexTvException], the body dropped
  Future<Object?> _json(String method, Uri uri, {String? token, Set<int> expect = const {200}}) async {
    final client = _client();
    final trigger = Completer<void>();
    final timer = Timer(timeout, () {
      if (!trigger.isCompleted) {
        trigger.complete();
      }
    });
    try {
      final request = http.AbortableRequest(method, uri, abortTrigger: trigger.future)
        ..followRedirects = false
        ..headers.addAll(await headers(token: token));
      final response = await client.send(request);
      final status = response.statusCode;
      if (!expect.contains(status)) {
        await response.stream.listen(null).cancel();
        throw PlexTvException(status == 401 || status == 403 ? PlexTvFailure.refused : PlexTvFailure.failed, status);
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        body.add(chunk);
        if (body.length > maxAnswerSize) {
          throw PlexTvException(PlexTvFailure.failed, status);
        }
      }
      return jsonDecode(utf8.decode(body.takeBytes(), allowMalformed: true));
    } on PlexTvException {
      rethrow;
    } on FormatException {
      throw const PlexTvException(PlexTvFailure.failed);
    } on SocketException {
      throw const PlexTvException(PlexTvFailure.unreachable);
    } on TimeoutException {
      throw const PlexTvException(PlexTvFailure.unreachable);
    } on HandshakeException {
      // A certificate the system refuses: something on the way pretends to be plex.tv
      throw const PlexTvException(PlexTvFailure.failed);
    } on http.ClientException {
      // An aborted request (no answer in time) comes as one too
      throw const PlexTvException(PlexTvFailure.unreachable);
    } on HttpException {
      throw const PlexTvException(PlexTvFailure.unreachable);
    } finally {
      timer.cancel();
      client.close();
    }
  }
}

/// A server of plex.tv reached at one of its addresses: what fills the page, as if typed
class PlexTvConnected {
  const PlexTvConnected({required this.address, required this.server, required this.token});

  final PlexAddress address;
  final PlexServerFound server;

  /// The token of the server (see [PlexTvServer.accessToken])
  final String token;

  @override
  String toString() => 'PlexTvConnected($server)';
}

/// Reaches [server] through [lookUp] (PlexPairing.lookUp: the pinned look up of the page) at each of its connections
/// in order, the first that answers with the server's machine identifier winning. [accountToken] stands in for a
/// server plex.tv gave no token of its own. Throws the failure of the last connection tried, or an unreachable one
/// when none can be used.
Future<PlexTvConnected> connectPlexTvServer(
  PlexTvServer server,
  String accountToken,
  Future<PlexServerFound> Function(PlexAddress address) lookUp,
) async {
  NetworkFileSystemException? last;
  final tried = <String>{};
  for (final connection in server.connections) {
    final PlexAddress address;
    try {
      address = parsePlexAddress(connection.uri);
    } on PlexAddressException {
      continue;
    }
    // A name and a plex.direct name may give the same address
    if (!tried.add('${address.host}:${address.port}:${address.hash}')) {
      continue;
    }
    try {
      final found = await lookUp(address);
      if (found.machineIdentifier.isNotEmpty && found.machineIdentifier != server.clientIdentifier) {
        last = const PlexFileSystemException('Another Plex server answers at this address', PlexFailure.otherServer);
        continue;
      }
      return PlexTvConnected(
        address: address,
        server: PlexServerFound(
          address: found.address,
          port: found.port,
          hash: found.hash,
          machineIdentifier: found.machineIdentifier,
          version: found.version,
          name: server.name,
          typedName: found.typedName,
        ),
        token: server.accessToken ?? accountToken,
      );
    } on NetworkFileSystemException catch (error) {
      _log.fine('A connection of a Plex server from plex.tv failed (${connection.rank}): ${plexErrorKind(error)}');
      last = error;
    }
  }
  throw last ?? const PlexFileSystemException('No address of this Plex server can be used', PlexFailure.unreachable);
}
