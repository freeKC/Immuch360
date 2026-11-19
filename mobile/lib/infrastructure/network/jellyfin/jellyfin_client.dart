// The requests of the app to a Jellyfin or Emby server. Every request names the app in the authorization header of
// the product (Jellyfin: Authorization: MediaBrowser Client=..., Device=..., DeviceId=..., Version=..., Token=...;
// Emby: the same value in X-Emby-Authorization, and the token in X-Emby-Token too). The token travels in that header
// only, never in a URL: URLs end up in logs and in error messages. No redirect is followed, since the header would go
// with it wherever the answer points. Answers are read with a size and a time limit.
//
// The DeviceId is the install's (StoreKey.jellyfinDeviceId) followed by the start of the source id: Jellyfin ends the
// earlier token of a user when the same user signs in again with the same DeviceId (bench of release 49, fact 5), so
// two accounts of one server on one install, or the same account added twice, never end each other's session.
//
// Logs tell request kinds, statuses and timings, never the token, the Quick Connect secret, an address, a path or a
// title.

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
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';
import 'package:logging/logging.dart';

final _log = Logger('JellyfinClient');

/// How the app names itself to the server: never the name the user gave the device
const jellyfinClientName = 'Immuch360';

/// The default port of both products over http; 8920 is the one of https
const jellyfinDefaultPort = 8096;
const jellyfinDefaultTlsPort = 8920;

/// What went wrong with a Jellyfin or Emby server, for the pages that put it into the user's language
enum JellyfinFailure {
  /// Nothing answers at the address
  unreachable,

  /// Something answers, but not Jellyfin or Emby
  notJellyfin,

  /// A Jellyfin or Emby server answers, with another id than the one of the source: no token is sent to it
  otherServer,

  /// The server's setup is not done
  setupNotDone,

  /// The user or the password is wrong
  passwordRefused,

  /// 401 with the token: the session was ended (signed out, the user removed, a sign in elsewhere)
  tokenRefused,

  /// Quick Connect is turned off on the server (or the product has none)
  quickConnectOff,

  /// The Quick Connect code is no longer known to the server
  quickConnectExpired,

  /// 403: the user has no right to this item or to downloads
  downloadForbidden,

  /// The server answered with an error of its own (5xx, an answer that does not read)
  serverError,

  /// The https address has no valid certificate
  tlsRefused,
}

/// A failure of a Jellyfin or Emby server, told in English like the failures of every share, with its [failure] for
/// the pages. Never holds the token, an address, a path or a title.
class JellyfinException extends NetworkFileSystemException {
  const JellyfinException(
    super.message,
    this.failure, {
    this.status,
    super.isAuthentication,
    super.isNotFound,
    super.isDownloadForbidden,
  });

  /// The exception of [failure], its flags set: passwordRefused and tokenRefused are isAuthentication
  factory JellyfinException.of(JellyfinFailure failure, {int? status}) => JellyfinException(
    _messages[failure]!,
    failure,
    status: status,
    isAuthentication: failure == JellyfinFailure.passwordRefused || failure == JellyfinFailure.tokenRefused,
    isNotFound: status == 404 && failure == JellyfinFailure.serverError,
    isDownloadForbidden: failure == JellyfinFailure.downloadForbidden,
  );

  final JellyfinFailure failure;

  /// The HTTP status that told, null for a failure of the network
  final int? status;

  static const _messages = {
    JellyfinFailure.unreachable: 'No Jellyfin or Emby server answers at this address',
    JellyfinFailure.notJellyfin: 'The server at this address is not a Jellyfin or Emby server',
    JellyfinFailure.otherServer: 'Another server answers at this address now',
    JellyfinFailure.setupNotDone: 'This server is not set up yet',
    JellyfinFailure.passwordRefused: 'The user or the password is wrong',
    JellyfinFailure.tokenRefused: 'The server ended this session',
    JellyfinFailure.quickConnectOff: 'Quick Connect is turned off on this server',
    JellyfinFailure.quickConnectExpired: 'The Quick Connect code expired',
    JellyfinFailure.downloadForbidden: 'This user may not read this item',
    JellyfinFailure.serverError: 'The server could not answer',
    JellyfinFailure.tlsRefused: 'The certificate of this https address is not valid',
  };
}

