// The HTTP stack of the computers. The phones hand a native client (OkHttp, URLSession) to Dart through NetworkApi;
// no such client exists for Windows, Linux or macOS, so the computers keep one dart:io stack that reproduces what the
// native clients do for the app (HttpClientManager.kt and URLSessionManager.swift, the contract pinned by the tests
// of test/desktop/network):
// - the custom headers of the settings on every request, and the app's own User-Agent;
// - the cookies the server sets, the session ones copied to every address of the user's server (desktop_cookie_jar);
// - Basic authentication from a user name and password written in the server address;
// - the client certificate (mTLS), imported from a PKCS#12 file, and the certificates the user trusts;
// - the timeouts of the OkHttp configuration: 30 s to connect, 60 s without progress while sending or receiving;
// - websockets for socket.io;
// - all of it kept between two starts (flutter_secure_storage, DPAPI on Windows), as the native clients keep it in
//   SharedPreferences, the Android KeyStore, UserDefaults and the Keychain;
// - and handed to the desktop transfers of the vendored background_downloader, which build their own client.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/desktop/network/desktop_cookie_jar.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart';

final _log = Logger('DesktopHttpStack');

/// The client certificate of the user's server, as imported
@immutable
class ClientCertificate {
  const ClientCertificate(this.pkcs12, this.password);

  final Uint8List pkcs12;
  final String password;
}

class DesktopHttpStack {
  /// [global]: the stack of the app, which also gives the trusted certificates to every other HttpClient of its
  /// isolate and its TLS material and cookies to the desktop transfers. The tests make stacks that touch neither.
  DesktopHttpStack({
    SecureStorageRepository? secrets,
    TrustedCertificates? trustedCertificates,
    Future<String?> Function()? userAgent,
    DateTime Function()? clock,
    this.connectTimeout = const Duration(seconds: 30),
    this.readTimeout = const Duration(seconds: 60),
    this.writeTimeout = const Duration(seconds: 60),
    this.global = false,
  }) : _secrets = secrets ?? const SecureStorageRepository(FlutterSecureStorage()),
       _trusted = trustedCertificates ?? TrustedCertificates.instance,
       _readUserAgent = userAgent ?? _appUserAgent,
       _jar = DesktopCookieJar(clock: clock);

  /// One stack for the app, as there is one native client on the phones. Each isolate that starts the app's domain
  /// (Bootstrap.initDomain) has its own, read from what the stack saved.
  static final instance = DesktopHttpStack(global: true);

  /// Where the stack keeps the custom headers, the server addresses and the cookies
  static const sessionKey = 'immuch360_desktop_http_session';

  /// Where the stack keeps the client certificate
  static const clientCertificateKey = 'immuch360_desktop_client_certificate';

  /// OkHttpClientConfiguration of NetworkRepository: connect 30 s, read 60 s, write 60 s
  final Duration connectTimeout;
  final Duration readTimeout;
  final Duration writeTimeout;

  /// maxRequestsPerHost of HttpClientManager.kt, httpMaximumConnectionsPerHost of URLSessionManager.swift
  static const maxConnectionsPerHost = 64;

  final bool global;
  final SecureStorageRepository _secrets;
  final TrustedCertificates _trusted;
  final Future<String?> Function() _readUserAgent;
  final DesktopCookieJar _jar;

  Map<String, String> _headers = const {};
  ClientCertificate? _clientCertificate;
  String? _userAgent;
  io.SecurityContext? _context;
  bool _contextBuilt = false;
  io.HttpClient? _io;
  IOClient? _ioClient;
  Future<void>? _initialized;
  Future<void> _saving = Future.value();

  /// The client every request of the app goes through. It stays the same object for the life of the app, as callers
  /// keep it (ApiService, the probes); a change of certificates only replaces the connections under it.
  late final http.Client client = _DesktopClient(this);

  /// The custom headers of the settings
  Map<String, String> get customHeaders => _headers;

  bool get hasClientCertificate => _clientCertificate != null;

  /// Reads what the stack saved, once; later calls wait for the first one, like NetworkRepository.init with an
  /// unchanged native pointer. Never fails: what cannot be read is logged and the stack starts without it.
  Future<void> init() => _initialized ??= _init();

