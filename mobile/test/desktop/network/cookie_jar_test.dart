// The cookie rules of the desktop stack, against what the native jars do (PersistentCookieJar of
// HttpClientManager.kt, the shared HTTPCookieStorage of URLSessionManager.swift). Addresses are of the documentation
// ranges (RFC 2606, RFC 5737).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/desktop_cookie_jar.dart';

void main() {
  var now = DateTime.utc(2026, 10, 8, 12);
  late DesktopCookieJar jar;

  final external = Uri.parse('https://photos.example.test/api');
  final local = Uri.parse('http://192.0.2.10:2283/api');

  Cookie setCookie(String value) => Cookie.fromSetCookieValue(value);

  setUp(() {
    now = DateTime.utc(2026, 10, 8, 12);
    jar = DesktopCookieJar(clock: () => now);
  });

  group('what the server sets', () {
    test('a host only cookie goes back to its host only', () {
      jar.saveFromResponse(external, [setCookie('a=1; Path=/')]);
      expect(jar.cookieHeaderFor(Uri.parse('https://photos.example.test/api/users/me')), 'a=1');
      expect(jar.cookieHeaderFor(Uri.parse('https://sub.photos.example.test/')), isNull);
      expect(jar.cookieHeaderFor(Uri.parse('https://example.test/')), isNull);
    });

    test('a Domain cookie goes to its sub domains, a foreign Domain is refused', () {
      jar.saveFromResponse(external, [
        setCookie('a=1; Domain=.example.test; Path=/'),
        setCookie('b=2; Domain=other.test'),
      ]);
      expect(jar.cookieHeaderFor(Uri.parse('https://cdn.example.test/')), 'a=1');
      expect(jar.cookies.map((c) => c.name), ['a']);
    });

    test('paths match as RFC 6265 says, the longest first', () {
      jar.saveFromResponse(Uri.parse('https://photos.example.test/api/auth/login'), [
        setCookie('root=1; Path=/'),
        setCookie('api=2; Path=/api'),
        setCookie('folder=3'),
      ]);
      // No Path: the folder of the request, /api/auth
      expect(jar.cookieHeaderFor(Uri.parse('https://photos.example.test/api/auth/x')), 'folder=3; api=2; root=1');
      expect(jar.cookieHeaderFor(Uri.parse('https://photos.example.test/apix')), 'root=1');
      expect(jar.cookieHeaderFor(Uri.parse('https://photos.example.test/')), 'root=1');
    });

    test('a Secure cookie never goes over plain HTTP, also for websockets', () {
      jar.saveFromResponse(external, [setCookie('s=1; Path=/; Secure')]);
      expect(jar.cookieHeaderFor(Uri.parse('http://photos.example.test/')), isNull);
      expect(jar.cookieHeaderFor(Uri.parse('wss://photos.example.test/api/socket.io/')), 's=1');
      expect(jar.cookieHeaderFor(Uri.parse('ws://photos.example.test/api/socket.io/')), isNull);
    });

    test('Max-Age wins over Expires, an expired cookie deletes the stored one', () {
      jar.saveFromResponse(external, [setCookie('a=1; Path=/; Max-Age=60; Expires=Wed, 01 Jan 2031 00:00:00 GMT')]);
      expect(jar.cookies.single.expiresAt, now.add(const Duration(seconds: 60)));
      now = now.add(const Duration(seconds: 61));
      expect(jar.cookieHeaderFor(external), isNull);

      jar.saveFromResponse(external, [setCookie('b=1; Path=/')]);
      expect(jar.saveFromResponse(external, [setCookie('b=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT')]), isTrue);
      expect(jar.cookies, isEmpty);
    });

    test('saving the same cookie again is not a change, a new value is', () {
      expect(jar.saveFromResponse(external, [setCookie('a=1; Path=/')]), isTrue);
      expect(jar.saveFromResponse(external, [setCookie('a=1; Path=/')]), isFalse);
      expect(jar.saveFromResponse(external, [setCookie('a=2; Path=/')]), isTrue);
      expect(jar.cookieHeaderFor(external), 'a=2');
    });
  });

  group('the session of the user\'s server', () {
    const login = [
      'immich_access_token=T1; Path=/; Max-Age=34560000; HttpOnly; SameSite=Lax',
      'immich_auth_type=password; Path=/; Max-Age=34560000; HttpOnly; SameSite=Lax',
      'immich_is_authenticated=true; Path=/; Max-Age=34560000; SameSite=Lax',
    ];

    test('the session cookies of one address are copied to the others (local and external)', () {
      jar.setServerUrls([external, local]);
      jar.saveFromResponse(external, [for (final value in login) setCookie(value)]);
      expect(
        jar.cookieHeaderFor(Uri.parse('http://192.0.2.10:2283/api/assets')),
        allOf(contains('immich_access_token=T1'), contains('immich_auth_type=password')),
      );
      // The copies are Secure only on HTTPS addresses, as rebuildCookie does
      expect(jar.cookies.where((c) => c.domain == '192.0.2.10').every((c) => !c.secure), isTrue);
      expect(jar.cookies.where((c) => c.domain == 'photos.example.test').any((c) => c.httpOnly), isTrue);
    });

    test('an address added later gets the session at once', () {
      jar.setServerUrls([external]);
      jar.saveFromResponse(external, [for (final value in login) setCookie(value)]);
      expect(jar.cookieHeaderFor(local), isNull);
      expect(jar.setServerUrls([external, local]), isTrue);
      expect(jar.cookieHeaderFor(local), contains('immich_access_token=T1'));
    });

    test('a new sign in on one address replaces the session on all', () {
      jar.setServerUrls([external, local]);
      jar.saveFromResponse(external, [for (final value in login) setCookie(value)]);
      jar.saveFromResponse(local, [setCookie('immich_access_token=T2; Path=/; Max-Age=34560000; HttpOnly')]);
      expect(jar.cookieHeaderFor(external), contains('immich_access_token=T2'));
      expect(jar.cookieHeaderFor(local), contains('immich_access_token=T2'));
    });

    test('the logout clears the session on every address', () {
      jar.setServerUrls([external, local]);
      jar.saveFromResponse(external, [for (final value in login) setCookie(value)]);
      jar.saveFromResponse(external, [
        for (final name in DesktopCookieJar.authCookieNames)
          setCookie('$name=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT'),
      ]);
      expect(jar.cookieHeaderFor(external), isNull);
      expect(jar.cookieHeaderFor(local), isNull);
    });

    test('a token handed over makes the session cookies, 400 days long, on every address', () {
      jar.setServerUrls([external, local]);
      expect(jar.setToken('MIGRATED'), isTrue);
      for (final url in [external, local]) {
        expect(
          jar.cookieHeaderFor(url),
          allOf(
            contains('immich_access_token=MIGRATED'),
            contains('immich_is_authenticated=true'),
            contains('immich_auth_type=password'),
          ),
        );
      }
      expect(jar.cookies.map((c) => c.expiresAt).toSet(), {now.add(DesktopCookieJar.authCookieLifetime)});
      expect(jar.cookies.firstWhere((c) => c.name == 'immich_is_authenticated').httpOnly, isFalse);
    });

    test('no token without a server address', () {
      expect(jar.setToken('T'), isFalse);
      expect(jar.cookies, isEmpty);
    });

    test('clearAuthCookies leaves the other cookies', () {
      jar.setServerUrls([external]);
      jar.setToken('T');
      jar.saveFromResponse(external, [setCookie('other=1; Path=/')]);
      expect(jar.clearAuthCookies(), isTrue);
      expect(jar.cookieHeaderFor(external), 'other=1');
      expect(jar.clearAuthCookies(), isFalse);
    });
  });

  test('what is saved comes back, without what expired meanwhile', () {
    jar.setServerUrls([external]);
    jar.setToken('T');
    jar.saveFromResponse(external, [setCookie('short=1; Path=/; Max-Age=10')]);
    final saved = jar.toJson();

    now = now.add(const Duration(seconds: 11));
    final again = DesktopCookieJar(clock: () => now)..restore(saved);
    again.setServerUrls([external]);
    expect(again.cookieHeaderFor(external), allOf(contains('immich_access_token=T'), isNot(contains('short'))));
    expect(again.cookies.firstWhere((c) => c.name == 'immich_access_token').hostOnly, isTrue);

    final broken = DesktopCookieJar(clock: () => now)
      ..restore([
        42,
        'x',
        {'name': 'a'},
      ]);
    expect(broken.cookies, isEmpty);
  });
}
