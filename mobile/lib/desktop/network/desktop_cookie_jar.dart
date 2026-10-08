// The cookies of the computers' HTTP stack. The sign in of the app rests on cookies: the server answers /auth/login
// with immich_access_token, immich_is_authenticated and immich_auth_type, and the phones' native clients keep them
// (the PersistentCookieJar of HttpClientManager.kt, the shared HTTPCookieStorage of URLSessionManager.swift) for every
// later request, websocket and transfer; the Dart side never sends the token itself. dart:io has no cookie jar, so the
// desktop stack keeps this one, with the rules of RFC 6265 the native jars follow (host and domain, path, expiry,
// Secure only over TLS) and the fork's own rule of the native jars: the three session cookies are copied to every
// address of the user's server, so that switching between its local and its external address keeps the session.

import 'dart:io';

/// One cookie as the jar keeps it, also its persisted form
class StoredCookie {
  const StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    required this.expiresAt,
    required this.secure,
    required this.httpOnly,
  });

  final String name;
  final String value;

  /// A host name in lower case, without a leading dot
  final String domain;

  /// True when the server gave no Domain attribute: the cookie goes back to that exact host only
  final bool hostOnly;
  final String path;

  /// Null for a cookie of the session, which a native jar keeps until it is replaced
  final DateTime? expiresAt;
  final bool secure;
  final bool httpOnly;

  bool isExpired(DateTime now) {
    final expiresAt = this.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(now);
  }

  bool sameSlot(StoredCookie other) => name == other.name && domain == other.domain && path == other.path;

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'hostOnly': hostOnly,
    'path': path,
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
    'secure': secure,
    'httpOnly': httpOnly,
  };

  static StoredCookie? fromJson(Object? json) {
    if (json case {
      'name': final String name,
      'value': final String value,
      'domain': final String domain,
      'hostOnly': final bool hostOnly,
      'path': final String path,
      'secure': final bool secure,
      'httpOnly': final bool httpOnly,
    }) {
      final expiresAt = json['expiresAt'];
      return StoredCookie(
        name: name,
        value: value,
        domain: domain,
        hostOnly: hostOnly,
        path: path,
        expiresAt: expiresAt is int ? DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true) : null,
        secure: secure,
        httpOnly: httpOnly,
      );
    }
    return null;
  }
}