  Future<void> _init() async {
    await _trusted.load();
    _trusted.addListener(_securityChanged);
    if (global) {
      io.HttpOverrides.global = DesktopHttpOverrides(_trusted);
    }
    await _restoreSession();
    await _restoreClientCertificate();
    try {
      _userAgent = await _readUserAgent();
    } catch (error) {
      _log.warning('No User-Agent for the app: $error');
    }
    _securityChanged();
  }

  /// What NetworkApi.setRequestHeaders gives the native clients: [headers] go with every request of [client], the
  /// cookies of the session follow every address of [serverUrls], and [token], when given (a sign in carried over
  /// from an older version of the app), becomes the session cookies of those addresses
  Future<void> setRequestHeaders(Map<String, String> headers, List<String> serverUrls, String? token) async {
    _headers = Map.unmodifiable(headers);
    _jar.setServerUrls(_parseUrls(serverUrls));
    if (token != null) {
      _jar.setToken(token);
    }
    _updateTransfers();
    await _saveSession();
  }

  /// Forgets the session cookies, as the logout of the server does by expiring them
  Future<void> clearToken() async {
    if (_jar.clearAuthCookies()) {
      await _saveSession();
    }
  }

  /// What a request to [url] made outside [client] needs to be accepted by the user's server, as getAuthHeaders of
  /// HttpClientManager.kt gives the players and the image fetcher: the custom headers, the cookies of [url], and
  /// Basic authentication when [url] carries a user name
  Map<String, String> headersFor(Uri url) {
    final userInfo = url.userInfo;
    return {..._headersOf(url), if (userInfo.isNotEmpty) 'authorization': _basic(userInfo)};
  }

  /// The custom headers and the cookies of [url]
  Map<String, String> _headersOf(Uri url) {
    final cookie = _jar.cookieHeaderFor(url);
    return {..._headers, 'cookie': ?cookie};
  }

  /// Checks a PKCS#12 file and its password, keeps them, and uses them from the next connection on. Throws a
  /// [io.TlsException] when the file or the password is wrong, keeping the previous certificate.
  Future<void> setClientCertificate(Uint8List pkcs12, String password) async {
    final certificate = ClientCertificate(Uint8List.fromList(pkcs12), password);
    _contextWith(certificate);
    await _secrets.write(
      clientCertificateKey,
      jsonEncode({'pkcs12': base64.encode(certificate.pkcs12), 'password': password}),
    );
    _clientCertificate = certificate;
    _securityChanged();
  }

  Future<void> removeClientCertificate() async {
    await _secrets.delete(clientCertificateKey);
    _clientCertificate = null;
    _securityChanged();
  }

  /// A websocket for socket.io, with the custom headers and the cookies of [uri]'s server; dart:io adds Basic
  /// authentication itself from a user name in [uri]
  Future<WebSocket> createWebSocket(Uri uri, {Map<String, String>? headers, Iterable<String>? protocols}) async {
    return IOWebSocket.fromWebSocket(
      await io.WebSocket.connect(
        uri.toString(),
        protocols: protocols,
        headers: {..._headersOf(uri), ...?headers},
        customClient: _httpClient(),
      ),
    );
  }

  /// The context of the stack's connections: the system's roots, the trusted certificates and the client
  /// certificate; null while there is nothing to add to dart:io's default context
  io.SecurityContext? get securityContext {
    if (!_contextBuilt) {
      _context = _contextWith(_clientCertificate);
      _contextBuilt = true;
    }
    return _context;
  }

  io.SecurityContext? _contextWith(ClientCertificate? certificate) {
    if (certificate == null) {
      return _trusted.context;
    }
    return _trusted.newContext()
      ..useCertificateChainBytes(certificate.pkcs12, password: certificate.password)
      ..usePrivateKeyBytes(certificate.pkcs12, password: certificate.password);
  }

  io.HttpClient _httpClient() {
    final existing = _io;
    if (existing != null) {
      return existing;
    }
    final made = io.HttpClient(context: securityContext)
      ..connectionTimeout = connectTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost;
    final userAgent = _userAgent;
    if (userAgent != null) {
      made.userAgent = userAgent;
    }
    return _io = made;
  }

  IOClient _inner() => _ioClient ??= IOClient(_httpClient());

  /// The certificates changed: the next requests open new connections with the new context, while the ones running
  /// end on the old connections, as the native clients rebuild their client and let the old one drain
  void _securityChanged() {
    _contextBuilt = false;
    _context = null;
    final previous = _io;
    _io = null;
    _ioClient = null;
    previous?.close();
    _updateTransfers();
  }

