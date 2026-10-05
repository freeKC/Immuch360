// The XML parser shared by the WebDAV client, the DLNA client and the phone share: what real servers send, and the
// malformed answers some of them send.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';

const _upnpDevice = 'urn:schemas-upnp-org:device-1-0';
const _soap = 'http://schemas.xmlsoap.org/soap/envelope/';
const _contentDirectory = 'urn:schemas-upnp-org:service:ContentDirectory:1';
const _didl = 'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/';
const _dc = 'http://purl.org/dc/elements/1.1/';

void main() {
  group('parseLiteXml', () {
    test('gives a document without a name holding the top level element', () {
      final document = parseLiteXml('<?xml version="1.0"?>\n<root><a/></root>');

      expect(document.name, '');
      expect(document.children.single.name, 'root');
      expect(document.child('root')!.child('a'), isNotNull);
    });

    test('resolves a default namespace and prefixed ones, and keeps the qualified name', () {
      final document = parseLiteXml(
        '<root xmlns="$_upnpDevice" xmlns:dlna="urn:schemas-dlna-org:device-1-0">'
        '<device><friendlyName>NAS</friendlyName><dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC></device>'
        '</root>',
      );

      final root = document.child('root', namespace: _upnpDevice)!;
      final device = root.child('device')!;
      expect(device.namespace, _upnpDevice);
      expect(device.child('friendlyName')!.text, 'NAS');
      final doc = device.child('X_DLNADOC')!;
      expect(doc.qualifiedName, 'dlna:X_DLNADOC');
      expect(doc.namespace, 'urn:schemas-dlna-org:device-1-0');
      expect(device.child('X_DLNADOC', namespace: _upnpDevice), isNull);
    });

    test('a prefix bound in an element only applies inside it, and an unknown prefix has no namespace', () {
      final document = parseLiteXml('<a><x:b xmlns:x="urn:x"><x:c/></x:b><x:d/></a>');

      final a = document.child('a')!;
      expect(a.namespace, isNull);
      expect(a.child('b')!.namespace, 'urn:x');
      expect(a.child('b')!.child('c')!.namespace, 'urn:x');
      expect(a.child('d')!.namespace, isNull);
      expect(a.child('d')!.qualifiedName, 'x:d');
    });

    test('stores the attributes by local name, without the namespace declarations, entities decoded', () {
      final document = parseLiteXml(
        '<item xmlns="$_didl" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" id="64\$1" '
        "parentID='64' restricted=\"1\" title=\"Tom &amp; Jerry &#233;t&#xE9; &lt;3\">"
        '<albumArtURI dlna:profileID="JPEG_TN">http://192.168.1.10:8200/AlbumArt/22-1.jpg</albumArtURI>'
        '</item>',
      );

      final item = document.child('item')!;
      expect(item.attributes, {'id': '64\$1', 'parentID': '64', 'restricted': '1', 'title': 'Tom & Jerry été <3'});
      expect(item.child('albumArtURI')!.attributes, {'profileID': 'JPEG_TN'});
    });

    test('keeps the first of two attributes with the same local name', () {
      final element = parseLiteXml('<a xmlns:x="urn:x" x:size="1" size="2"/>').child('a')!;

      expect(element.attributes, {'size': '1'});
    });

    test('decodes the entities of the text, and leaves the unknown ones and a lone "&" as they are', () {
      final element = parseLiteXml(
        '<t>a &lt; b &amp;&amp; c &gt; d &quot;e&quot; &apos;f&apos; &#65;&#x42; &nbsp; & g</t>',
      );

      expect(element.child('t')!.text, 'a < b && c > d "e" \'f\' AB &nbsp; & g');
    });

    test('keeps CDATA sections as they are, entities included', () {
      final element = parseLiteXml('<Result><![CDATA[<DIDL-Lite>&amp;</DIDL-Lite>]]></Result>').child('Result')!;

      expect(element.text, '<DIDL-Lite>&amp;</DIDL-Lite>');
      expect(element.children, isEmpty);
    });

    test('reads the escaped DIDL-Lite of a Browse answer as text, which parses in turn', () {
      final envelope = parseLiteXml(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="$_soap" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:BrowseResponse xmlns:u="$_contentDirectory"><Result>&lt;DIDL-Lite xmlns:dc="$_dc" '
        'xmlns="$_didl"&gt;&lt;container id="64\$0" childCount="3"&gt;&lt;dc:title&gt;Trips &amp;amp; more'
        '&lt;/dc:title&gt;&lt;/container&gt;&lt;/DIDL-Lite&gt;</Result><NumberReturned>1</NumberReturned>'
        '<TotalMatches>1</TotalMatches></u:BrowseResponse></s:Body></s:Envelope>',
      );

      final response = envelope.descendantsNamed('BrowseResponse').single;
      expect(response.namespace, _contentDirectory);
      expect(envelope.child('Envelope', namespace: _soap)!.attributes, {
        'encodingStyle': 'http://schemas.xmlsoap.org/soap/encoding/',
      });
      expect(response.child('NumberReturned')!.text, '1');

      final didl = parseLiteXml(response.child('Result')!.text).child('DIDL-Lite', namespace: _didl)!;
      final container = didl.child('container')!;
      expect(container.attributes, {'id': '64\$0', 'childCount': '3'});
      final title = container.child('title', namespace: _dc)!;
      expect(title.text, 'Trips & more');
      expect(title.qualifiedName, 'dc:title');
    });

    test('skips comments, processing instructions, doctypes and a byte order mark', () {
      final document = parseLiteXml(
        '\uFEFF<?xml version="1.0"?><!DOCTYPE root [<!ENTITY x "y">]><!-- a <comment> --><root>'
        '<?pi data?>text<!-- <b/> --></root>',
      );

      expect(document.children.single.name, 'root');
      expect(document.child('root')!.text, 'text');
      expect(document.child('root')!.children, isEmpty);
    });

    test('keeps a ">" inside a quoted attribute value', () {
      final element = parseLiteXml('<a href="x>y" other=\'1>2\'>t</a>').child('a')!;

      expect(element.attributes, {'href': 'x>y', 'other': '1>2'});
      expect(element.text, 't');
    });

    test('is forgiving with malformed input and never throws', () {
      // An unclosed element is closed by the end tag of its parent
      final unclosed = parseLiteXml('<a><b>one<c>two</a><d/>');
      expect(unclosed.children.map((e) => e.name), ['a', 'd']);
      expect(unclosed.child('a')!.child('b')!.child('c')!.text, 'two');

      // A stray end tag is ignored
      expect(parseLiteXml('<a></b>x</a>').child('a')!.text, 'x');

      // A cut answer keeps what came before the cut
      final cut = parseLiteXml('<a><b>1</b><c attr="');
      expect(cut.child('a')!.child('b')!.text, '1');

      for (final input in ['', '<', '<>', '</>', '<<<', '&', '<a', '<!-- never closed', '<![CDATA[ never', 'text']) {
        expect(() => parseLiteXml(input), returnsNormally, reason: input);
      }
      expect(parseLiteXml('plain text').text, 'plain text');
    });
  });

  group('LiteXmlElement', () {
    final document = parseLiteXml(
      '<root xmlns="urn:a" xmlns:b="urn:b">'
      '<device><name>1</name><deviceList><device><name>2</name>'
      '<deviceList><device><name>3</name></device></deviceList></device></deviceList></device>'
      '<device><name>4</name></device><b:device><name>5</name></b:device>'
      '</root>',
    );
    final root = document.child('root')!;

    test('finds the children by name, in any namespace or in one', () {
      expect(root.childrenNamed('device').length, 3);
      expect(root.childrenNamed('device', namespace: 'urn:a').length, 2);
      expect(root.child('device', namespace: 'urn:b')!.child('name')!.text, '5');
      expect(root.child('missing'), isNull);
    });

    test('finds the descendants depth first in document order', () {
      expect(document.descendantsNamed('name').map((e) => e.text), ['1', '2', '3', '4', '5']);
      expect(root.descendantsNamed('device', namespace: 'urn:a').map((e) => e.child('name')!.text), [
        '1',
        '2',
        '3',
        '4',
      ]);
      expect(root.descendantsNamed('root'), isEmpty, reason: 'the element itself is not its descendant');
    });
  });

  group('escapeXmlText and decodeXmlEntities', () {
    test('escape the five special characters, and decode back', () {
      const text = 'Tom & Jerry <"in" \'Paris\'> 64\$1 été';

      expect(escapeXmlText(text), 'Tom &amp; Jerry &lt;&quot;in&quot; &apos;Paris&apos;&gt; 64\$1 été');
      expect(decodeXmlEntities(escapeXmlText(text)), text);
      expect(escapeXmlText('plain'), 'plain');
    });

    test('an escaped object id reads back from an element and an attribute', () {
      const id = 'a<b>&"c\'';
      final element = parseLiteXml(
        '<ObjectID id="${escapeXmlText(id)}">${escapeXmlText(id)}</ObjectID>',
      ).child('ObjectID')!;

      expect(element.text, id);
      expect(element.attributes['id'], id);
    });

    test('decode character references, and leave out of range ones as they are', () {
      expect(decodeXmlEntities('&#x1F600; &#128512; &#x110000; &#xZZ;'), '\u{1F600} \u{1F600} &#x110000; &#xZZ;');
    });
  });
}
