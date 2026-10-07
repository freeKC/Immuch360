import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';

const _hash = '0123456789abcdef0123456789abcdef';

Object? _fixture(String name) => jsonDecode(File('test/fixtures/plex/$name').readAsStringSync());

void main() {
  test('reads the identity', () {
    final identity = parsePlexIdentity(_fixture('identity.json'));
    expect(identity?.machineIdentifier, '0000000000000000000000000000000000000001');
    expect(identity?.version, '1.42.1.10060-4e8b05daf');
    expect(identity?.claimed, isTrue);
    expect(identity?.shortId, '00000000');
    expect(
      parsePlexIdentity({
        'MediaContainer': {'size': 0},
      }),
      isNull,
    );
    expect(parsePlexIdentity('text'), isNull);
  });

  test('reads the name of the server, and nothing of its account', () {
    expect(parsePlexServerName(_fixture('server_root.json')), 'Test Plex');
    expect(
      parsePlexServerName({
        'MediaContainer': {'friendlyName': '  '},
      }),
      isNull,
    );
  });

  test('keeps the photo, movie and show sections, in server order, music left out', () {
    final sections = parsePlexSections(_fixture('sections.json'));
    expect(
      [for (final s in sections) (s.key, s.type, s.title)],
      [('1', 'movie', 'Movies'), ('2', 'photo', 'Photos'), ('3', 'show', 'Series')],
    );
    expect(sections[1].isPhoto, isTrue);
  });

  test('names the sections at the root uniquely without case', () {
    final names = plexSectionEntryNames(const [
      PlexSection(key: '1', title: 'Photos', type: 'photo'),
      PlexSection(key: '2', title: 'photos', type: 'photo'),
      PlexSection(key: '3', title: 'A/B', type: 'movie'),
    ]);
    expect([for (final n in names) n.name], ['Photos', 'photos (2)', 'A_B']);
  });

  group('parsePlexListing', () {
    test('classifies the elements of the folder view: folders by key, a file per part', () {
      final page = parsePlexListing(_fixture('folder_root.json'));
      expect(page.count, 5);
      expect(page.totalSize, 5);
      expect(page.offset, 0);
      final folders = page.items.whereType<PlexFolderItem>().toList();
      expect(
        [for (final f in folders) (f.key, f.name)],
        [
          ('/library/sections/1/folder?parent=101', 'Holidays'),
          ('/library/sections/1/folder?parent=102', 'Shorts'),
          ('/library/sections/1/folder?parent=103', 'holidays'),
        ],
      );
      final files = page.items.whereType<PlexFileItem>().toList();
      expect(
        [for (final f in files) f.name],
        ['Test Pattern (2020).mkv', 'Two Parts - pt1.mp4', 'Two Parts - pt2.mp4'],
      );
      final movie = files.first;
      expect(movie.partKey, '/library/parts/2010/1700000000/file.mkv');
      expect(movie.partId, 2010);
      expect(movie.size, 104857600);
      expect(movie.addedAt, DateTime.fromMillisecondsSinceEpoch((1600000000 + 201) * 1000, isUtc: true));
      expect(movie.mimeType, 'video/x-matroska');
      expect((movie.width, movie.height, movie.durationMs), (1920, 1080, 600000));
      expect(movie.thumb, '/library/metadata/201/thumb/1700000000');
      expect(movie.ratingKey, '201');
      expect([for (final f in files.skip(1)) (f.size, f.durationMs)], [(2000, 60000), (3000, 60000)]);
    });

    test('takes the last segment of a path on Windows too', () {
      final page = parsePlexListing(_fixture('folder_child_page1.json'));
      expect([for (final f in page.items.whereType<PlexFileItem>()) f.name], ['beach_360.mp4', 'beach_360.mp4']);
      expect(page.totalSize, 3);
    });

    test('reads a page with an offset, and one without a total', () {
      final second = parsePlexListing(_fixture('folder_child_page2.json'));
      expect(second.offset, 2);
      expect(second.items.single, isA<PlexFolderItem>().having((f) => f.name, 'name', 'Night_Day'));
      final noTotal = parsePlexListing(_fixture('folder_no_total.json'));
      expect(noTotal.totalSize, isNull);
      expect(noTotal.items.single, isA<PlexFileItem>().having((f) => f.mimeType, 'mime', 'video/quicktime'));
      expect(parsePlexListing(_fixture('folder_empty.json')).items, isEmpty);
    });

    test('reads albums and their photos', () {
      final albums = parsePlexListing(_fixture('photo_all.json'));
      expect(albums.items.first, isA<PlexFolderItem>().having((f) => f.key, 'key', '/library/metadata/500/children'));
      expect(albums.items.last, isA<PlexFileItem>().having((f) => f.name, 'name', 'loose.jpg'));
      final photos = parsePlexListing(_fixture('album_children.json')).items.cast<PlexFileItem>();
      expect(
        [for (final p in photos) (p.name, p.mimeType, p.width)],
        [('pano_equirect.jpg', 'image/jpeg', 8000), ('garden.heic', 'image/heic', 4032)],
      );
    });

    test('reads both arrays, and leaves out what is neither a folder nor a file', () {
      final page = parsePlexListing({
        'MediaContainer': {
          'size': 4,
          'Directory': [
            {'key': '/library/sections/1/folder?parent=9', 'title': 'In Directory'},
            {'key': '/library/collections/5', 'title': 'A collection'},
          ],
          'Metadata': [
            {'key': '/library/metadata/7', 'title': 'Movie without media', 'type': 'movie'},
            {
              'title': 'No file name',
              'Media': [
                {
                  'container': 'mp4',
                  'Part': [
                    {'key': '/library/parts/1/2/file.mp4'},
                  ],
                },
              ],
            },
          ],
        },
      });
      expect(page.count, 4);
      expect([for (final i in page.items) i.name], ['In Directory', 'No file name.mp4']);
    });

    test('gives an empty page for what is no listing', () {
      expect(parsePlexListing(null).items, isEmpty);
      expect(parsePlexListing({'MediaContainer': 'x'}).count, 0);
    });
  });

  group('the address outside home', () {
    test('comes from the account, never with its token or user name', () {
      final account = parsePlexAccount(_fixture('account.json'));
      expect(account?.publicAddress, '203.0.113.7');
      expect(account?.publicPort, 32401);
      expect(account?.mappingState, 'mapped');
      expect(plexPublicAddressOf(account, null), (host: '203.0.113.7', port: 32401, mapping: 'mapped'));
    });

    test('takes the port forwarded by hand when the account has none', () {
      final prefs = parsePlexPrefs(_fixture('prefs.json'), _hash);
      expect(prefs.manualPort, 32401);
      expect(prefs.customHost, isNull);
      const account = PlexAccountAddress(publicAddress: '203.0.113.7');
      expect(plexPublicAddressOf(account, prefs)?.port, 32401);
      expect(plexPublicAddressOf(account, null), isNull);
    });

    test('takes a plex.direct address of the custom addresses, for this hash only', () {
      final prefs = parsePlexPrefs({
        'MediaContainer': {
          'Setting': [
            {'id': 'ManualPortMappingMode', 'value': 0},
            {'id': 'ManualPortMappingPort', 'value': 32401},
            {
              'id': 'customConnections',
              'value':
                  'https://203-0-113-8.fedcba9876543210fedcba9876543210.plex.direct:443, '
                  'https://203-0-113-9.$_hash.plex.direct:8443,http://example.com:32400',
            },
          ],
        },
      }, _hash);
      expect(prefs.manualPort, isNull, reason: 'the manual mapping is off');
      expect((prefs.customHost, prefs.customPort), ('203.0.113.9', 8443));
      expect(plexPublicAddressOf(null, prefs), (host: '203.0.113.9', port: 8443, mapping: null));
    });

    test('keeps public IPv4 addresses with a valid port only', () {
      for (final address in ['192.168.1.2', '10.0.0.1', '172.16.0.1', '100.64.1.1', '127.0.0.1', '169.254.1.1']) {
        expect(
          plexPublicAddressOf(PlexAccountAddress(publicAddress: address, publicPort: 32400), null),
          isNull,
          reason: address,
        );
      }
      expect(plexPublicAddressOf(const PlexAccountAddress(publicAddress: '203.0.113.7', publicPort: 0), null), isNull);
      expect(plexPublicAddressOf(const PlexAccountAddress(publicAddress: '2001:db8::1', publicPort: 1), null), isNull);
      expect(isPublicIPv4('8.8.8.8'), isTrue);
      expect(isPublicIPv4('224.0.0.1'), isFalse);
      expect(isPublicIPv4('nas.example.com'), isFalse);
    });

    test('reads a mapping mode written as a number or a string', () {
      for (final mode in [1, '1', 'true', true]) {
        final prefs = parsePlexPrefs({
          'MediaContainer': {
            'Setting': [
              {'id': 'ManualPortMappingMode', 'value': mode},
              {'id': 'ManualPortMappingPort', 'value': '32402'},
            ],
          },
        }, _hash);
        expect(prefs.manualPort, 32402, reason: '$mode');
      }
    });
  });
}