  void _updateTransfers() {
    if (!global) {
      return;
    }
    final certificate = _clientCertificate;
    configureDesktopTransfers(
      security: DesktopTransferSecurity(
        trustedCertificates: [for (final trusted in _trusted.certificates) utf8.encode(trusted.pem)],
        clientCertificate: certificate?.pkcs12,
        clientCertificatePassword: certificate?.password,
      ),
      // The tasks carry the custom headers themselves (ApiService.getRequestHeaders), not the cookies
      headersFor: (url) {
        final cookie = _jar.cookieHeaderFor(url);
        return cookie == null ? const {} : {'cookie': cookie};
      },
    );
  }

  void _saveCookies(Uri url, http.BaseResponse response) {
    final values = response.headersSplitValues['set-cookie'];
    if (values == null) {
      return;
    }
    final cookies = <io.Cookie>[];
    for (final value in values) {
      try {
        cookies.add(io.Cookie.fromSetCookieValue(value));
      } on FormatException {
        // dart:io refuses some values the native jars take; such a cookie is not one of Immich's
        continue;
      }
    }
    if (_jar.saveFromResponse(url, cookies)) {
      unawaited(_saveSession());
    }
  }

  /// Writes are chained so that the last state always wins
  Future<void> _saveSession() {
    return _saving = _saving.then((_) async {
      try {
        await _secrets.write(
          sessionKey,
          jsonEncode({
            'headers': _headers,
            'serverUrls': [for (final url in _jar.serverUrls) url.toString()],
            'cookies': _jar.toJson(),
          }),
        );
      } catch (error, stack) {
        _log.warning('Could not save the session of the HTTP stack', error, stack);
      }
    });
  }

  Future<void> _restoreSession() async {
    try {
      final saved = await _secrets.read(sessionKey);
      if (saved == null) {
        return;
      }
      final json = jsonDecode(saved);
      if (json case {'headers': final Map<String, dynamic> headers, 'serverUrls': final List<dynamic> urls}) {
        _headers = Map.unmodifiable({
          for (final MapEntry(:key, :value) in headers.entries)
            if (value is String) key: value,
        });
        _jar.restore(json['cookies']);
        _jar.setServerUrls(_parseUrls(urls.whereType<String>()));
      }
    } catch (error, stack) {
      _log.warning('Could not read the session of the HTTP stack', error, stack);
    }
  }

  Future<void> _restoreClientCertificate() async {
    try {
      final saved = await _secrets.read(clientCertificateKey);
      if (saved == null) {
        return;
      }
      if (jsonDecode(saved) case {'pkcs12': final String pkcs12, 'password': final String password}) {
        final certificate = ClientCertificate(base64.decode(pkcs12), password);
        _contextWith(certificate);
        _clientCertificate = certificate;
      }
    } catch (error, stack) {
      _log.warning('Could not use the saved client certificate', error, stack);
    }
  }

  static List<Uri> _parseUrls(Iterable<String> urls) => [
    for (final url in urls)
      if (Uri.tryParse(url) case final uri? when uri.hasAuthority && uri.host.isNotEmpty) uri,
  ];

  /// Basic authentication of a user name and password written in an address, decoded as OkHttp's HttpUrl does
  static String _basic(String userInfo) {
    final separator = userInfo.indexOf(':');
    final user = Uri.decodeComponent(separator < 0 ? userInfo : userInfo.substring(0, separator));
    final password = separator < 0 ? '' : Uri.decodeComponent(userInfo.substring(separator + 1));
    return 'Basic ${base64.encode(utf8.encode('$user:$password'))}';
  }

  /// `immich-android/<version>` and `immich-ios/<version>` on the phones; the server reads the version of the app
  /// from that pattern for its list of sessions, and "unknown" is the third platform it knows
  static Future<String?> _appUserAgent() async => 'immich-unknown/${(await PackageInfo.fromPlatform()).version}';
}

/// The client of the stack: adds what the native clients add, sends through the connections of the moment with the
/// timeouts, and keeps the cookies of the answers
class _DesktopClient extends http.BaseClient {
  _DesktopClient(this._stack);

