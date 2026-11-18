// The file system of a Jellyfin or Emby server against the loopback fake of the bench answers: the libraries, the
// films paged by 200, series, seasons and episodes, a path after a restart, the file name rule, the reads with and
// without Range support, the server id checked before the token, a refused token, the pictures, a base path, Emby.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/jellyfin_server_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_file_system.dart';
import 'package:logging/logging.dart';

import 'fake_jellyfin_server.dart';

NetworkSource jellyfinSourceOf(FakeJellyfinServer server, {String? serverId, String id = 'jf0123456789abcd'}) =>
    NetworkSource(
      id: id,
      type: NetworkSourceType.jellyfin,
      name: 'Media',
      host: '127.0.0.1',
      port: server.port,
      share: server.basePath,
      username: 'viewer',
      discoveryId: serverId ?? server.serverId,
      jellyfin: JellyfinServerInfo(
        serverId: serverId ?? server.serverId,
        userId: server.userId,
        product: server.product.name,
        version: server.product == JellyfinProduct.emby ? '4.10.2.0' : '12.4.0',
      ),
    );

Future<JellyfinFileSystem> openJellyfin(
  FakeJellyfinServer server, {
  String token = jellyfinTestToken,
  NetworkSource? source,
  int pageSize = JellyfinFileSystem.defaultPageSize,
}) => JellyfinFileSystem.open(
  source ?? jellyfinSourceOf(server),
  token,
  client: IOClient(HttpClient()),
  installId: '0123456789abcdef0123456789abcdef',
  appVersion: '3.4.3',
  pageSize: pageSize,
);

Matcher failsWith(JellyfinFailure failure) =>
    throwsA(isA<JellyfinException>().having((e) => e.failure, 'failure', failure));

