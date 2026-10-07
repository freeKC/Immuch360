// The requests of the app to a Plex Media Server, sent through the pinned client of plex_direct.dart. Every request
// carries the headers that name the app to the server (its dashboard lists one entry per install). The token travels in
// the X-Plex-Token header only, never in a URL: URLs end up in logs and in error messages. No redirect is followed,
// since the header would go with it wherever the answer points. Answers are read with a size and a time limit, and the
// body of an error is never parsed: Plex answers 401 in HTML whatever the request accepts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _log = Logger('PlexClient');

/// How the app names itself to the server, as product and as device: never the name the user gave the phone
const plexProduct = 'Immuch360';

final _tokenInText = RegExp(r'(X-Plex-Token\s*[=:]\s*)[^&#\s,;"]*', caseSensitive: false);

/// [text] with the value of every X-Plex-Token (a query parameter, a header line) replaced, for the messages built from
/// a URI or an answer
String redactPlexToken(String text) => text.replaceAllMapped(_tokenInText, (match) => '${match[1]}<hidden>');

/// What went wrong with a Plex server, for the page that pairs it and the messages of the browser
enum PlexFailure {
  /// Nothing answers at the address, at home
  unreachable,

  /// Nothing answers at the address outside home, or there is none
  unreachableOutsideHome,

  /// The address answers with a certificate other than the one of the stored hash, or one that is not valid any more
  wrongCertificate,

  /// The right certificate, but another machine identifier
  otherServer,

  /// The certificate of the address is no plex.direct one: a server not claimed, secure connections off, or no Plex
  notPlex,

  /// 401: the token is wrong, revoked or expired
  tokenRefused,

  /// 403: a shared or managed user without the right to a library or to downloads
  tokenForbidden,

  /// Anything else the server answered
  failed,
}

/// A failure of a Plex server, told in English like the failures of every share, with its [failure] for the pages that
/// put it into the user's language. Never holds the token, an address, a path or a title.
class PlexFileSystemException extends NetworkFileSystemException {
  const PlexFileSystemException(super.message, this.failure, {super.isAuthentication, super.isNotFound});

  final PlexFailure failure;
}

/// An answer with another status than the one expected; its body was dropped unread
class PlexHttpStatus implements Exception {
  const PlexHttpStatus(this.status);

  final int status;

  @override
  String toString() => 'HTTP $status';
}

/// The exception the user gets for [error] of a request to a Plex server. [outsideHome] tells which address failed.
NetworkFileSystemException plexErrorOf(Object error, {bool outsideHome = false}) => switch (error) {
  NetworkFileSystemException() => error,
  PlexHttpStatus(status: 401) => const PlexFileSystemException(
    'The Plex server refused the token',
    PlexFailure.tokenRefused,
    isAuthentication: true,
  ),
  PlexHttpStatus(status: 403) => const PlexFileSystemException(
    'The token has no right to this library or to downloads',
    PlexFailure.tokenForbidden,
    isAuthentication: true,
  ),
  PlexHttpStatus(:final status) when status >= 300 && status < 400 => const PlexFileSystemException(
    'The Plex server sent the request elsewhere, which the app does not follow',
    PlexFailure.failed,
  ),
  PlexHttpStatus(:final status) => PlexFileSystemException('The Plex server answered HTTP $status', PlexFailure.failed),
  HandshakeException(:final message) when message.toLowerCase().contains('expired') => const PlexFileSystemException(
    'The certificate of the Plex server has expired',
    PlexFailure.wrongCertificate,
  ),
  HandshakeException() => const PlexFileSystemException(
    'This address answers with the certificate of another server',
    PlexFailure.wrongCertificate,
  ),
  TlsException() => const PlexFileSystemException(
    'The secure connection to the Plex server failed',
    PlexFailure.failed,
  ),
  FormatException() => const PlexFileSystemException(
    'The server did not answer like a Plex Media Server',
    PlexFailure.failed,
  ),
  SocketException() ||
  TimeoutException() ||
  HttpException() ||
  http.ClientException() => _unreachable(outsideHome, error),
  // The type only: the message of an unexpected error may hold anything
  _ => PlexFileSystemException('The Plex server could not be read (${error.runtimeType})', PlexFailure.failed),
};