/// An answer with another status than the one expected; its body was dropped unread
class JellyfinHttpStatus implements Exception {
  const JellyfinHttpStatus(this.status);

  final int status;

  @override
  String toString() => 'HTTP $status';
}

/// A request stopped by its caller: no failure of the server
class JellyfinRequestCancelled implements Exception {
  const JellyfinRequestCancelled();

  @override
  String toString() => 'The request was cancelled';
}

/// The exception the user gets for [error] of a request. [signingIn] turns a 401 into a wrong password rather than an
/// ended session.
NetworkFileSystemException jellyfinErrorOf(Object error, {bool signingIn = false}) => switch (error) {
  NetworkFileSystemException() => error,
  JellyfinHttpStatus(status: 401) => JellyfinException.of(
    signingIn ? JellyfinFailure.passwordRefused : JellyfinFailure.tokenRefused,
    status: 401,
  ),
  JellyfinHttpStatus(status: 403) => JellyfinException.of(JellyfinFailure.downloadForbidden, status: 403),
  JellyfinHttpStatus(:final status) => JellyfinException.of(JellyfinFailure.serverError, status: status),
  HandshakeException() || TlsException() => JellyfinException.of(JellyfinFailure.tlsRefused),
  FormatException() => JellyfinException.of(JellyfinFailure.serverError),
  SocketException() ||
  TimeoutException() ||
  HttpException() ||
  http.ClientException() => JellyfinException.of(JellyfinFailure.unreachable),
  _ => JellyfinException.of(JellyfinFailure.serverError),
};

/// A word for the logs about [error]: its type and status, never its message, which may hold an address
String jellyfinErrorKind(Object error) => switch (error) {
  JellyfinHttpStatus(:final status) => 'HTTP $status',
  JellyfinException(:final failure, :final status) => status == null ? failure.name : '${failure.name} $status',
  SocketException(:final osError) => 'socket error ${osError?.errorCode ?? ''}'.trim(),
  _ => error.runtimeType.toString(),
};

/// The value of the authorization header: Client, Device, DeviceId, Version, then Token when there is one
String jellyfinAuthorization({
  required String deviceId,
  required String deviceName,
  String? appVersion,
  String? token,
}) {
  String quoted(String value) => '"${value.replaceAll('"', "'")}"';
  return [
    'MediaBrowser Client=${quoted(jellyfinClientName)}',
    'Device=${quoted(deviceName)}',
    'DeviceId=${quoted(deviceId)}',
    'Version=${quoted(appVersion ?? '0')}',
    if (token != null && token.isNotEmpty) 'Token=${quoted(token)}',
  ].join(', ');
}

/// "Immuch360 Android", "Immuch360 iOS", "Immuch360 Windows": the platform only, never the user's device name
String jellyfinDeviceName() {
  final platform = switch (Platform.operatingSystem) {
    'ios' => 'iOS',
    'android' => 'Android',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    final other => other,
  };
  return '$jellyfinClientName $platform';
}

/// The requests to one server: [routes] build every URL, [_http] sends them (off the UI isolate in the app, see
/// IsolateHttpClient)
class JellyfinClient {
  JellyfinClient(
    this._http, {
    required this.routes,
    required this.deviceId,
    this.token,
    this.appVersion,
    String? deviceName,
    this.answerTimeout = defaultAnswerTimeout,
  }) : deviceName = deviceName ?? jellyfinDeviceName();

  final http.Client _http;

  /// The HTTP client the requests go through, for another client of the same server
  http.Client get httpClient => _http;