void main() {
  group('Jellyfin 12.4', () {
    late FakeJellyfinServer server;
    setUp(() async => server = await FakeJellyfinServer.start());
    tearDown(() => server.close());

    test('the libraries, then the films with their file names, titles, sizes and lengths', () async {
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      expect((await fileSystem.list('/')).map((e) => e.name), ['Films', 'Home', 'Photos', 'Shows']);
      final films = await fileSystem.list('/Films');
      expect(films.map((e) => e.name), [
        'Long Tone (2020).mkv',
        'Pattern (2024).mp4',
        'Sphere (2023) 360.mp4',
        'Stereo (2022) 3D.HSBS.mkv',
        'Tone (2021).mkv',
      ]);
      expect(films.map((e) => e.title), [
        'Long Tone (2020)',
        'Pattern (2024)',
        'Sphere (2023)',
        'Stereo (2022)',
        'Tone (2021)',
      ]);
      final stereo = films[3];
      expect(stereo.isVideo, isTrue);
      expect(stereo.size, FakeJellyfinServer.fileSize);
      expect(stereo.width, 1920);
      expect(stereo.durationMs, closeTo(20023, 100));
      // The device id of the requests: the install's, then the start of the source id
      expect(
        server.requests.last.headers['authorization'],
        contains('DeviceId="0123456789abcdef0123456789abcdef-jf012345"'),
      );
    });

    test('series, seasons and episodes, titled by their numbers', () async {
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      expect((await fileSystem.list('/Shows')).map((e) => (e.name, e.isDirectory)), [('Pattern Show', true)]);
      expect((await fileSystem.list('/Shows/Pattern Show')).map((e) => e.name), ['Season 1']);
      final episodes = await fileSystem.list('/Shows/Pattern Show/Season 1');
      expect(episodes.map((e) => e.name), ['Pattern Show S01E01.mp4', 'Pattern Show S01E02.mp4']);
      expect(episodes.map((e) => e.title), ['S01E01 Pattern Show S01E01', 'S01E02 Pattern Show S01E02']);
    });

    test(
      'the home videos and photos as the server lists them; the .insv file the server does not index is absent',
      () async {
        final fileSystem = await openJellyfin(server);
        addTearDown(fileSystem.close);
        expect((await fileSystem.list('/Home/Trip')).map((e) => e.name), ['clip.mp4']);
        final photos = await fileSystem.list('/Photos/2024');
        expect(photos.map((e) => e.name), ['pano-001.jpg', 'pattern-001.jpg']);
        expect(photos.first.isImage, isTrue);
        expect(photos.first.size, isNull, reason: 'the server gives no size of a photo');
        final stat = await fileSystem.stat('/Photos/2024/pano-001.jpg');
        expect(stat.size, FakeJellyfinServer.fileSize, reason: 'found by a read of its first byte');
      },
    );

    test('a path not met yet is found after a restart, and its bytes read with ranges', () async {
      final first = await openJellyfin(server);
      await first.close();
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      const path = '/Shows/Pattern Show/Season 1/Pattern Show S01E02.mp4';
      final entry = await fileSystem.stat(path);
      expect(entry.size, FakeJellyfinServer.fileSize);
      final id = server.itemId('Pattern Show S01E02');
      final bytes = await fileSystem.readRange(path, 1000, 5000);
      expect(bytes, server.files[id]!.sublist(1000, 6000));
      expect(fileSystem.supportsRanges, isTrue);
      final stream = server.requests.lastWhere((r) => r.path.startsWith('/Videos/'));
      expect(stream.path, '/Videos/$id/stream');
      expect(stream.query['static'], 'true');
      expect(stream.query['mediaSourceId'], isNotEmpty);
      expect(stream.headers['range'], 'bytes=1000-5999');
      // The end of the file, then past it
      expect(await fileSystem.readRange(path, FakeJellyfinServer.fileSize - 10, 100), hasLength(10));
      expect(await fileSystem.readRange(path, FakeJellyfinServer.fileSize, 100), isEmpty);
    });

    test(
      'a server that answers a range with the whole file: the bytes are right, ranges are said unsupported',
      () async {
        server.honourRanges = false;
        final fileSystem = await openJellyfin(server);
        addTearDown(fileSystem.close);
        final films = await fileSystem.list('/Films');
        final id = server.itemId('Tone (2021)');
        expect(await fileSystem.readRange(films.last.path, 300, 200), server.files[id]!.sublist(300, 500));
        expect(fileSystem.supportsRanges, isFalse);
        expect(readsAnywhere(fileSystem, films.last), isFalse);
      },
    );

    test('photos are read through the File route', () async {
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      await fileSystem.list('/Photos/2024');
      final bytes = await fileSystem.readRange('/Photos/2024/pattern-001.jpg', 0, 64);
      expect(bytes, server.files[server.itemId('pattern-001')]!.sublist(0, 64));
      expect(server.requests.last.path, '/Items/${server.itemId('pattern-001')}/File');
    });

    test('a library of more than 200 films is read page by page', () async {
      server.addFilms(server.viewId('Films'), 450);
      final fileSystem = await openJellyfin(server, pageSize: 200);
      addTearDown(fileSystem.close);
      final films = await fileSystem.list('/Films');
      expect(films, hasLength(455));
      final pages = server.requests.where((r) => r.path == '/Items' && r.query['parentId'] == server.viewId('Films'));
      expect(pages.map((r) => r.query['startIndex']), ['0', '200', '400']);
      expect(pages.first.query['sortBy'], 'SortName');
      expect(pages.first.query['includeItemTypes'], 'Movie');
    });

    test('another server at the address: refused before the token is sent', () async {
      await expectLater(
        openJellyfin(server, source: jellyfinSourceOf(server, serverId: '0123456789abcdef0123456789abcdef')),
        failsWith(JellyfinFailure.otherServer),
      );
      expect(server.requestsWithToken, isEmpty);
      expect(server.requests.map((r) => r.path), ['/System/Info/Public']);
    });

    test('a token the server refused: an authentication failure, the open says at which step', () async {
      try {
        await openJellyfin(server, token: 'ended-token');
        fail('no failure');
      } on JellyfinException catch (error) {
        expect(error.failure, JellyfinFailure.tokenRefused);
        expect(error.isAuthentication, isTrue);
        expect(JellyfinFileSystem.lastOpenFailure?.step, 'user');
        expect(JellyfinFileSystem.lastOpenFailure?.status, 401);
      }
      await expectLater(
        JellyfinFileSystem.open(jellyfinSourceOf(server), null, client: IOClient(HttpClient()), installId: 'i'),
        failsWith(JellyfinFailure.tokenRefused),
      );
    });

    test('the session ended while browsing: the next listing is an authentication failure', () async {
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      server.tokens.clear();
      await expectLater(
        fileSystem.list('/Shows'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
      );
    });

    test('a hidden path: the name is built from the title, the 3D layout and the container', () async {
      final stereo = server.items[server.itemId('Stereo (2022)')]!;
      stereo['MediaSources'] = [
        for (final source in stereo['MediaSources']! as List)
          {...(source as Map).cast<String, Object?>()}..remove('Path'),
      ];
      stereo.remove('Path');
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      final names = (await fileSystem.list('/Films')).map((e) => e.name);
      expect(names, contains('Stereo (2022) hsbs.mkv'));
    });

    test('the path of its own of an item, read again after a restart', () async {
      final fileSystem = await openJellyfin(server);
      final id = server.itemId('Sphere (2023)');
      final path = await fileSystem.pathOfItem(id);
      expect(path, startsWith('/.items/$id/'));
      expect(path, endsWith('/Sphere (2023) 360.mp4'));
      await fileSystem.close();
      final again = await openJellyfin(server);
      addTearDown(again.close);
      expect((await again.stat(path)).size, FakeJellyfinServer.fileSize);
      expect(await again.readRange(path, 10, 10), server.files[id]!.sublist(10, 20));
    });

    test('pictures: a photo has one, a film without an image none; sizes in steps of 120', () async {
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      final photos = await fileSystem.list('/Photos/2024');
      final picture = await fileSystem.thumbnail(photos.first, 256);
      expect(picture, isNotNull);
      final asked = server.requests.last;
      expect(asked.path, '/Items/${server.itemId('pano-001')}/Images/Primary');
      expect(asked.query['maxWidth'], '360');
      expect(asked.query['tag'], isNotNull);
      final films = await fileSystem.list('/Films');
      expect(await fileSystem.thumbnail(films.first, 256), isNull, reason: 'no Primary image on the bench films');
      final poster = await fileSystem.pictureOf(const JellyfinItem(id: 'x1', type: 'Movie', primaryImageTag: 't'), 300);
      expect(poster, isNull, reason: 'unknown to the server: 404');
      expect(server.requests.last.query, containsPair('fillHeight', '360'));
      expect(server.requests.last.query, containsPair('fillWidth', '240'));
    });

    test('the token, the address, titles and paths stay out of the logs and the errors', () async {
      final records = <LogRecord>[];
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        await subscription.cancel();
        Logger.root.level = previous;
      });
      final errors = <Object>[];
      final fileSystem = await openJellyfin(server);
      await fileSystem.list('/Films');
      await fileSystem.list('/Shows/Pattern Show/Season 1');
      await fileSystem.readRange('/Films/Pattern (2024).mp4', 0, 10);
      try {
        await fileSystem.stat('/Films/Missing (1999).mp4');
      } catch (error) {
        errors.add(error);
      }
      server.tokens.clear();
      try {
        await fileSystem.list('/Home/Trip');
      } catch (error) {
        errors.add(error);
      }
      await fileSystem.close();
      try {
        await openJellyfin(server, source: jellyfinSourceOf(server, serverId: '0123456789abcdef0123456789abcdef'));
      } catch (error) {
        errors.add(error);
      }
      expect(errors, hasLength(3));
      final texts = [for (final r in records) '${r.message} ${r.error ?? ''}', for (final e in errors) '$e'];
      for (final text in texts) {
        for (final secret in [jellyfinTestToken, '127.0.0.1', '${server.port}', 'Pattern', 'Trip', '/media/']) {
          expect(text, isNot(contains(secret)), reason: text);
        }
      }
    });
  });

  test('a base path behind a reverse proxy', () async {
    final server = await FakeJellyfinServer.start(basePath: '/jellyfin');
    addTearDown(server.close);
    final fileSystem = await openJellyfin(server);
    addTearDown(fileSystem.close);
    expect((await fileSystem.list('/')).map((e) => e.name), contains('Films'));
    expect(server.requests.where((r) => r.path == '/System/Info/Public'), hasLength(1));
  });

  for (final folder in ['jellyfin-10.10', 'emby']) {
    test('$folder: the libraries, the films and their bytes through its routes', () async {
      final server = await FakeJellyfinServer.start(folder: folder);
      addTearDown(server.close);
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      expect((await fileSystem.list('/')).map((e) => e.name), ['Films', 'Home', 'Photos', 'Shows']);
      final films = await fileSystem.list('/Films');
      expect(films.map((e) => e.name), contains('Stereo (2022) 3D.HSBS.mkv'));
      final stereo = films.firstWhere((e) => e.name == 'Stereo (2022) 3D.HSBS.mkv');
      final id = server.itemId(folder == 'emby' ? 'Stereo' : 'Stereo (2022)');
      expect(await fileSystem.readRange(stereo.path, 0, 32), server.files[id]!.sublist(0, 32));
      final listing = server.requests.where((r) => r.path.contains('Items') && r.query['parentId'] != null).first;
      if (folder == 'emby') {
        expect(listing.path, '/Users/${server.userId}/Items');
        expect(server.requests.any((r) => r.headers.containsKey('x-emby-token')), isTrue);
        expect(films.map((e) => e.title), contains('Stereo (2022)'), reason: 'Emby names the film, the year apart');
      } else {
        expect(listing.path, '/Items');
      }
    });
  }

  test('the entry name and title rules', () {
    expect(
      jellyfinEntryName(
        const JellyfinItem(
          id: '1',
          name: 'Up/Down',
          type: 'Movie',
          mediaSources: [JellyfinMediaSource(id: 's', container: 'mov,mp4,m4a,3gp', video3DFormat: 'FullTopAndBottom')],
        ),
      ),
      'Up_Down tb.mov',
    );
    expect(jellyfinEntryName(const JellyfinItem(id: '2', name: 'pic', type: 'Photo', mediaType: 'Photo')), 'pic.jpg');
    expect(
      jellyfinEntryName(const JellyfinItem(id: '3', name: 'x', path: r'D:\Films\Big 360.MP4', type: 'Movie')),
      'Big 360.MP4',
    );
    expect(
      jellyfinTitleOf(const JellyfinItem(id: '1', name: 'Pattern', type: 'Movie', productionYear: 2024)),
      'Pattern (2024)',
    );
    expect(
      jellyfinTitleOf(const JellyfinItem(id: '1', name: 'Pattern (2024)', type: 'Movie', productionYear: 2024)),
      'Pattern (2024)',
    );
    expect(
      jellyfinTitleOf(
        const JellyfinItem(id: '1', name: 'Pilot', type: 'Episode', indexNumber: 2, parentIndexNumber: 1),
      ),
      'S01E02 Pilot',
    );
    expect(jellyfinTitleOf(const JellyfinItem(id: '1', name: 'clip', type: 'Video')), isNull);
  });

  test('the base URL of a source', () {
    NetworkSource source({String host = '192.0.2.10', int? port, String share = '', bool tls = false}) => NetworkSource(
      id: 'x',
      type: NetworkSourceType.jellyfin,
      name: 'n',
      host: host,
      port: port,
      share: share,
      useTls: tls,
    );
    expect(jellyfinBaseOf(source()).toString(), 'http://192.0.2.10:8096');
    expect(jellyfinBaseOf(source(tls: true)).toString(), 'https://192.0.2.10:8920');
    expect(jellyfinBaseOf(source(port: 443, tls: true, share: 'jellyfin/')).toString(), 'https://192.0.2.10/jellyfin');
    expect(jellyfinBaseOf(source(host: '[fd00::2]')).host, 'fd00::2');
    expect(() => jellyfinBaseOf(source(host: ' ')), throwsA(isA<NetworkFileSystemException>()));
  });
}
