import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/desktop_http_stack.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';

void main() {
  group('DesktopHttpStack.headersFor', () {
    // What a player, the image fetcher or the transfers add to a request of their own, as getAuthHeaders of
    // HttpClientManager.kt: the custom headers on every request, the session cookie on the user's servers only. The
    // whole contract, against a server, is in http_contract_test.dart.
    late DesktopHttpStack stack;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      stack = DesktopHttpStack(
        secrets: const SecureStorageRepository(FlutterSecureStorage()),
        trustedCertificates: TrustedCertificates(folder: () async => Directory('/nonexistent/immuch360-test')),
        userAgent: () async => null,
      );
      await stack.init();
    });

    test('the custom headers go everywhere, the session cookie to the user\'s servers only', () async {
      await stack.setRequestHeaders(
        {'X-Proxy': 'abc'},
        ['https://photos.example.test', 'http://192.0.2.10:2283'],
        'TOKEN',
      );
      expect(stack.headersFor(Uri.parse('https://photos.example.test/api/server/ping')), {
        'X-Proxy': 'abc',
        'cookie': allOf(contains('immich_access_token=TOKEN'), contains('immich_auth_type=password')),
      });
      expect(stack.headersFor(Uri.parse('http://192.0.2.10:2283/api/assets')), contains('cookie'));
      // Another host: the custom headers only, as the native clients send them with every request
      expect(stack.headersFor(Uri.parse('https://plex.example.test/')), {'X-Proxy': 'abc'});
      // The session cookie of an HTTPS address is Secure: never over plain HTTP
      expect(stack.headersFor(Uri.parse('http://photos.example.test/')), {'X-Proxy': 'abc'});
    });

    test('websocket addresses match their server', () async {
      await stack.setRequestHeaders(const {}, ['https://photos.example.test'], 'TOKEN');
      expect(stack.headersFor(Uri.parse('wss://photos.example.test/api/socket.io/')), contains('cookie'));
      expect(stack.headersFor(Uri.parse('ws://photos.example.test/api/socket.io/')), isEmpty);
    });

    test('the session stays until it is cleared, through header changes', () async {
      await stack.setRequestHeaders(const {}, ['https://photos.example.test'], 'TOKEN');
      await stack.setRequestHeaders({'A': 'b'}, ['https://photos.example.test'], null);
      expect(stack.headersFor(Uri.parse('https://photos.example.test/')), contains('cookie'));
      await stack.clearToken();
      expect(stack.headersFor(Uri.parse('https://photos.example.test/')), {'A': 'b'});
    });
  });

  group('desktopLanAddressesOf', () {
    test('private addresses, two subnets at most, without loopback or link-local ones', () {
      final picked = desktopLanAddressesOf([
        ('Loopback Pseudo-Interface 1', InternetAddress('127.0.0.1')),
        ('Ethernet', InternetAddress('169.254.10.2')),
        ('Wi-Fi', InternetAddress('192.168.77.20')),
        ('Wi-Fi 2', InternetAddress('192.168.77.21')),
        ('Public', InternetAddress('203.0.113.5')),
        ('Ethernet 2', InternetAddress('10.20.30.4')),
        ('Ethernet 3', InternetAddress('172.16.4.4')),
      ]);
      expect(picked, ['192.168.77.20', '10.20.30.4']);
    });
  });
}
