// The QR code of a TV's Drone page (p2/design-tv-2026-10-24.md, 2.4): the code the TV made, behind a strict prefix and
// a version; the sign in code of "Connect a TV or computer" is told apart, everything else is refused.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/dji_watch_code.dart';

void main() {
  test('the text of a code, and the code read back', () {
    expect(buildDjiWatchQrText('K7M2Q9XRTH'), 'IMMUCH360-WATCH:1:K7M2Q9XRTH');
    final scan = parseDjiWatchQrText('IMMUCH360-WATCH:1:K7M2Q9XRTH');
    expect(scan, isA<DjiWatchCode>());
    expect((scan as DjiWatchCode).code, 'K7M2Q9XRTH');
    // Spaces around, as some scanners leave them
    expect(parseDjiWatchQrText('  IMMUCH360-WATCH:1:ABCDEFGHJK \n'), isA<DjiWatchCode>());
  });

  test('anything but the exact form is not a code of a TV', () {
    for (final text in [
      '',
      'K7M2Q9XRTH',
      'immuch360-watch:1:K7M2Q9XRTH',
      'IMMUCH360-WATCH:1:k7m2q9xrth',
      'IMMUCH360-WATCH:2:K7M2Q9XRTH',
      'IMMUCH360-WATCH:1:K7M2Q9XRT',
      'IMMUCH360-WATCH:1:K7M2Q9XRTHA',
      'IMMUCH360-WATCH:1:K7M2Q 9XRTH',
      'IMMUCH360-WATCH:1:K7M2Q9XRT0',
      'IMMUCH360-WATCH:1:K7M2Q9XRTO',
      'IMMUCH360-WATCH:1:K7M2Q9XRTI',
      'IMMUCH360-WATCH:1:K7M2Q9XRT1',
      'IMMUCH360-WATCH:1:K7M2Q9XRTL',
      'https://example.com/IMMUCH360-WATCH:1:K7M2Q9XRTH',
      'IMMUCH360-WATCH:1:${'A' * 600}',
    ]) {
      expect(parseDjiWatchQrText(text), isA<DjiWatchNotACode>(), reason: text);
    }
  });

  test('the sign in code of a screen is recognised as such, directly or as a link', () {
    const signIn = 'http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA';
    expect(parseDjiWatchQrText(signIn), isA<DjiWatchSignInCode>());
    expect(parseDjiWatchQrText('immuch360://pair?u=${Uri.encodeComponent(signIn)}'), isA<DjiWatchSignInCode>());
    // Not on a private address: not a sign in code either
    expect(parseDjiWatchQrText('http://8.8.8.8:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA'), isA<DjiWatchNotACode>());
  });
}