  final DesktopHttpStack _stack;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // A header the request sets itself wins, as with URLSession's additional headers. The Basic authentication of a
    // user name in the address replaces the one dart:io would make, which keeps the percent escapes of the address
    // where OkHttp decodes them.
    for (final MapEntry(:key, :value) in _stack.headersFor(request.url).entries) {
      request.headers.putIfAbsent(key, () => value);
    }
    final response = await _sendWithTimeouts(request);
    _stack._saveCookies(response.url, response);
    return response;
  }

  /// The body goes through a watched stream that keeps dart:io's back pressure: no chunk taken for [writeTimeout]
  /// while sending, no answer [readTimeout] after the last byte was sent, or no chunk of the answer for [readTimeout]
  /// while it is read, and the request is aborted with a ClientException, as OkHttp's timeouts end a call
  Future<_TimedResponse> _sendWithTimeouts(http.BaseRequest request) async {
    final stalled = Completer<void>();
    String? stallReason;
    var abortedByCaller = false;
    var answered = false;
    Timer? timer;
    void stall(String reason) {
      if (!stalled.isCompleted) {
        stallReason = reason;
        stalled.complete();
      }
    }

    // A server may answer before it took the whole body (a refused upload); the body still flowing after that must
    // not arm a timer that would abort the answer being read
    void arm(Duration limit, String reason) {
      if (answered) {
        return;
      }
      timer?.cancel();
      timer = Timer(limit, () => stall(reason));
    }

    final callerTrigger = request is http.Abortable ? request.abortTrigger : null;
    // A trigger that fails aborts as well (package:http); its error stays the caller's, not an uncaught one here
    unawaited(callerTrigger?.then((_) => abortedByCaller = true, onError: (Object _) => abortedByCaller = true));

    final body = request.finalize().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          arm(_stack.writeTimeout, 'Write timed out');
          sink.add(chunk);
        },
        handleDone: (sink) {
          arm(_stack.readTimeout, 'Read timed out');
          sink.close();
        },
      ),
    );
    final forwarded =
        _ForwardedRequest(
            request.method,
            request.url,
            body,
            abortTrigger: callerTrigger == null ? stalled.future : Future.any([stalled.future, callerTrigger]),
          )
          ..headers.addAll(request.headers)
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection
          ..contentLength = request.contentLength;

    final http.StreamedResponse response;
    try {
      response = await _stack._inner().send(forwarded);
    } on http.RequestAbortedException {
      final reason = stallReason;
      if (reason != null && !abortedByCaller) {
        throw http.ClientException(reason, request.url);
      }
      rethrow;
    } finally {
      answered = true;
      timer?.cancel();
    }
    return _TimedResponse(
      _readTimeout(response.stream, request.url, () => stall('Read timed out')),
      response,
      switch (response) {
        http.BaseResponseWithUrl(:final url) => url,
        _ => request.url,
      },
    );
  }

  Stream<List<int>> _readTimeout(Stream<List<int>> source, Uri url, void Function() onStall) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    void arm() {
      timer?.cancel();
      timer = Timer(_stack.readTimeout, () {
        controller.addError(http.ClientException('Read timed out', url));
        unawaited(subscription?.cancel());
        subscription = null;
        onStall();
        unawaited(controller.close());
      });
    }

    controller = StreamController<List<int>>(
      onListen: () {
        arm();
        subscription = source.listen(
          (chunk) {
            arm();
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: () {
            timer?.cancel();
            subscription = null;
            unawaited(controller.close());
          },
        );
      },
      // A reader that pauses is not a stalled server
      onPause: () {
        timer?.cancel();
        subscription?.pause();
      },
      onResume: () {
        arm();
        subscription?.resume();
      },
      onCancel: () {
        timer?.cancel();
        final cancelled = subscription?.cancel();
        subscription = null;
        return cancelled;
      },
    );
    return controller.stream;
  }

  /// The client lives as long as the app, like the native client the phones share; closing it would end every later
  /// request of the app
  @override
  void close() {}
}

/// The request as sent by dart:io, its body being the watched stream of the original
class _ForwardedRequest extends http.BaseRequest with http.Abortable {
  _ForwardedRequest(super.method, super.url, this._body, {this.abortTrigger});

  final Stream<List<int>> _body;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}

class _TimedResponse extends http.StreamedResponse implements http.BaseResponseWithUrl {
  _TimedResponse(Stream<List<int>> stream, http.StreamedResponse response, this.url)
    : super(
        stream,
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );

  @override
  final Uri url;
}
