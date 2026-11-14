// The addresses of the cameras of other brands: a pasted address read and its account taken out, the masks of the
// logs, the UniFi Protect link on the phones, the stream paths of the secure storage. Synthetic addresses only.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';

void main() {
  group('parseCameraStreamAddress', () {
    test('reads a plain address with the default port', () {
      final address = parseCameraStreamAddress(' rtsp://192.0.2.10/Streaming/Channels/101 ')!;
      expect(address.secure, isFalse);
      expect(address.host, '192.0.2.10');
      expect(address.port, 554);
      expect(address.pathAndQuery, '/Streaming/Channels/101');
      expect(address.user, isNull);
      expect(address.url, 'rtsp://192.0.2.10:554/Streaming/Channels/101');
    });

    test('takes the account out of the user info, decoded', () {
      final address = parseCameraStreamAddress(
        'rtsp://admin:p%40ss%3Aw0rd@192.0.2.11:8554/cam/realmonitor?channel=1&subtype=0',
      )!;
      expect(address.user, 'admin');
      expect(address.password, 'p@ss:w0rd');
      expect(address.port, 8554);
      expect(address.pathAndQuery, '/cam/realmonitor?channel=1&subtype=0');
      expect(address.url, isNot(contains('admin')));
    });

    test('a raw @ in the password ends at the last one', () {
      final address = parseCameraStreamAddress('rtsp://viewer:a@b@192.0.2.12/live')!;
      expect(address.user, 'viewer');
      expect(address.password, 'a@b');
      expect(address.host, '192.0.2.12');
    });

    test('RTSPS, IPv6 and a query without a path', () {
      final unifi = parseCameraStreamAddress('rtsps://192.0.2.1:7441/AbCdEf123?enableSrtp')!;
      expect(unifi.secure, isTrue);
      expect(unifi.port, 7441);
      expect(unifi.pathAndQuery, '/AbCdEf123?enableSrtp');
      expect(parseCameraStreamAddress('rtsps://cam.example/')!.port, rtspsDefaultPort);
      final v6 = parseCameraStreamAddress('rtsp://[2001:db8::5]:554/stream1')!;
      expect(v6.host, '2001:db8::5');
      expect(v6.url, 'rtsp://[2001:db8::5]:554/stream1');
      expect(parseCameraStreamAddress('rtsp://192.0.2.13?x=1')!.pathAndQuery, '/?x=1');
    });

    test('refuses what is not an RTSP address', () {
      for (final text in [
        '',
        '192.0.2.10',
        'http://192.0.2.10/onvif/device_service',
        'rtsp://',
        'rtsp:///stream',
        'rtsp://host:port/x',
        'rtsp://host:70000/x',
        'rtsp://[2001:db8::5/x',
      ]) {
        expect(parseCameraStreamAddress(text), isNull, reason: text);
      }
    });
  });

  group('maskCameraUrl', () {
    test('keeps the scheme, the host and the port only', () {
      expect(
        maskCameraUrl('rtsp://admin:secret@192.0.2.10:554/user=admin_password=secret_channel=1'),
        'rtsp://…@192.0.2.10:554/…',
      );
      expect(maskCameraUrl('rtsps://192.0.2.1:7441/AbCdEf123?enableSrtp'), 'rtsps://192.0.2.1:7441/…');
      expect(maskCameraUrl('http://192.0.2.10/onvif/device_service'), 'http://192.0.2.10/…');
      expect(maskCameraUrl('rtsp://192.0.2.10:554/'), 'rtsp://192.0.2.10:554/');
      expect(maskCameraUrl('not an address'), '…');
    });

    test('masks every address of a message', () {
      final text = maskCameraUrlsIn(
        'Failed to open rtsp://u:pw@192.0.2.10/token123 and "http://192.0.2.10/snap?pwd=x"',
      );
      expect(text, isNot(contains('pw')));
      expect(text, isNot(contains('token123')));
      expect(text, isNot(contains('pwd=x')));
      expect(text, contains('rtsp://…@192.0.2.10/…'));
    });
  });

  group('phonePlayableAddress', () {
    test('a UniFi Protect link plays on its plain port with the same token', () {
      final phone = phonePlayableAddress(parseCameraStreamAddress('rtsps://192.0.2.1:7441/AbCdEf123?enableSrtp')!)!;
      expect(phone.url, 'rtsp://192.0.2.1:7447/AbCdEf123');
      final other = phonePlayableAddress(parseCameraStreamAddress('rtsps://192.0.2.1:7441/Tok?a=1&enableSrtp&b=2')!)!;
      expect(other.pathAndQuery, '/Tok?a=1&b=2');
    });

    test('plain RTSP as it is, another RTSPS address nowhere', () {
      final plain = parseCameraStreamAddress('rtsp://192.0.2.10/stream1')!;
      expect(phonePlayableAddress(plain), same(plain));
      expect(phonePlayableAddress(parseCameraStreamAddress('rtsps://192.0.2.10:322/stream1')!), isNull);
    });
  });

  group('IpCameraStreams', () {
    test('round trips and picks the stream', () {
      const streams = IpCameraStreams(
        main: '/h264Preview_01_main',
        sub: '/h264Preview_01_sub',
        snapshot: 'http://192.0.2.10/cgi-bin/snap',
      );
      final back = IpCameraStreams.decode(streams.encode());
      expect(back, streams);
      expect(back!.pathFor(hd: true), '/h264Preview_01_main');
      expect(back.pathFor(hd: false), '/h264Preview_01_sub');
      expect(const IpCameraStreams(main: '/live').pathFor(hd: false), '/live');
      expect(streams.toString(), isNot(contains('Preview')));
    });

    test('refuses what it cannot read', () {
      for (final text in [null, '', 'x', '[]', '{"main":""}', '{"sub":"/a"}']) {
        expect(IpCameraStreams.decode(text), isNull, reason: text);
      }
    });
  });
}
