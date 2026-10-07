import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_token.dart';

const _token = 'TEST-TOKEN-0000000000';
const _hash = '0123456789abcdef0123456789abcdef';

String _jwt(Map<String, Object?> payload) {
  String part(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'EdDSA', 'typ': 'JWT'})}.${part(payload)}.c2lnbmF0dXJl';
}

void main() {
  test('takes the token and the server of a "View XML" address', () {
    final pasted = parsePastedPlexToken(
      'https://192-0-2-20.$_hash.plex.direct:32400/library/metadata/201?checkFiles=1&X-Plex-Token=$_token',
    );
    expect(pasted?.token, _token);
    expect(pasted?.kind, PlexTokenKind.legacy);
    expect(pasted?.server.toString(), 'https://192-0-2-20.$_hash.plex.direct:32400');
  });

  test('takes the server of a plain local address, and none of another site', () {
    expect(
      parsePastedPlexToken('http://192.0.2.20:32400/library/metadata/1?X-Plex-Token=$_token')?.server.toString(),
      'http://192.0.2.20:32400',
    );
    final fromWeb = parsePastedPlexToken(
      'https://app.plex.tv/desktop/#!/server/x/details?key=%2Flibrary%2Fmetadata%2F1&X-Plex-Token=$_token',
    );
    expect(fromWeb?.token, _token, reason: 'the token in the fragment');
    expect(fromWeb?.server, isNull, reason: 'app.plex.tv tells nothing of the server');
  });

  test('takes a token alone, dropping spaces and line breaks', () {
    final pasted = parsePastedPlexToken('  TEST-TOKEN-\n0000000000 \r\n');
    expect(pasted?.token, _token);
    expect(pasted?.server, isNull);
    expect(pasted?.kind, PlexTokenKind.legacy);
  });

  test('reads the expiry of a JSON Web Token, past or future', () {
    final now = DateTime.utc(2026, 10, 7);
    final future = parsePastedPlexToken(_jwt({'exp': now.add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000}));
    expect(future?.kind, PlexTokenKind.jwt);
    expect(future?.expires, now.add(const Duration(days: 7)));
    expect(future?.isExpired(now), isFalse);

    final past = parsePastedPlexToken(
      _jwt({'exp': now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}),
    );
    expect(past?.isExpired(now), isTrue);

    final noExpiry = parsePastedPlexToken(_jwt({'sub': 'x'}));
    expect(noExpiry?.kind, PlexTokenKind.jwt);
    expect(noExpiry?.expires, isNull);
    expect(noExpiry?.isExpired(now), isFalse);
  });

  test('still gives a text of no known form, for the server to decide', () {
    final pasted = parsePastedPlexToken('not!a#token');
    expect(pasted?.kind, PlexTokenKind.unknown);
    expect(parsePastedPlexToken('a.b.c')?.kind, PlexTokenKind.unknown, reason: 'three parts without a JWT header');
  });

  test('gives nothing for an empty text or an address without a token', () {
    expect(parsePastedPlexToken(''), isNull);
    expect(parsePastedPlexToken(' \n '), isNull);
    expect(parsePastedPlexToken('https://192-0-2-20.$_hash.plex.direct:32400/library/metadata/1'), isNull);
    expect(parsePastedPlexToken('https://192.0.2.20:32400/?X-Plex-Token='), isNull);
  });

  test('never prints the token', () {
    final pasted = parsePastedPlexToken('https://192.0.2.20:32400/x?X-Plex-Token=$_token')!;
    expect(pasted.toString(), isNot(contains(_token)));
    expect(pasted.toString(), contains('legacy'));
  });

  test('redactPlexToken hides the token of a query and of a header line', () {
    expect(
      redactPlexToken('https://192.0.2.20:32400/x?a=1&X-Plex-Token=$_token&b=2'),
      'https://192.0.2.20:32400/x?a=1&X-Plex-Token=<hidden>&b=2',
    );
    expect(redactPlexToken('x-plex-token: $_token'), 'x-plex-token: <hidden>');
    expect(redactPlexToken('nothing here'), 'nothing here');
  });
}
