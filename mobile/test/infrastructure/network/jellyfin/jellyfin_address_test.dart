// The address of a Jellyfin or Emby server as typed: a bare host, a port, a scheme, a base path, a pasted web page,
// and when http leaves the home network.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_address.dart';

void main() {
  test('what is typed, read', () {
    String? read(String text) => parseJellyfinAddress(text)?.text;
    expect(read('192.168.1.20'), 'http://192.168.1.20:8096');
    expect(read(' 192.168.1.20:8920 '), 'http://192.168.1.20:8920');
    expect(read('https://media.example.org/jellyfin/'), 'https://media.example.org/jellyfin');
    expect(read('http://nas.local:8096/web/index.html'), 'http://nas.local:8096');
    expect(read('http://nas.local:8096/jellyfin/web/'), 'http://nas.local:8096/jellyfin');
    expect(read('[fd00::5]:8096'), 'http://[fd00::5]:8096');
    for (final wrong in ['', 'ftp://x', 'http://', 'a b', 'http://user:pw@host:8096', 'host:99999']) {
      expect(parseJellyfinAddress(wrong), isNull, reason: wrong);
    }
  });

  test('the port stored: none for the default of the scheme', () {
    expect(parseJellyfinAddress('192.168.1.20')!.storedPort, isNull);
    expect(parseJellyfinAddress('https://192.168.1.20:8920')!.storedPort, isNull);
    expect(parseJellyfinAddress('https://media.example.org')!.storedPort, 443);
    expect(parseJellyfinAddress('192.168.1.20:18096')!.storedPort, 18096);
  });

  test('http outside home is told, at home or over https it is not', () {
    bool outside(String text) => parseJellyfinAddress(text)!.isPlainOutsideHome;
    expect(outside('http://203.0.113.9:8096'), isTrue);
    expect(outside('http://media.example.org'), isTrue);
    expect(outside('https://media.example.org'), isFalse);
    expect(outside('192.168.1.20'), isFalse);
    expect(outside('10.0.0.5:8096'), isFalse);
    expect(outside('nas'), isFalse);
    expect(outside('nas.local'), isFalse);
    expect(outside('127.0.0.1'), isFalse);
  });
}