PlexFileSystemException _unreachable(bool outsideHome, Object error) {
  // The reason without the address the system puts in its own message
  final reason = switch (error) {
    SocketException(:final osError?) => ' (${osError.message})',
    TimeoutException() || http.RequestAbortedException() => ' (no answer in time)',
    _ => '',
  };
  return outsideHome
      ? PlexFileSystemException(
          'Your Plex server cannot be reached from outside your home network$reason. Turn on remote access with a '
          'port forwarding in Plex (Settings, Remote Access), or type its public address.',
          PlexFailure.unreachableOutsideHome,
        )
      : PlexFileSystemException('The Plex server does not answer$reason', PlexFailure.unreachable);
}

/// Whether [error] is a failure of the network rather than an answer of the server: another address of the server
/// may answer
bool isPlexNetworkFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is HttpException ||
    error is TlsException ||
    // An answer that did not come in time too: the request is aborted then
    error is http.ClientException ||
    (error is PlexFileSystemException &&
        (error.failure == PlexFailure.unreachable || error.failure == PlexFailure.unreachableOutsideHome));

/// The requests to one Plex server, whatever its address: the URIs are given whole, and [_http] is the pinned client
/// of its hash (a plain one in the tests)
class PlexClient {
  const PlexClient(
    this._http, {
    required this._token,
    required this.clientIdentifier,
    this.appVersion,
    this.answerTimeout = defaultAnswerTimeout,
  });

  final http.Client _http;
  final String? _token;

  /// X-Plex-Client-Identifier, see [plexClientIdentifier]
  final String clientIdentifier;

  /// X-Plex-Version, null when the version of the app is not known
  final String? appVersion;

  /// Longest wait for the answer of the server, then between two parts of a body
  final Duration answerTimeout;

  static const defaultAnswerTimeout = Duration(seconds: 30);

  /// Largest JSON answer read: a page of 200 items takes well under 1 MiB, even with long summaries
  static const maxJsonSize = 16 * 1024 * 1024;

  /// Largest picture read from the photo transcoder
  static const maxPictureSize = 8 * 1024 * 1024;

  /// Past this size, an answer is parsed in another isolate, away from the interface
  static const isolateParseSize = 256 * 1024;

  static String get _platform => Platform.isIOS
      ? 'iOS'
      : Platform.isAndroid
      ? 'Android'
      : Platform.operatingSystem;

  /// The headers of every request. The token goes in its header unless [withToken] is false (/identity needs none).
  Map<String, String> headers({bool withToken = true, String accept = 'application/json'}) {
    final token = _token;
    final version = appVersion;
    return {
      'accept': accept,
      if (withToken && token != null) 'x-plex-token': token,
      'x-plex-client-identifier': clientIdentifier,
      'x-plex-product': plexProduct,
      'x-plex-version': ?version,
      'x-plex-platform': _platform,
      'x-plex-device-name': plexProduct,
    };
  }

