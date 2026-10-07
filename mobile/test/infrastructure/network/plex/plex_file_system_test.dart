import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';

import 'fake_plex_server.dart';

NetworkSource _source({String rootPath = '/', String? discoveryId = plexTestMachine}) => NetworkSource(
  id: '0123456789abcdef',
  type: NetworkSourceType.plex,
  name: 'Test Plex',
  host: '192.0.2.20',
  rootPath: rootPath,
  useTls: true,
  discoveryId: discoveryId,
  plex: const PlexServerInfo(hash: plexTestHash),
);

/// A port where nothing listens
Future<int> _deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late FakePlexServer server;

  setUp(() async => server = await FakePlexServer.start());
  tearDown(() => server.close());

  Future<PlexFileSystem> open({
    NetworkSource? source,
    String? token = plexTestToken,
    int pageSize = PlexFileSystem.defaultPageSize,
    Uri? local,
    Uri? public,
    bool atHome = true,
    PlexLearnedAddressStore? learned,
  }) async {
    final fileSystem = await PlexFileSystem.open(
      source ?? _source(),
      token,
      baseOverride: local ?? (atHome ? server.base : null),
      publicBaseOverride: public,
      pageSize: pageSize,
      clientIdentifier: 'client-test-0000',
      learned: learned,
    );
    addTearDown(fileSystem.close);
    return fileSystem;
  }

  List<String> namesOf(List<NetworkEntry> entries) => [for (final e in entries) e.name];

  test('lists the photo, movie and show sections at the root, and sends the headers of the app', () async {
    final plex = await open();
    final root = await plex.list('/');
    expect(namesOf(root), ['Movies', 'Photos', 'Series']);
    expect(root.every((e) => e.isDirectory), isTrue);
    expect(plex.isOutsideHome, isFalse);

    final identity = server.requests.firstWhere((r) => r.path == '/identity');
    expect(identity.headers.containsKey('x-plex-token'), isFalse, reason: '/identity needs no token');
    final sections = server.requests.firstWhere((r) => r.path == '/library/sections');
    expect(sections.headers['x-plex-token'], plexTestToken);
    expect(sections.headers['accept'], 'application/json');
    expect(sections.headers['x-plex-client-identifier'], 'client-test-0000');
    expect(sections.headers['x-plex-product'], 'Immuch360');
    expect(sections.headers['x-plex-device-name'], 'Immuch360');
    expect(sections.headers['x-plex-platform'], isNotEmpty);
    expect(server.requests.any((r) => (r.query ?? '').contains(plexTestToken)), isFalse, reason: 'never in a URL');
  });

  test('lists a section page by page, folders first, names made unique', () async {
    final plex = await open(pageSize: 2);
    final movies = await plex.list('/Movies');
    expect(namesOf(movies), ['Holidays', 'holidays (2)', 'a.mp4', 'b.jpg']);
    final pages = server.requests.where((r) => r.path == '/library/sections/1/folder').toList();
    expect([for (final p in pages) p.headers['x-plex-container-start']], ['0', '2']);
    expect(pages.every((p) => p.headers['x-plex-container-size'] == '2'), isTrue);

    final photo = movies.last;
    expect(photo.size, 600);
    expect(photo.mimeType, 'image/jpeg');
    expect((photo.width, photo.height), (4000, 2000));
    expect(photo.modified, DateTime.fromMillisecondsSinceEpoch((1600000000 + 12) * 1000, isUtc: true));
    expect(photo.thumbnailUrl, isNull, reason: 'Plex pictures need the token: through thumbnail() only');
  });

  test('pages without totalSize go on while full', () async {
    server.withTotals = false;
    final plex = await open(pageSize: 2);
    expect(namesOf(await plex.list('/Movies')), hasLength(4));
    final starts = [
      for (final r in server.requests.where((r) => r.path == '/library/sections/1/folder'))
        r.headers['x-plex-container-start'],
    ];
    expect(starts, ['0', '2', '4']);
  });

  test('names the files after their names on the disk, those of Windows too', () async {
    final plex = await open();
    final holidays = await plex.list('/Movies/Holidays');
    expect(namesOf(holidays), ['beach (2).mp4', 'beach.mp4']);
    final beach = holidays.firstWhere((e) => e.name == 'beach.mp4');
    expect(beach.size, 5000);
    expect(beach.durationMs, 60000);
  });

  test('stat tells sizes, asking the server for a part without one', () async {
    final plex = await open(source: _source(rootPath: '/Movies/Holidays'));
    expect((await plex.stat('/')).isDirectory, isTrue);
    expect((await plex.stat('/Movies/Holidays/beach.mp4')).size, 5000);
    final unknown = await plex.stat('/Movies/Holidays/beach (2).mp4');
    expect(unknown.size, 3000);
    final sizeRequest = server.requests.lastWhere((r) => r.path.startsWith('/library/parts/22/'));
    expect(sizeRequest.headers['range'], 'bytes=0-0');
    expect(sizeRequest.headers['x-plex-token'], plexTestToken);
    await expectLater(
      plex.stat('/Movies/Holidays/nothing.mp4'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
  });

  test('reads ranges of the original part, clamped to its size', () async {
    final plex = await open();
    final whole = plexPartBytes(21, 5000);
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 100, 50), whole.sublist(100, 150));
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 4990, 100), whole.sublist(4990));
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 5000, 10), isEmpty);
    final read = server.requests.lastWhere((r) => r.path.startsWith('/library/parts/21/'));
    expect(read.headers['range'], 'bytes=4990-4999', reason: 'never past the end, which some servers refuse');
    expect(read.headers['accept-encoding'], 'identity');
    expect(read.headers['x-plex-token'], plexTestToken);
    expect(read.query, isNull, reason: 'the token goes in the header only');
  });

  test('reads from a server that ignores ranges', () async {
    server.supportRanges = false;
    final plex = await open();
    final whole = plexPartBytes(21, 5000);
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 0, 10), whole.sublist(0, 10));
    expect(await plex.readRange('/Movies/Holidays/beach.mp4', 2000, 10), whole.sublist(2000, 2010));
  });

  test('a token refused or without the right to read is an authentication error', () async {
    await expectLater(
      open(token: 'WRONG-TOKEN-000000000'),
      throwsA(
        isA<PlexFileSystemException>()
            .having((e) => e.isAuthentication, 'isAuthentication', isTrue)
            .having((e) => e.failure, 'failure', PlexFailure.tokenRefused),
      ),
    );
    final plex = await open();
    server.forbidden = true;
    await expectLater(
      plex.list('/Movies'),
      throwsA(
        isA<PlexFileSystemException>()
            .having((e) => e.isAuthentication, 'isAuthentication', isTrue)
            .having((e) => e.failure, 'failure', PlexFailure.tokenForbidden),
      ),
    );
    server.forbidden = false;
    server.token = 'REVOKED';
    await expectLater(
      plex.readRange('/Movies/a.mp4', 0, 10),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
    );
  });

  test('opens nothing without a token', () async {
    await expectLater(
      open(token: null),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
    );
    expect(server.requests, isEmpty);
  });

  test('walks again once from the top when a key changed, by a 404 or an empty listing', () async {
    final plex = await open();
    expect(namesOf(await plex.list('/Movies/Holidays')), hasLength(2));

    // A rescan gives the folder another id: the old one answers 404
    server.listings['/library/sections/1/folder']![0] = plexFolder('/library/sections/1/folder?parent=201', 'Holidays');
    server.listings['/library/sections/1/folder?parent=201'] =
        server.listings['/library/sections/1/folder?parent=101']!;
    server.statuses['/library/sections/1/folder?parent=101'] = 404;
    expect(namesOf(await plex.list('/Movies/Holidays')), hasLength(2));

    // Again, the old id now answering an empty listing as Plex does: the section tells the new one
    server.listings['/library/sections/1/folder']![0] = plexFolder('/library/sections/1/folder?parent=301', 'Holidays');
    server.listings['/library/sections/1/folder?parent=301'] =
        server.listings['/library/sections/1/folder?parent=201']!;
    server.listings.remove('/library/sections/1/folder?parent=201');
    final before = server.requests.length;
    expect(namesOf(await plex.list('/Movies/Holidays')), hasLength(2));
    expect(
      [for (final r in server.requests.skip(before)) r.query == null ? r.path : '${r.path}?${r.query}'],
      ['/library/sections/1/folder?parent=201', '/library/sections/1/folder', '/library/sections/1/folder?parent=301'],
      reason: 'the listing of the parent tells the new key, without walking again from the top',
    );

    // A folder that is gone: its key lists empty, and the section no longer has it
    server.listings['/library/sections/1/folder']!.removeAt(0);
    server.listings.remove('/library/sections/1/folder?parent=301');
    await expectLater(
      plex.list('/Movies/Holidays'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
  });

  test('a folder left empty is checked against its parent once, and what was shown stays known', () async {
    server.listings['/library/sections/1/folder']!.add(plexFolder('/library/sections/1/folder?parent=104', 'Empty'));
    final plex = await open();
    final beach = (await plex.list('/Movies/Holidays')).firstWhere((e) => e.name == 'beach.mp4');
    final before = server.requests.length;
    expect(await plex.list('/Movies/Empty'), isEmpty);
    expect(
      [for (final r in server.requests.skip(before)) r.query == null ? r.path : '${r.path}?${r.query}'],
      ['/library/sections/1/folder?parent=104', '/library/sections/1/folder'],
    );
    expect(await plex.thumbnail(beach, 256), isNotNull, reason: 'no key was forgotten');

    final again = server.requests.length;
    expect(await plex.list('/Movies/Empty'), isEmpty);
    expect(server.requests.length - again, 1, reason: 'a folder found empty is not checked again within a minute');
  });

  test('a walk from the top does not wait for a listing under way with an old key', () async {
    final plex = await open();
    final whole = plexPartBytes(121, 5000);
    expect(namesOf(await plex.list('/Movies/Holidays')), hasLength(2));

    // A rescan: new keys for the folder and its files, the old ones answering 404, the folder slowly
    server.listings['/library/sections/1/folder']![0] = plexFolder('/library/sections/1/folder?parent=201', 'Holidays');
    server.listings['/library/sections/1/folder?parent=201'] = [
      plexFile(121, '/data/movies/Holidays/beach.mp4', 5000),
      plexFile(122, r'D:\Plex\Holidays\beach.mp4', null, thumb: false),
    ];
    server.partSizes
      ..remove(21)
      ..[121] = 5000;
    server.statuses['/library/sections/1/folder?parent=101'] = 404;
    server.delays['/library/sections/1/folder?parent=101'] = const Duration(seconds: 1);

    final listing = plex.list('/Movies/Holidays');
    final read = plex.readRange('/Movies/Holidays/beach.mp4', 0, 4);
    expect(await read, whole.sublist(0, 4));
    expect(namesOf(await listing), hasLength(2));
  });

  test('a part gone is looked for again once, then not found', () async {
    final plex = await open();
    await plex.list('/Movies');
    server.partSizes.remove(11);
    await expectLater(
      plex.readRange('/Movies/a.mp4', 0, 10),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
  });

  test('shows the albums of a photo section whose folder view does not answer', () async {
    final plex = await open();
    expect(namesOf(await plex.list('/Photos')), ['Summer', 'loose.jpg']);
    expect(namesOf(await plex.list('/Photos/Summer')), ['pano.jpg']);
    expect(await plex.readRange('/Photos/Summer/pano.jpg', 0, 4), plexPartBytes(52, 400).sublist(0, 4));
  });

  test('refuses another server behind the right certificate, before any token goes', () async {
    server.machineIdentifier = '0000000000000000000000000000000000000002';
    await expectLater(
      open(),
      throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.otherServer)),
    );
    expect(server.requests.every((r) => r.path == '/identity' && !r.headers.containsKey('x-plex-token')), isTrue);
  });

  test('does not follow a redirect, which would take the token elsewhere', () async {
    final elsewhere = await FakePlexServer.start();
    addTearDown(elsewhere.close);
    server.redirects['/library/sections/1/folder'] = '${elsewhere.base}/library/sections/1/folder';
    final plex = await open();
    await expectLater(
      plex.list('/Movies'),
      throwsA(isA<PlexFileSystemException>().having((e) => e.message, 'message', contains('elsewhere'))),
    );
    expect(elsewhere.requests, isEmpty);
  });

  group('addresses', () {
    late FakePlexServer outside;

    setUp(() async => outside = await FakePlexServer.start());
    tearDown(() => outside.close());

    test('at home first: the address outside home is not asked when home answers at once', () async {
      final plex = await open(public: outside.base);
      expect(plex.isOutsideHome, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(outside.requests, isEmpty);
    });

    test('outside home as soon as the address at home fails', () async {
      final watch = Stopwatch()..start();
      final plex = await open(local: Uri.parse('http://127.0.0.1:${await _deadPort()}'), public: outside.base);
      expect(plex.isOutsideHome, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(namesOf(await plex.list('/')), contains('Movies'));
    });

    test('outside home 400 ms later when home is slow, the slow one stopped', () async {
      server.identityDelay = const Duration(seconds: 3);
      final watch = Stopwatch()..start();
      final plex = await open(public: outside.base);
      expect(plex.isOutsideHome, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('tells why when no address answers', () async {
      await expectLater(
        open(
          local: Uri.parse('http://127.0.0.1:${await _deadPort()}'),
          public: Uri.parse('http://127.0.0.1:${await _deadPort()}'),
        ),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.unreachableOutsideHome)),
      );
      await expectLater(
        open(local: Uri.parse('http://127.0.0.1:${await _deadPort()}')),
        throwsA(isA<PlexFileSystemException>().having((e) => e.failure, 'failure', PlexFailure.unreachable)),
      );
    });

    test('a read that fails on the network chooses the address again, once', () async {
      final plex = await open(public: outside.base);
      await plex.list('/Movies');
      expect(plex.isOutsideHome, isFalse);
      await server.close();
      expect(await plex.readRange('/Movies/a.mp4', 0, 4), plexPartBytes(11, 1000).sublist(0, 4));
      expect(plex.isOutsideHome, isTrue);
    });
  });

  test('the address outside home: the one typed, through the port the server told when none is typed', () {
    final told = PlexLearnedAddress(host: '203.0.113.7', port: 32401, at: DateTime.utc(2026, 10, 7));
    PlexServerInfo info({String? host, int? port}) =>
        PlexServerInfo(hash: plexTestHash, publicHost: host, publicPort: port);

    expect(plexPublicAddress(info(), null), isNull);
    expect(plexPublicAddress(info(), told), (host: '203.0.113.7', port: 32401));
    expect(plexPublicAddress(info(port: 40000), told), (host: '203.0.113.7', port: 40000), reason: 'a port alone');
    expect(plexPublicAddress(info(port: 40000), null), isNull);
    expect(plexPublicAddress(info(host: 'home.example.org'), told), (host: 'home.example.org', port: 32401));
    expect(plexPublicAddress(info(host: 'home.example.org'), null), (host: 'home.example.org', port: 32400));
    expect(plexPublicAddress(info(host: 'home.example.org', port: 443), told), (host: 'home.example.org', port: 443));
  });

  test('keeps what the server tells of its address outside home, once open at home', () async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    addTearDown(() async {
      await store.dispose();
      await db.close();
    });
    final learned = PlexLearnedAddressStore(store);
    final plex = await open(learned: learned);
    for (var i = 0; i < 50 && learned.read(plex.source.id) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final told = learned.read(plex.source.id);
    expect((told?.host, told?.port, told?.mapping), ('203.0.113.7', 32401, 'mapped'));
    final account = server.requests.firstWhere((r) => r.path == '/myplex/account');
    expect(account.headers['x-plex-token'], plexTestToken);
  });

  group('thumbnails', () {
    test('come from the photo transcoder with the token in the header', () async {
      final plex = await open();
      final beach = (await plex.list('/Movies/Holidays')).firstWhere((e) => e.name == 'beach.mp4');
      expect(await plex.thumbnail(beach, 256), Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]));
      final request = server.requests.lastWhere((r) => r.path == '/photo/:/transcode');
      expect(Uri(query: request.query).queryParameters, {
        'width': '256',
        'height': '256',
        'minSize': '1',
        'upscale': '0',
        'url': '/library/metadata/21/thumb/1700000000',
      });
      expect(request.headers['x-plex-token'], plexTestToken);
      expect(request.query, isNot(contains(plexTestToken)));
    });

    test('are null for an entry without one, or that the server does not have', () async {
      final plex = await open();
      final entries = await plex.list('/Movies/Holidays');
      final count = server.requests.length;
      expect(await plex.thumbnail(entries.firstWhere((e) => e.name == 'beach (2).mp4'), 256), isNull);
      expect(server.requests.length, count, reason: 'no thumb, no request');
      final movies = await plex.list('/Movies');
      expect(await plex.thumbnail(movies.firstWhere((e) => e.name == 'a.mp4'), 256), isNull);
      expect(
        await plex.thumbnail(const NetworkEntry(sourceId: 'x', path: '/Movies/unknown.mp4', isDirectory: false), 256),
        isNull,
      );
    });
  });

  test('a closed file system reads nothing more', () async {
    final plex = await open();
    await plex.close();
    await expectLater(plex.list('/Movies'), throwsA(isA<NetworkFileSystemException>()));
  });
}
