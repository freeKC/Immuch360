import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/upnp/upnp_description.dart';

String _fixture(String name) => File('test/fixtures/upnp/$name').readAsStringSync();

void main() {
  group('parseUpnpDescription', () {
    test('reads the description of minidlna', () {
      final location = Uri.parse('http://192.168.1.10:8200/rootDesc.xml');

      final device = parseUpnpDescription(_fixture('minidlna_rootDesc.xml'), location)!;

      expect(device.friendlyName, 'immuch-minidlna');
      expect(device.udn, 'uuid:4d696e69-444c-164e-9d41-b64674b87a0b');
      expect(device.contentDirectoryControl, Uri.parse('http://192.168.1.10:8200/ctl/ContentDir'));
      expect(device.contentDirectoryType, 'urn:schemas-upnp-org:service:ContentDirectory:1');
      expect(device.manufacturer, 'Justin Maggard');
      expect(device.modelName, 'Windows Media Connect compatible (MiniDLNA)');
    });

    test('reads the description of Gerbera, the ContentDirectory after another service', () {
      final location = Uri.parse('http://192.168.1.11:49494/upnp/description.xml');

      final device = parseUpnpDescription(_fixture('gerbera_description.xml'), location)!;

      expect(device.friendlyName, 'Gerbera');
      expect(device.udn, 'uuid:96dea31c-d605-4ef0-aeb8-0af1c9fd4d26');
      expect(device.contentDirectoryControl, Uri.parse('http://192.168.1.11:49494/upnp/control/cds'));
    });

    test('reads the description of Plex', () {
      final location = Uri.parse('http://192.168.1.12:32469/DeviceDescription.xml');

      final device = parseUpnpDescription(_fixture('plex_DeviceDescription.xml'), location)!;

      expect(device.friendlyName, 'Plex Media Server: living-room');
      expect(device.contentDirectoryControl, Uri.parse('http://192.168.1.12:32469/ContentDirectory/control.xml'));
      expect(device.manufacturer, 'Plex, Inc.');
    });

    test('finds the media server in an embedded device, its relative control URL resolved and trimmed', () {
      final location = Uri.parse('http://192.168.1.13:8096/dlna/01e2a6c7/description.xml');

      final device = parseUpnpDescription(_fixture('jellyfin_description.xml'), location)!;

      expect(device.friendlyName, 'Jellyfin - media', reason: 'the name of the device with the ContentDirectory');
      expect(device.udn, 'uuid:01e2a6c7-f0d2-4c1b-9f3a-5e7d9c1b3a5e');
      expect(
        device.contentDirectoryControl,
        Uri.parse('http://192.168.1.13:8096/dlna/01e2a6c7/contentdirectory/control'),
      );
    });

    test('resolves the control URL against URLBase, and keeps the version of the service type', () {
      final location = Uri.parse('http://192.168.1.50:49152/desc/root.xml');

      final device = parseUpnpDescription(_fixture('urlbase_description.xml'), location)!;

      expect(device.friendlyName, 'Box & NAS media');
      expect(device.contentDirectoryControl, Uri.parse('http://192.168.1.50:49152/upnp/control/content_directory'));
      expect(device.contentDirectoryType, 'urn:schemas-upnp-org:service:ContentDirectory:2');
    });

    test('ignores a relative URLBase', () {
      const xml =
          '<root xmlns="urn:schemas-upnp-org:device-1-0"><URLBase>/base/</URLBase>'
          '<device><friendlyName>A</friendlyName>'
          '<UDN>uuid:a</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1'
          '</serviceType><controlURL>cd</controlURL></service></serviceList></device></root>';

      final device = parseUpnpDescription(xml, Uri.parse('http://10.0.0.2:8200/dev/desc.xml'))!;

      expect(device.contentDirectoryControl, Uri.parse('http://10.0.0.2:8200/dev/cd'));
    });

    test('matches the elements in any namespace, prefixed or not', () {
      const xml =
          '<u:root xmlns:u="urn:schemas-upnp-org:device-1-0"><u:device><u:friendlyName>Prefixed</u:friendlyName>'
          '<u:UDN>uuid:b</u:UDN><u:serviceList><u:service>'
          '<u:serviceType>urn:schemas-upnp-org:service:ContentDirectory:1'
          '</u:serviceType><u:controlURL>/cd</u:controlURL></u:service></u:serviceList></u:device></u:root>';

      final device = parseUpnpDescription(xml, Uri.parse('http://10.0.0.2:8200/desc.xml'))!;

      expect(device.friendlyName, 'Prefixed');
      expect(device.contentDirectoryControl, Uri.parse('http://10.0.0.2:8200/cd'));
    });

    test('gives null without a ContentDirectory, without a control URL, or for something else than a description', () {
      final location = Uri.parse('http://192.168.1.1:5000/rootDesc.xml');

      expect(parseUpnpDescription(_fixture('no_content_directory.xml'), location), isNull);
      expect(
        parseUpnpDescription(
          '<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1'
          '</serviceType><controlURL> </controlURL></service></serviceList></device></root>',
          location,
        ),
        isNull,
      );
      expect(parseUpnpDescription('<html><body>Router</body></html>', location), isNull);
      expect(parseUpnpDescription('', location), isNull);
    });
  });
}