  final JellyfinRoutes routes;
  final String deviceId;
  final String deviceName;
  final String? appVersion;

  /// Null before a sign in
  String? token;

  final Duration answerTimeout;

  static const defaultAnswerTimeout = Duration(seconds: 30);

  /// Largest JSON answer read: a page of 200 items with their media sources takes well under 2 MiB
  static const maxJsonSize = 16 * 1024 * 1024;

  /// Largest picture read
  static const maxPictureSize = 8 * 1024 * 1024;

  /// Past this size, an answer is parsed in another isolate, away from the interface
  static const isolateParseSize = 256 * 1024;

  JellyfinProduct get product => routes.product;

  /// The headers of every request: the authorization of the product, the token when [withToken] and there is one
  Map<String, String> headers({bool withToken = true, String accept = 'application/json'}) {
    final sent = withToken ? token : null;
    final authorization = jellyfinAuthorization(
      deviceId: deviceId,
      deviceName: deviceName,
      appVersion: appVersion,
      token: sent,
    );
    return {
      'accept': accept,
      if (product == JellyfinProduct.emby) ...{
        'x-emby-authorization': authorization,
        if (sent != null && sent.isNotEmpty) 'x-emby-token': sent,
      } else
        'authorization': authorization,
    };
  }

  /// Sends one request to [uri], aborted when [abort] completes or when no answer comes within [timeout] (by default
  /// [answerTimeout]). A redirect is an error: its body is dropped and a [JellyfinHttpStatus] thrown.
  Future<http.StreamedResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? jsonBody,
    bool withToken = true,
    String accept = 'application/json',
    Future<void>? abort,
    Duration? timeout,
  }) async {
    final trigger = Completer<void>();
    void fire() {
      if (!trigger.isCompleted) {
        trigger.complete();
      }
    }

    var timedOut = false;
    final limit = timeout ?? answerTimeout;
    final timer = Timer(limit, () {
      timedOut = true;
      fire();
    });
    unawaited(abort?.whenComplete(fire));
    final request = http.AbortableRequest(method, uri, abortTrigger: trigger.future)
      ..followRedirects = false
      ..headers.addAll(this.headers(withToken: withToken, accept: accept))
      ..headers.addAll(headers);
    if (jsonBody != null) {
      request
        ..headers['content-type'] = 'application/json'
        ..bodyBytes = utf8.encode(jsonEncode(jsonBody));
    } else if (method == 'POST') {
      request.headers['content-length'] = '0';
    }
    final watch = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on http.RequestAbortedException {
      if (timedOut) {
        throw TimeoutException('No answer in time', limit);
      }
      throw const JellyfinRequestCancelled();
    } finally {
      timer.cancel();
    }
    final status = response.statusCode;
    _log.finest('$method ${_kindOfRoute(uri)}: $status in ${watch.elapsedMilliseconds} ms');
    if (status >= 300 && status < 400) {
      await discardHttpBody(response);
      throw JellyfinHttpStatus(status);
    }
    return response;
  }

  /// The JSON answer of [method] at [uri], parsed by [parse]; any status but 2xx throws a [JellyfinHttpStatus]
  Future<T> json<T>(
    String method,
    Uri uri,
    T Function(Object? json) parse, {
    Object? body,
    bool withToken = true,
    Future<void>? abort,
  }) async {
    final response = await send(method, uri, jsonBody: body, withToken: withToken, abort: abort);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await discardHttpBody(response);
      throw JellyfinHttpStatus(response.statusCode);
    }
    final bytes = await _body(response, maxJsonSize);
    if (bytes.isEmpty) {
      return parse(null);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.length > isolateParseSize ? await Isolate.run(() => parse(jsonDecode(text))) : parse(jsonDecode(text));
  }

  /// POSTs [body] to [uri] and drops the answer; any status but 2xx throws a [JellyfinHttpStatus]
  Future<void> post(Uri uri, {Object? body}) async {
    final response = await send('POST', uri, jsonBody: body);
    await discardHttpBody(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JellyfinHttpStatus(response.statusCode);
    }
  }

  /// The bytes at [uri]: null for a 404, a [JellyfinHttpStatus] for any other status but 200
  Future<Uint8List?> bytes(
    Uri uri, {
    String accept = 'image/*',
    int maxSize = maxPictureSize,
    Future<void>? abort,
  }) async {
    final response = await send('GET', uri, accept: accept, abort: abort);
    if (response.statusCode == 404) {
      await discardHttpBody(response);
      return null;
    }
    if (response.statusCode != 200) {
      await discardHttpBody(response);
      throw JellyfinHttpStatus(response.statusCode);
    }
    return _body(response, maxSize);
  }

  // The calls of the app

  /// GET /System/Info/Public without credential. Throws notJellyfin when the answer is not one of either product.
  Future<JellyfinPublicInfo> publicInfo() async {
    final JellyfinPublicInfo? info;
    try {
      info = await json('GET', routes.publicInfo(), JellyfinPublicInfo.parse, withToken: false);
    } on JellyfinHttpStatus catch (error) {
      if (error.status == 404 || error.status == 401 || error.status == 403) {
        throw JellyfinException.of(JellyfinFailure.notJellyfin, status: error.status);
      }
      rethrow;
    } on FormatException {
      throw JellyfinException.of(JellyfinFailure.notJellyfin);
    }
    if (info == null) {
      throw JellyfinException.of(JellyfinFailure.notJellyfin);
    }
    return info;
  }

  /// The users the server shows on its sign in page; none when it shows none or refuses
  Future<List<JellyfinPublicUser>> publicUsers() async {
    try {
      return await json('GET', routes.publicUsers(), JellyfinPublicUser.parseList, withToken: false);
    } on JellyfinHttpStatus {
      return const [];
    }
  }

  /// Signs in with [user] and [password]; the token is kept by this client. The password is sent once and kept
  /// nowhere.
  Future<JellyfinSignIn> signIn(String user, String password) async {
    final JellyfinSignIn? result;
    try {
      result = await json(
        'POST',
        routes.signIn(),
        JellyfinSignIn.parse,
        body: {'Username': user, 'Pw': password},
        withToken: false,
      );
    } on JellyfinHttpStatus catch (error) {
      throw jellyfinErrorOf(error, signingIn: true);
    }
    if (result == null) {
      throw JellyfinException.of(JellyfinFailure.serverError);
    }
    token = result.accessToken;
    return result;
  }

  /// Whether Quick Connect is on: false for Emby, which has none (404)
  Future<bool> quickConnectEnabled() async {
    if (product == JellyfinProduct.emby) {
      return false;
    }
    try {
      return await json('GET', routes.quickConnectEnabled(), (json) => json == true, withToken: false);
    } on JellyfinHttpStatus {
      return false;
    }
  }

  /// A new Quick Connect request. Throws quickConnectOff when the server refuses it.
  Future<JellyfinQuickConnect> quickConnectInitiate() async {
    if (product == JellyfinProduct.emby) {
      throw JellyfinException.of(JellyfinFailure.quickConnectOff);
    }
    final JellyfinQuickConnect? started;
    try {
      started = await json('POST', routes.quickConnectInitiate(), JellyfinQuickConnect.parse, withToken: false);
    } on JellyfinHttpStatus catch (error) {
      if (error.status == 401 || error.status == 403 || error.status == 404) {
        throw JellyfinException.of(JellyfinFailure.quickConnectOff, status: error.status);
      }
      rethrow;
    }
    if (started == null) {
      throw JellyfinException.of(JellyfinFailure.serverError);
    }
    return started;
  }

  /// Whether the request of [secret] was approved. Throws quickConnectExpired once the server forgot it (404).
  Future<bool> quickConnectApproved(String secret) async {
    try {
      final state = await json('GET', routes.quickConnectState(secret), JellyfinQuickConnect.parse, withToken: false);
      return state?.authenticated ?? false;
    } on JellyfinHttpStatus catch (error) {
      if (error.status == 404 || error.status == 400) {
        throw JellyfinException.of(JellyfinFailure.quickConnectExpired, status: error.status);
      }
      if (error.status == 401 || error.status == 403) {
        throw JellyfinException.of(JellyfinFailure.quickConnectOff, status: error.status);
      }
      rethrow;
    }
  }

  /// The token of an approved Quick Connect request
  Future<JellyfinSignIn> quickConnectSignIn(String secret) async {
    final JellyfinSignIn? result;
    try {
      result = await json(
        'POST',
        routes.quickConnectSignIn(),
        JellyfinSignIn.parse,
        body: {'Secret': secret},
        withToken: false,
      );
    } on JellyfinHttpStatus catch (error) {
      if (error.status == 404 || error.status == 400 || error.status == 401) {
        throw JellyfinException.of(JellyfinFailure.quickConnectExpired, status: error.status);
      }
      rethrow;
    }
    if (result == null) {
      throw JellyfinException.of(JellyfinFailure.serverError);
    }
    token = result.accessToken;
    return result;
  }

  /// The signed in user, which checks the token: tokenRefused when it is not good any more
  Future<JellyfinItem> me(String userId) async {
    try {
      final user = await json('GET', routes.me(userId), JellyfinItem.parse);
      if (user == null) {
        throw JellyfinException.of(JellyfinFailure.serverError);
      }
      return user;
    } on JellyfinHttpStatus catch (error) {
      throw jellyfinErrorOf(error);
    }
  }

  Future<List<JellyfinItem>> views(String userId) async =>
      (await json('GET', routes.views(userId), JellyfinItemsPage.parse)).items;

  Future<JellyfinItemsPage> items(
    String userId, {
    String? parentId,
    int? startIndex,
    int? limit,
    String? includeItemTypes,
    bool recursive = false,
  }) => json(
    'GET',
    routes.items(
      userId,
      parentId: parentId,
      startIndex: startIndex,
      limit: limit,
      includeItemTypes: includeItemTypes,
      recursive: recursive,
    ),
    JellyfinItemsPage.parse,
  );

  /// One item with its media sources
  Future<JellyfinItem> item(String userId, String itemId) async {
    final item = await json('GET', routes.item(userId, itemId), JellyfinItem.parse);
    if (item == null) {
      throw JellyfinException.of(JellyfinFailure.serverError);
    }
    return item;
  }

  Future<List<JellyfinItem>> seasons(String userId, String seriesId) async =>
      (await json('GET', routes.seasons(userId, seriesId), JellyfinItemsPage.parse)).items;

  Future<List<JellyfinItem>> episodes(String userId, String seriesId, {String? seasonId}) async =>
      (await json('GET', routes.episodes(userId, seriesId, seasonId: seasonId), JellyfinItemsPage.parse)).items;

  /// The next episode to watch of a series, null when the server has none
  Future<JellyfinItem?> nextUp(String userId, String seriesId) async =>
      (await json('GET', routes.nextUp(userId, seriesId), JellyfinItemsPage.parse)).items.firstOrNull;

  /// PlaybackInfo with [deviceProfile] (the server's conversion offer), for [mediaSourceId]
  Future<JellyfinPlaybackInfo> playbackInfo(
    String userId,
    String itemId, {
    String? mediaSourceId,
    Map<String, Object?>? deviceProfile,
    int? maxStreamingBitrate,
  }) => json(
    'POST',
    routes.playbackInfo(userId, itemId),
    JellyfinPlaybackInfo.parse,
    body: {
      'UserId': userId,
      'MediaSourceId': ?mediaSourceId,
      'DeviceProfile': ?deviceProfile,
      'MaxStreamingBitrate': ?maxStreamingBitrate,
      'EnableDirectPlay': deviceProfile == null,
      'EnableDirectStream': deviceProfile == null,
      'EnableTranscoding': true,
      'AutoOpenLiveStream': false,
    },
  );

  /// Sessions/Playing, Progress and Stopped: the place reached in [itemId], so that the server and its other apps
  /// resume there
  Future<void> report(
    JellyfinReport kind, {
    required String itemId,
    required String mediaSourceId,
    required int positionMs,
    required String playSessionId,
    bool paused = false,
    bool converted = false,
  }) => post(
    switch (kind) {
      JellyfinReport.start => routes.playing(),
      JellyfinReport.progress => routes.playingProgress(),
      JellyfinReport.stopped => routes.playingStopped(),
    },
    body: {
      'ItemId': itemId,
      'MediaSourceId': mediaSourceId,
      'PositionTicks': jellyfinMsToTicks(positionMs),
      'PlaySessionId': playSessionId,
      'PlayMethod': converted ? 'Transcode' : 'DirectPlay',
      'CanSeek': true,
      'IsPaused': paused,
    },
  );

  /// Ends the session of the token on the server (best effort: a failure is logged and dropped)
  Future<void> logout() async {
    try {
      await post(routes.logout());
    } catch (error) {
      _log.info('The server did not end the session: ${jellyfinErrorKind(error)}');
    }
  }

  void close() => _http.close();

  /// The body of [response], at most [maxSize] bytes, each part within [answerTimeout]
  Future<Uint8List> _body(http.StreamedResponse response, int maxSize) async {
    final declared = response.contentLength;
    if (declared != null && declared > maxSize) {
      await response.stream.listen(null).cancel();
      throw JellyfinException.of(JellyfinFailure.serverError);
    }
    final body = BytesBuilder(copy: false);
    final chunks = StreamIterator(response.stream);
    try {
      while (await chunks.moveNext().timeout(answerTimeout)) {
        body.add(chunks.current);
        if (body.length > maxSize) {
          throw JellyfinException.of(JellyfinFailure.serverError);
        }
      }
      return body.takeBytes();
    } finally {
      chunks.cancel().ignore();
    }
  }

  /// The kind of a request for the logs: the first segment of its path past the base, never an id or a query
  String _kindOfRoute(Uri uri) {
    final path = uri.path.substring(min(routes.base.path.length, uri.path.length));
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return '/';
    }
    final first = segments.first;
    final last = segments.length > 1 && !RegExp(r'^[0-9a-fA-F-]{6,}$|^\d+$').hasMatch(segments.last)
        ? '/${segments.last}'
        : '';
    return '$first$last';
  }
}

/// The three playback reports, see [JellyfinClient.report]
enum JellyfinReport { start, progress, stopped }

/// The id of this install for the DeviceId of the requests (StoreKey.jellyfinDeviceId): 32 hex digits made on first
/// use and kept, never exported. A new one each time when the Store is not there.
Future<String> jellyfinInstallId({StoreService? store}) async {
  StoreService? service = store;
  if (service == null) {
    try {
      service = StoreService.I;
    } on UnsupportedError {
      service = null;
    }
  }
  final known = service?.tryGet(StoreKey.jellyfinDeviceId);
  if (known != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(known)) {
    return known;
  }
  final random = Random.secure();
  final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  try {
    await service?.put(StoreKey.jellyfinDeviceId, id);
  } catch (error) {
    _log.fine('The install id could not be kept: ${jellyfinErrorKind(error)}');
  }
  return id;
}

/// The DeviceId of the requests for the source [sourceId]: the install's id, then the first 8 characters of the
/// source id
String jellyfinDeviceIdOf(String installId, String sourceId) {
  final start = sourceId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  return '$installId-${start.substring(0, min(8, start.length))}';
}