  /// Sends one request to [uri], aborted when [abort] completes or when no answer comes within [answerTimeout]. A
  /// redirect is an error: its body is dropped and a [PlexHttpStatus] thrown.
  Future<http.StreamedResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    bool withToken = true,
    String accept = 'application/json',
    Future<void>? abort,
  }) async {
    final trigger = Completer<void>();
    void fire() {
      if (!trigger.isCompleted) {
        trigger.complete();
      }
    }

    final timer = Timer(answerTimeout, fire);
    unawaited(abort?.whenComplete(fire));
    final request = http.AbortableRequest(method, uri, abortTrigger: trigger.future)
      ..followRedirects = false
      ..headers.addAll(this.headers(withToken: withToken, accept: accept))
      ..headers.addAll(headers);
    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } finally {
      timer.cancel();
    }
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      await discardHttpBody(response);
      throw PlexHttpStatus(status);
    }
    return response;
  }

  /// GETs [uri] and gives the answer, parsed by [parse] from its JSON (in another isolate past [isolateParseSize]
  /// bytes). Any status but 200 throws a [PlexHttpStatus], the body dropped.
  Future<T> getJson<T>(
    Uri uri,
    T Function(Object? json) parse, {
    Map<String, String> headers = const {},
    bool withToken = true,
    Future<void>? abort,
  }) async {
    final response = await send('GET', uri, headers: headers, withToken: withToken, abort: abort);
    if (response.statusCode != 200) {
      await discardHttpBody(response);
      throw PlexHttpStatus(response.statusCode);
    }
    final text = utf8.decode(await _body(response, maxJsonSize), allowMalformed: true);
    return text.length > isolateParseSize ? await Isolate.run(() => parse(jsonDecode(text))) : parse(jsonDecode(text));
  }

  /// GETs the bytes at [uri]: null for a 404, a [PlexHttpStatus] for any other status but 200
  Future<Uint8List?> getBytes(Uri uri, {String accept = 'image/jpeg', int maxSize = maxPictureSize}) async {
    final response = await send('GET', uri, accept: accept);
    if (response.statusCode == 404) {
      await discardHttpBody(response);
      return null;
    }
    if (response.statusCode != 200) {
      await discardHttpBody(response);
      throw PlexHttpStatus(response.statusCode);
    }
    return _body(response, maxSize);
  }

  /// What the server at [base] tells of its address outside home (see [plexPublicAddressOf]); null when it tells
  /// nothing usable. Asks /myplex/account and /:/prefs, both on the server itself and behind the token; the account
  /// answer also holds the user name and an account token, which are not read.
  Future<PlexLearnedAddress?> learnPublicAddress(Uri base, String hash) async {
    PlexAccountAddress? account;
    PlexPrefsAddress? prefs;
    try {
      account = await getJson(base.resolve('/myplex/account'), parsePlexAccount);
    } catch (error) {
      _log.fine('The server did not tell its account address: ${_kindOf(error)}');
    }
    try {
      prefs = await getJson(base.resolve('/:/prefs'), (json) => parsePlexPrefs(json, hash));
    } catch (error) {
      _log.fine('The server did not tell its preferences: ${_kindOf(error)}');
    }
    final found = plexPublicAddressOf(account, prefs);
    return found == null
        ? null
        : PlexLearnedAddress(host: found.host, port: found.port, mapping: found.mapping, at: DateTime.now().toUtc());
  }

  /// Closes the client; the open transfers stop
  void close() => _http.close();

  /// The body of [response], at most [maxSize] bytes, each part within [answerTimeout]
  Future<Uint8List> _body(http.StreamedResponse response, int maxSize) async {
    final declared = response.contentLength;
    if (declared != null && declared > maxSize) {
      await response.stream.listen(null).cancel();
      throw const PlexFileSystemException('The Plex server sent too large an answer', PlexFailure.failed);
    }
    final body = BytesBuilder(copy: false);
    final chunks = StreamIterator(response.stream);
    try {
      while (await chunks.moveNext().timeout(answerTimeout)) {
        body.add(chunks.current);
        if (body.length > maxSize) {
          throw const PlexFileSystemException('The Plex server sent too large an answer', PlexFailure.failed);
        }
      }
      return body.takeBytes();
    } finally {
      // Stops a transfer that was cut; nothing to wait for once the body ended
      chunks.cancel().ignore();
    }
  }
}

/// A word for the logs about [error]: its type and status, never its message, which may hold an address
String plexErrorKind(Object error) => _kindOf(error);

String _kindOf(Object error) => switch (error) {
  PlexHttpStatus(:final status) => 'HTTP $status',
  PlexFileSystemException(:final failure) => failure.name,
  SocketException(:final osError) => 'socket error ${osError?.errorCode ?? ''}'.trim(),
  _ => error.runtimeType.toString(),
};

/// The X-Plex-Client-Identifier of this install (StoreKey.plexClientIdentifier): 32 hex digits made on first use and
/// kept, so that the server lists the app once. A new one each time when the Store is not there.
Future<String> plexClientIdentifier({StoreService? store}) async {
  StoreService? service = store;
  if (service == null) {
    try {
      service = StoreService.I;
    } on UnsupportedError {
      service = null;
    }
  }
  final known = service?.tryGet(StoreKey.plexClientIdentifier);
  if (known != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(known)) {
    return known;
  }
  final random = Random.secure();
  final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  try {
    await service?.put(StoreKey.plexClientIdentifier, id);
  } catch (error) {
    _log.fine('The Plex client identifier could not be kept: ${_kindOf(error)}');
  }
  return id;
}

Future<String?>? _appVersion;

/// The version of the app for X-Plex-Version, null when the platform does not tell (the tests)
Future<String?> plexAppVersion() => _appVersion ??= () async {
  try {
    return (await PackageInfo.fromPlatform().timeout(const Duration(seconds: 1))).version;
  } catch (_) {
    return null;
  }
}();
