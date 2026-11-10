// Download of a Plex film through PlexFileSystem.openDownload, against the loopback fake server (never a real server):
// the part asked with download=1 and the token in its header only, the range from the bytes already there, the
// identity of the copy, the 403 of an account without the right to download, and a whole copy through FilmTransfer,
// resumed from a partial file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/film_download/film_transfer.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';

import 'fake_plex_server.dart';

const _source = NetworkSource(
  id: '0123456789abcdef',
  type: NetworkSourceType.plex,
  name: 'Test Plex',
  host: '192.0.2.20',
  rootPath: '/',
  useTls: true,
  discoveryId: plexTestMachine,
  plex: PlexServerInfo(hash: plexTestHash),
);

const _film = '/Movies/Holidays/beach.mp4';

void main() {
  late FakePlexServer server;
  late PlexFileSystem plex;
  late Directory folder;

  setUp(() async {
    server = await FakePlexServer.start();
    plex = await PlexFileSystem.open(_source, plexTestToken, baseOverride: server.base, clientIdentifier: 'client-0');
    folder = await Directory.systemTemp.createTemp('plex_download_test');
  });
  tearDown(() async {
    await plex.close();
    await server.close();
    await folder.delete(recursive: true);
  });

  List<PlexTestRequest> partRequests() => server.requests.where((r) => r.path.startsWith('/library/parts/')).toList();

  test('asks the part with download=1, the token in its header and never in the address', () async {
    final answer = await plex.openDownload(_film);
    final bytes = await answer.bytes.expand((chunk) => chunk).toList();
    expect(bytes, plexPartBytes(21, 5000));
    expect(answer.start, 0);
    expect(answer.total, 5000);
    expect(answer.identity, '/library/parts/21/1700000000/file.mp4|5000');
    expect(answer.fileName, 'beach.mp4');
    final request = partRequests().single;
    expect(request.query, 'download=1');
    expect(request.headers['x-plex-token'], plexTestToken);
    expect(request.headers.containsKey('range'), isFalse);
    for (final sent in server.requests) {
      expect(sent.query ?? '', isNot(contains(plexTestToken)));
    }
  });

  test('asks the rest of the file with a range from the bytes already there', () async {
    final answer = await plex.openDownload(_film, from: 4000);
    final bytes = await answer.bytes.expand((chunk) => chunk).toList();
    expect(answer.start, 4000);
    expect(answer.total, 5000);
    expect(bytes, plexPartBytes(21, 5000).sublist(4000));
    expect(partRequests().single.headers['range'], 'bytes=4000-');
  });

  test('a server without ranges sends the whole file, from its start', () async {
    server.supportRanges = false;
    final answer = await plex.openDownload(_film, from: 4000);
    expect(answer.start, 0);
    expect((await answer.bytes.expand((chunk) => chunk).toList()).length, 5000);
  });

  test('nothing left after the end of the file', () async {
    final answer = await plex.openDownload(_film, from: 5000);
    expect(answer.start, 5000);
    expect(answer.total, 5000);
    expect(await answer.bytes.toList(), isEmpty);
  });

  test('an account whose owner forbids downloads gets one clear failure', () async {
    server.downloadForbidden = true;
    await expectLater(
      plex.openDownload(_film),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isDownloadForbidden, 'isDownloadForbidden', isTrue)),
    );
    // A plain read for the player still works: the owner's choice is about downloads
    expect(await plex.readRange(_film, 0, 10), plexPartBytes(21, 5000).sublist(0, 10));
  });

  test('a whole copy through FilmTransfer, resumed from a partial file', () async {
    final target = '${folder.path}${Platform.pathSeparator}beach.mp4';
    final whole = plexPartBytes(21, 5000);
    await File('$target.part').writeAsBytes(whole.sublist(0, 1234));
    final copy = FilmTransfer(
      target: target,
      identity: '/library/parts/21/1700000000/file.mp4|5000',
      open: (from, abort) => plex.openDownload(_film, from: from, abort: abort),
    );
    final result = await copy.run();
    expect(result.end, FilmTransferEnd.completed);
    expect(await File(target).readAsBytes(), whole);
    expect(partRequests().single.headers['range'], 'bytes=1234-');
  });

  test('a forbidden download stops the copy with its own failure', () async {
    server.downloadForbidden = true;
    final copy = FilmTransfer(
      target: '${folder.path}${Platform.pathSeparator}beach.mp4',
      open: (from, abort) => plex.openDownload(_film, from: from, abort: abort),
    );
    await expectLater(
      copy.run(),
      throwsA(isA<FilmTransferException>().having((e) => e.failure, 'failure', FilmDownloadFailure.forbidden)),
    );
  });
}
