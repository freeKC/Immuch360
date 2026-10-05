import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/network/upnp/didl_lite.dart';
import 'package:immich_mobile/infrastructure/network/upnp/dlna_file_system.dart';

final _base = Uri.parse('http://192.168.1.10:8200/ctl/ContentDir');

String _fixture(String name) => File('test/fixtures/upnp/$name').readAsStringSync();

/// The Browse answer of the design, minidlna style, the DIDL-Lite escaped in Result
final browseSample = _fixture('browse_sample.xml');

/// A DIDL-Lite document holding [objects]
String _didl(String objects) =>
    '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
    'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
    '$objects</DIDL-Lite>';

String _item(String title, String resources, {String upnpClass = 'object.item.imageItem.photo', String id = '1'}) =>
    '<item id="$id" parentID="0" restricted="1"><dc:title>$title</dc:title><upnp:class>$upnpClass</upnp:class>'
    '$resources</item>';

String _res(String url, String mime, {String extra = '', String attributes = '', String protocol = 'http-get'}) =>
    '<res protocolInfo="$protocol:*:$mime:$extra"$attributes>$url</res>';

DidlObject _one(String objects) => parseDidlLite(_didl(objects), base: _base).single;

void main() {
  group('parseBrowseResponse and parseDidlLite', () {
    test('read the Browse sample: a folder and a 360° video with its album art', () {
      final answer = parseBrowseResponse(browseSample, _base);

      expect(answer.errorCode, isNull);
      expect(answer.numberReturned, 2);
      expect(answer.totalMatches, 2);
      final [folder, video] = answer.objects!;

      expect(folder.id, r'64$0');
      expect(folder.parentId, '64');
      expect(folder.isContainer, isTrue);
      expect(folder.title, 'Trips');
      expect(folder.upnpClass, 'object.container.storageFolder');
      expect(folder.childCount, 3);
      expect(folder.isMedia, isTrue);
      expect(dlnaEntryName(folder), 'Trips');

      expect(video.id, r'64$1');
      expect(video.isContainer, isFalse);
      expect(video.date, DateTime(2024, 9, 8, 13, 30, 36), reason: 'a date without a zone is a local time');
      final original = video.original!;
      expect(original.url, Uri.parse('http://192.168.1.10:8200/MediaItems/22.mp4'));
      expect(original.protocol, 'http-get');
      expect(original.mimeType, 'video/mp4');
      expect(original.size, 104857600);
      expect(original.durationMs, 83456);
      expect(original.width, 5760);
      expect(original.height, 2880);
      expect(original.dlnaParams, {
        'DLNA.ORG_OP': '01',
        'DLNA.ORG_CI': '0',
        'DLNA.ORG_FLAGS': '01700000000000000000000000000000',
      });
      expect(original.byteSeek, isTrue);
      expect(original.isConverted, isFalse);
      expect(original.isThumbnail, isFalse);
      expect(video.thumbnailUrl, Uri.parse('http://192.168.1.10:8200/AlbumArt/22-1.jpg'));
      expect(video.isMedia, isTrue);
      expect(dlnaEntryName(video), 'VID_20240908_133036_00_001.mp4');
    });

    test('read a Result in a CDATA section', () {
      final beach = _didl(_item('Beach', _res('/media/1.jpg', 'image/jpeg')));
      final xml =
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse '
          'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result><![CDATA[$beach]]></Result>'
          '<NumberReturned>1</NumberReturned><TotalMatches>9</TotalMatches></u:BrowseResponse></s:Body></s:Envelope>';

      final answer = parseBrowseResponse(xml, _base);

      expect(answer.numberReturned, 1);
      expect(answer.totalMatches, 9);
      expect(answer.objects!.single.title, 'Beach');
      expect(
        answer.objects!.single.original!.url,
        Uri.parse('http://192.168.1.10:8200/media/1.jpg'),
        reason: 'a relative URL is resolved against the base',
      );
    });

    test('read the real answers of minidlna and Gerbera', () {
      final minidlna = parseBrowseResponse(_fixture('minidlna_browse_patterns.xml'), _base);
      expect(
        [for (final object in minidlna.objects!) dlnaEntryName(object)],
        ['bars.mov', 'clip.mp4', 'pattern.jpg', null],
      );
      expect(minidlna.objects!.last.isMedia, isFalse, reason: 'an MP3');
      final minidlnaPhoto = minidlna.objects![2];
      expect(minidlnaPhoto.original!.size, 16877, reason: 'the JPEG_SM file itself, not its JPEG_TN copy');
      expect(minidlnaPhoto.thumbnailUrl!.path, '/Resized/25.jpg');

      final gerbera = parseBrowseResponse(_fixture('gerbera_browse_patterns.xml'), _base);
      expect(gerbera.numberReturned, 4);
      expect(
        [for (final object in gerbera.objects!) dlnaEntryName(object)],
        [null, 'pattern.jpg', 'bars.mov', 'clip.mp4'],
      );
      final gerberaVideo = gerbera.objects![3];
      expect(gerberaVideo.original!.mimeType, 'video/mp4');
      expect(gerberaVideo.thumbnailUrl!.path, '/media/object_id/57/res_id/1/ext/file.jpg');
      expect(gerbera.objects![1].original!.width, 640);
    });

    test('tell the UPnP error of a fault', () {
      expect(parseBrowseResponse(_fixture('minidlna_browse_701.xml'), _base).errorCode, 701);
      expect(parseBrowseResponse(_fixture('gerbera_browse_701.xml'), _base).errorCode, 501);
      expect(parseBrowseResponse('<html>Not found</html>', _base).objects, isNull);
    });

    test('count the objects of a page when the server does not', () {
      final escaped = escapeXmlText(_didl('<container id="a"/><container id="b"/>'));
      final xml =
          '<Envelope><Body><BrowseResponse><Result>$escaped'
          '</Result></BrowseResponse></Body></Envelope>';

      final answer = parseBrowseResponse(xml, _base);

      expect(answer.numberReturned, 2);
      expect(answer.totalMatches, 0);
    });
  });

  group('DidlResource and DidlObject', () {
    test('choose the original: not a thumbnail, not converted, then the largest, then the first', () {
      final object = _one(
        _item(
          'Pano',
          [
            _res('http://h/tn.jpg', 'image/jpeg', extra: 'DLNA.ORG_PN=JPEG_TN', attributes: ' resolution="160x80"'),
            _res('http://h/small.jpg', 'image/jpeg', attributes: ' resolution="300x150" size="9000"'),
            _res('http://h/converted.jpg', 'image/jpeg', extra: 'DLNA.ORG_CI=1', attributes: ' size="900000"'),
            _res('http://h/first.jpg', 'image/jpeg', attributes: ' size="500000"'),
            _res('http://h/largest.jpg', 'image/jpeg', attributes: ' size="800000"'),
            _res('http://h/same.jpg', 'image/jpeg', attributes: ' size="800000"'),
            _res('rtsp://h/stream', 'video/mp4', attributes: ' size="99999999"', protocol: 'rtsp-rtp-udp'),
          ].join(),
        ),
      );

      expect(object.resources, hasLength(7));
      expect(object.resources[0].isThumbnail, isTrue, reason: 'JPEG_TN');
      expect(object.resources[1].isThumbnail, isTrue, reason: '320 pixels or less next to other resources');
      expect(object.resources[2].isConverted, isTrue);
      expect(object.original!.url.path, '/largest.jpg');
      expect(object.thumbnailUrl!.path, '/tn.jpg', reason: 'the smallest thumbnail without album art');
    });

    test('take a converted resource when there is nothing else, and a small picture alone as the file', () {
      final converted = _one(_item('A', _res('http://h/a.jpg', 'image/jpeg', extra: 'DLNA.ORG_CI=1')));
      expect(converted.original!.url.path, '/a.jpg');

      final small = _one(_item('Icon', _res('http://h/icon.png', 'image/png', attributes: ' resolution="64x64"')));
      expect(small.original!.isThumbnail, isFalse, reason: 'alone, a small picture is the file');
      expect(dlnaEntryName(small), 'Icon.png');
    });

    test('read the DLNA operations, durations and resolutions', () {
      final object = _one(
        _item(
          'Clip',
          [
            _res(
              'http://h/1.mp4',
              'video/mp4',
              extra: 'DLNA.ORG_OP=10',
              attributes: ' duration="12:03:04" resolution="1920 x 1080"',
            ),
            _res('http://h/2.mp4', 'video/mp4', attributes: ' duration="0:00:01.1/4" resolution="wide"'),
            _res('http://h/3.mp4', 'video/mp4', attributes: ' duration="bad"'),
          ].join(),
          upnpClass: 'object.item.videoItem',
        ),
      );

      final [first, second, third] = object.resources;
      expect(first.byteSeek, isFalse, reason: 'time seek only');
      expect(first.durationMs, (12 * 3600 + 3 * 60 + 4) * 1000);
      expect(first.width, 1920);
      expect(first.height, 1080);
      expect(second.byteSeek, isNull);
      expect(second.durationMs, 1250);
      expect(second.width, isNull);
      expect(third.durationMs, isNull);
      expect(parseDidlDuration('1:02:03.25'), 3723250);
    });

    test('leave out numbers too long for an int instead of failing', () {
      const huge = '99999999999999999999999';
      final object = _one(
        _item(
          'Clip',
          [
            _res('http://h/1.mp4', 'video/mp4', attributes: ' duration="$huge:00:00" resolution="${huge}x1080"'),
            _res('http://h/2.mp4', 'video/mp4', attributes: ' duration="0:00:01.$huge" resolution="1920x$huge"'),
          ].join(),
          upnpClass: 'object.item.videoItem',
        ),
      );

      final [first, second] = object.resources;
      expect(first.durationMs, isNull);
      expect(first.width, isNull);
      expect(first.height, isNull, reason: 'a resolution reads whole or not at all');
      expect(second.durationMs, 2000, reason: 'decimal digits, however many');
      expect(second.height, isNull);
      expect(parseDidlDuration('0:00:01.$huge/4'), isNull);
      expect(parseDidlDuration('0:00:01.5/4'), 1000, reason: 'not a fraction of a second');
      expect(parseDidlDuration('2000000:00:00'), isNull, reason: 'more hours than a duration holds');
      expect(parseDidlDuration('999999:00:00'), 999999 * 3600 * 1000);
    });

    test('read dates with and without time and zone', () {
      DateTime? dateOf(String date) =>
          _one(_item('A', '<dc:date>$date</dc:date>${_res('http://h/a.jpg', 'image/jpeg')}')).date;

      expect(dateOf('2024-09-08'), DateTime(2024, 9, 8));
      expect(dateOf('2024-09-08T13:30:36'), DateTime(2024, 9, 8, 13, 30, 36));
      expect(dateOf('2024-09-08T13:30:36Z'), DateTime.utc(2024, 9, 8, 13, 30, 36));
      expect(dateOf('2024-09-08T13:30:36+02:00'), DateTime.utc(2024, 9, 8, 11, 30, 36));
      expect(dateOf('2026-10-05T06:24:53+0000'), DateTime.utc(2026, 10, 5, 6, 24, 53), reason: 'Gerbera');
      expect(dateOf('yesterday'), isNull);
    });

    test('keep photos, videos and folders, and leave the audio and the rest out', () {
      const album =
          '<container id="c"><dc:title>Music</dc:title>'
          '<upnp:class>object.container.album.musicAlbum</upnp:class></container>';
      final objects = parseDidlLite(
        _didl(
          [
            album,
            _item('Song', _res('http://h/s.mp3', 'audio/mpeg'), upnpClass: 'object.item.audioItem.musicTrack', id: 'a'),
            _item('Photo', '', upnpClass: 'object.item.imageItem.photo', id: 'p'),
            _item('Generic', _res('http://h/g.mkv', 'video/x-matroska'), upnpClass: 'object.item', id: 'g'),
            _item('Text', _res('http://h/t.txt', 'text/plain'), upnpClass: 'object.item', id: 't'),
            '<item><dc:title>No id</dc:title></item>',
            '<desc id="d">metadata</desc>',
          ].join(),
        ),
        base: _base,
      );

      expect([for (final object in objects) object.id], ['c', 'a', 'p', 'g', 't']);
      expect([for (final object in objects) object.isMedia], [true, false, true, true, false]);
      expect(dlnaEntryName(objects[2]), isNull, reason: 'a photo item without a resource cannot be read');
      expect(dlnaEntryName(objects[3]), 'Generic.mkv');
    });
  });

  group('dlnaEntryName and dlnaEntryNames', () {
    test('make a path segment of the title', () {
      String? nameOf(String title) => dlnaEntryName(_one('<container id="1"><dc:title>$title</dc:title></container>'));

      expect(nameOf('  Trips 2024  '), 'Trips 2024');
      expect(nameOf('Summer/Winter'), 'Summer_Winter');
      expect(nameOf(r'C:\Photos'), 'C:_Photos');
      expect(nameOf('Tab\there'), 'Tab_here');
      expect(nameOf('  '), '_');
      expect(nameOf('.'), '_');
      expect(nameOf('..'), '_');
    });

    test('give an item the extension of its URL when it is a media one, else the one of its MIME type', () {
      String? nameOf(String title, String url, String mime) => dlnaEntryName(_one(_item(title, _res(url, mime))));

      expect(nameOf('VID_1', 'http://h/MediaItems/22.mp4', 'video/mp4'), 'VID_1.mp4');
      expect(nameOf('VID_1', 'http://h/content/ext/file.insv', 'video/mp4'), 'VID_1.insv', reason: 'raw camera file');
      expect(nameOf('IMG_1', 'http://h/Videos/stream?static=true', 'image/heic'), 'IMG_1.heic');
      expect(nameOf('IMG_1', 'http://h/item/7.bin', 'image/x-adobe-dng'), 'IMG_1.dng');
      expect(nameOf('Clip', 'http://h/7', 'video/quicktime'), 'Clip.mov');
      expect(nameOf('Clip', 'http://h/7', 'video/mp2t'), 'Clip.mts');
      expect(nameOf('Clip', 'http://h/7', 'video/mpeg'), 'Clip.mpg');
      expect(nameOf('Photo.JPG', 'http://h/1.jpg', 'image/jpeg'), 'Photo.JPG', reason: 'already in the title');
      expect(nameOf('a.jpg', 'http://h/1.mp4', 'video/mp4'), 'a.jpg.mp4');
      expect(nameOf('Odd', 'http://h/1.xyz', 'image/x-unknown'), isNull);
    });

    test('number the names met twice in a listing, without case, in server order', () {
      final objects = parseDidlLite(
        _didl(
          [
            _item('Beach', _res('http://h/1.jpg', 'image/jpeg'), id: '1'),
            _item('beach', _res('http://h/2.jpg', 'image/jpeg'), id: '2'),
            _item('Beach (2)', _res('http://h/3.jpg', 'image/jpeg'), id: '3'),
            _item('Beach', _res('http://h/4.jpg', 'image/jpeg'), id: '4'),
            _item('Beach', _res('http://h/5.mp4', 'video/mp4'), id: '5', upnpClass: 'object.item.videoItem'),
            '<container id="6"><dc:title>Trips</dc:title></container>',
            '<container id="7"><dc:title>TRIPS</dc:title></container>',
            _item('Song', _res('http://h/s.mp3', 'audio/mpeg'), id: '8', upnpClass: 'object.item.audioItem'),
          ].join(),
        ),
        base: _base,
      );

      final named = dlnaEntryNames(objects);

      expect(
        [for (final entry in named) '${entry.object.id}:${entry.name}'],
        [
          '1:Beach.jpg',
          '2:beach (2).jpg',
          '3:Beach (2) (2).jpg',
          '4:Beach (3).jpg',
          '5:Beach.mp4',
          '6:Trips',
          '7:TRIPS (2)',
        ],
      );
    });
  });
}