class DesktopCookieJar {
  DesktopCookieJar({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The cookies of an Immich session (AuthCookie in HttpClientManager.kt and URLSessionManager.swift)
  static const authCookieNames = {'immich_access_token', 'immich_is_authenticated', 'immich_auth_type'};

  /// immich_is_authenticated is read by the web pages, the two others are not
  static const _httpOnlyAuthCookies = {'immich_access_token', 'immich_auth_type'};

  /// The lifetime the native clients give the session cookies they make from a token (COOKIE_EXPIRY_DAYS)
  static const authCookieLifetime = Duration(days: 400);

  final DateTime Function() _clock;
  final List<StoredCookie> _store = [];
  List<Uri> _serverUrls = const [];

  List<StoredCookie> get cookies => List.unmodifiable(_store);

  List<Uri> get serverUrls => _serverUrls;

  Set<String> get _serverHosts => {for (final url in _serverUrls) url.host.toLowerCase()};

  /// Keeps the cookies [url] answered with; true when the jar changed, so that the caller saves it
  bool saveFromResponse(Uri url, Iterable<Cookie> cookies) {
    final now = _clock();
    final hosts = _serverHosts;
    final fromServer = hosts.contains(url.host.toLowerCase());
    var changed = false;
    for (final cookie in cookies) {
      final stored = _fromResponse(url, cookie, now);
      if (stored == null) {
        continue;
      }
      final before = _store.length;
      final same = _store.where((existing) => existing.sameSlot(stored)).toList();
      _store.removeWhere((existing) => existing.sameSlot(stored));
      if (stored.isExpired(now)) {
        // An expired cookie is how a server deletes one; the logout does it for the session cookies, which then go
        // from every address of the server. The native jars copy them back from another address instead, which the
        // revoked session makes harmless there; here the session simply ends everywhere.
        if (fromServer && authCookieNames.contains(stored.name)) {
          _store.removeWhere((existing) => existing.name == stored.name && hosts.contains(existing.domain));
        }
        changed |= _store.length != before;
        continue;
      }
      changed |= same.length != 1 || same.single.value != stored.value || same.single.expiresAt != stored.expiresAt;
      _store.add(stored);
    }
    if (fromServer) {
      changed |= _syncAuthCookies(now);
    }
    return changed;
  }

  /// The addresses of the user's server (its external address, the local one and the others of the settings);
  /// true when the jar changed
  bool setServerUrls(List<Uri> urls) {
    final hosts = [for (final url in urls) url.host.toLowerCase()];
    if (hosts.length == _serverUrls.length &&
        hosts.every(_serverHosts.contains) &&
        _serverHosts.every(hosts.contains)) {
      _serverUrls = urls;
      return false;
    }
    _serverUrls = urls;
    return _syncAuthCookies(_clock());
  }

  /// The session cookies of [token] for the first server address, then copied to the others, as
  /// HttpClientManager.setRequestHeaders does when the Dart side hands a token over (a migrated sign in)
  bool setToken(String token) {
    final url = _serverUrls.firstOrNull;
    if (url == null) {
      return false;
    }
    final expiresAt = _clock().add(authCookieLifetime);
    final values = {'immich_access_token': token, 'immich_is_authenticated': 'true', 'immich_auth_type': 'password'};
    final made = [
      for (final MapEntry(key: name, :value) in values.entries)
        StoredCookie(
          name: name,
          value: value,
          domain: url.host.toLowerCase(),
          hostOnly: true,
          path: '/',
          expiresAt: expiresAt,
          secure: _isSecure(url),
          httpOnly: _httpOnlyAuthCookies.contains(name),
        ),
    ];
    for (final cookie in made) {
      _store.removeWhere((existing) => existing.sameSlot(cookie));
      _store.add(cookie);
    }
    _syncAuthCookies(_clock());
    return true;
  }

  /// Forgets the session cookies everywhere; true when there were some
  bool clearAuthCookies() {
    final before = _store.length;
    _store.removeWhere((cookie) => authCookieNames.contains(cookie.name));
    return _store.length != before;
  }

  /// The cookies [url] gets, longest paths first as RFC 6265 asks
  List<StoredCookie> loadForRequest(Uri url) {
    final now = _clock();
    if (_store.any((cookie) => cookie.isExpired(now))) {
      _store.removeWhere((cookie) => cookie.isExpired(now));
      _syncAuthCookies(now);
    }
    final host = url.host.toLowerCase();
    final path = url.path.isEmpty ? '/' : url.path;
    final secure = _isSecure(url);
    return [
      for (final cookie in _store)
        if ((cookie.hostOnly ? cookie.domain == host : _domainMatches(host, cookie.domain)) &&
            _pathMatches(path, cookie.path) &&
            (!cookie.secure || secure))
          cookie,
    ]..sort((a, b) => b.path.length.compareTo(a.path.length));
  }

  /// The Cookie header of [url], null when it gets none
  String? cookieHeaderFor(Uri url) {
    final cookies = loadForRequest(url);
    return cookies.isEmpty ? null : cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  List<Map<String, Object?>> toJson() => [for (final cookie in _store) cookie.toJson()];

  /// Puts back what [toJson] gave, without what expired since
  void restore(Object? json) {
    _store.clear();
    if (json is! List) {
      return;
    }
    final now = _clock();
    for (final item in json) {
      final cookie = StoredCookie.fromJson(item);
      if (cookie != null && !cookie.isExpired(now)) {
        _store.add(cookie);
      }
    }
  }

  /// Copies the live session cookies found on one server address to the others, or removes them from all when none
  /// is left (syncAuthCookies of HttpClientManager.kt); true when the jar changed
  bool _syncAuthCookies(DateTime now) {
    final hosts = _serverHosts;
    if (hosts.isEmpty) {
      return false;
    }
    // The last one wins, as the newest cookies are added at the end
    final sources = <String, StoredCookie>{
      for (final cookie in _store)
        if (authCookieNames.contains(cookie.name) && hosts.contains(cookie.domain) && !cookie.isExpired(now))
          cookie.name: cookie,
    };
    if (sources.isEmpty) {
      final before = _store.length;
      _store.removeWhere((cookie) => authCookieNames.contains(cookie.name) && hosts.contains(cookie.domain));
      return _store.length != before;
    }
    var changed = false;
    for (final url in _serverUrls) {
      final host = url.host.toLowerCase();
      for (final source in sources.values) {
        if (_store.any(
          (cookie) => cookie.name == source.name && cookie.domain == host && cookie.value == source.value,
        )) {
          continue;
        }
        _store.removeWhere((cookie) => cookie.name == source.name && cookie.domain == host);
        _store.add(
          StoredCookie(
            name: source.name,
            value: source.value,
            domain: host,
            hostOnly: true,
            path: '/',
            expiresAt: source.expiresAt,
            secure: _isSecure(url),
            httpOnly: source.httpOnly,
          ),
        );
        changed = true;
      }
    }
    return changed;
  }

  /// The cookie a Set-Cookie of [url] makes, null when RFC 6265 says to ignore it (a Domain that is not the host's)
  static StoredCookie? _fromResponse(Uri url, Cookie cookie, DateTime now) {
    final host = url.host.toLowerCase();
    var domain = cookie.domain?.toLowerCase();
    if (domain != null && domain.startsWith('.')) {
      domain = domain.substring(1);
    }
    final hostOnly = domain == null || domain.isEmpty;
    if (!hostOnly && !_domainMatches(host, domain)) {
      return null;
    }
    final maxAge = cookie.maxAge;
    final expiresAt = maxAge != null ? now.add(Duration(seconds: maxAge)) : cookie.expires;
    final path = cookie.path;
    return StoredCookie(
      name: cookie.name,
      value: cookie.value,
      domain: hostOnly ? host : domain,
      hostOnly: hostOnly,
      path: path != null && path.startsWith('/') ? path : _defaultPath(url),
      expiresAt: expiresAt,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
    );
  }

  static bool _isSecure(Uri url) => url.scheme == 'https' || url.scheme == 'wss';

  /// RFC 6265 5.1.3: the host is the domain or one of its sub domains, never for an IP address
  static bool _domainMatches(String host, String domain) {
    if (host == domain) {
      return true;
    }
    return host.endsWith('.$domain') && InternetAddress.tryParse(host) == null;
  }

  /// RFC 6265 5.1.4
  static bool _pathMatches(String requestPath, String cookiePath) {
    if (requestPath == cookiePath) {
      return true;
    }
    if (!requestPath.startsWith(cookiePath)) {
      return false;
    }
    return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
  }

  /// RFC 6265 5.1.4: the folder of the request's path
  static String _defaultPath(Uri url) {
    final path = url.path;
    if (path.isEmpty || !path.startsWith('/')) {
      return '/';
    }
    final last = path.lastIndexOf('/');
    return last <= 0 ? '/' : path.substring(0, last);
  }
}
