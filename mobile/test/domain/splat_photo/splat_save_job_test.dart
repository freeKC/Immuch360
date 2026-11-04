// The job behind "Save to Immich" (lot L6, plan of 3 November 2026, section 6.3) against a fake server that counts
// what it is asked: the fields and headers of the upload, the metadata item from 2.5.0 on, no upload after a
// duplicate, "already there" from the record and from the heads of the splat photos of the server, a PLY converted
// as the maker converts it, the album made once, and the failures in the words of the job.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_tail.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

import 'splat_photo_fixtures.dart';
import 'splat_save_fakes.dart';

void main() {
  late Directory dir;
  late FakeSplatSaveServer server;
  late SplatSaveRecords records;
  var drawn = 0;
  var cards = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('splat_save_job');
    server = FakeSplatSaveServer();
    records = SplatSaveRecords(() async => File('${dir.path}/support/splat_saves.json'));
    drawn = 0;
    cards = 0;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  File scene(String name, [String folder = 'splat']) {
    final file = File('${dir.path}/scenes/$name')..createSync(recursive: true);
    return file..writeAsBytesSync(File('test/fixtures/$folder/$name').readAsBytesSync());
  }

  SplatSaveRequest requestOf(File file, {Uint8List? poster, bool force = false, bool album = true, String? up}) =>
      SplatSaveRequest(
        scene: file,
        sceneName: file.uri.pathSegments.last,
        sceneDate: DateTime.utc(2026, 11, 3, 15, 53),
        caption: (count) => 'Splat scene of $count gaussians. Open it with Immuch360 to explore it.',
        cardLine: (count) => '$count gaussians',
        poster: poster,
        force: force,
        album: album,
        up: up,
        software: 'Immuch360 tests',
        creatorTool: 'Immuch360 tests',
      );

  SplatSaveJob jobOf(SplatSaveRequest request, {int? maxPlyBytes}) => SplatSaveJob(
    request: request,
    server: server,
    records: records,
    workFolder: () async => Directory('${dir.path}/cache'),
    drawPoster: (spz, head, up, mark) async {
      drawn++;
      return splatPhotoFixture('poster.jpg');
    },
    drawCard: (name, line, mark) async {
      cards++;
      return splatPhotoFixture('poster.jpg');
    },
    maxPlyBytes: maxPlyBytes,
    now: () => DateTime.utc(2026, 11, 4, 12),
  );

  test('an SPZ: the fields of the plan, the checksum header, the metadata item on 2.5.0, then the album', () async {
    final spz = scene('axes_v2.spz');
    final status = await jobOf(requestOf(spz, up: 'yUp')).run();

    expect(status.state, SplatSaveState.done, reason: '$status');
    final upload = server.uploads.single;
    final source = upload.source;
    expect(source.filename, 'axes_v2_splat.jpg');
    expect(source.headers, {'x-immich-checksum': sha1Of(upload.body)});
    expect(source.deviceAssetId, 'splat-${sha1Of(upload.body)}');
    expect(source.createdAt, DateTime.utc(2026, 11, 3, 15, 53));
    expect(source.modifiedAt, DateTime.utc(2026, 11, 3, 15, 53));
    final metadata = jsonDecode(source.metadataJson!) as List;
    final value = (metadata.single as Map)['value'] as Map;
    expect((metadata.single as Map)['key'], 'immuch360');
    expect(value['kind'], 'GaussianSplat');
    expect(value['format'], 'spz');
    expect(value['version'], 2);
    expect(value['length'], spz.lengthSync());
    expect(value['sha256'], sha256.convert(spz.readAsBytesSync()).toString());
    expect(value['gaussians'], 686);
    // The scene is the end of the file, byte for byte, and the packet tells it
    expect(upload.body.sublist(upload.body.length - spz.lengthSync()), spz.readAsBytesSync());
    final xmp = SplatPhotoXmp.findIn(upload.body)!;
    expect(xmp.splatName, 'axes_v2.spz');
    expect(xmp.splatUp, 'yUp');
    expect(xmp.splatPoster, SplatPosterKind.render);
    expect(xmp.description, 'Splat scene of 686 gaussians. Open it with Immuch360 to explore it.');
    expect(drawn, 1);
    // The album, made at this first save
    expect(server.albums, {
      'album-1': [status.assetId],
    });
    expect(await records.album(server.url), 'album-1');
    // Nothing left in the cache
    expect(Directory('${dir.path}/cache').listSync(), isEmpty);
  });

  test('no metadata item on a server older than 2.5.0, nor when its version is unknown', () async {
    for (final version in [(2, 4, 0), (1, 139, 4), null]) {
      server = FakeSplatSaveServer(serverVersion: version);
      final status = await jobOf(requestOf(scene('axes_v2.spz'), force: true, album: false)).run();
      expect(status.state, SplatSaveState.done, reason: '$version');
      expect(server.uploads.single.source.metadataJson, isNull, reason: '$version');
    }
  });

  test('a 400 with the metadata item is sent once more without it', () async {
    var first = true;
    server.answer = (source) {
      if (first) {
        first = false;
        return UploadResult.error(statusCode: 400, errorMessage: 'metadata must be an array');
      }
      return UploadResult.success(remoteAssetId: 'asset-7', statusCode: 201);
    };
    final status = await jobOf(requestOf(scene('axes_v2.spz'), album: false)).run();
    expect(status.state, SplatSaveState.done);
    expect(server.uploads.map((upload) => upload.source.metadataJson != null), [true, false]);
  });

  test('a duplicate answer of bulk-upload-check stops before the upload', () async {
    server.bulkAnswer = const SplatBulkAnswer(accept: false, assetId: 'asset-held');
    final status = await jobOf(requestOf(scene('axes_v2.spz'), force: true)).run();
    expect(status.state, SplatSaveState.duplicate);
    expect(status.assetId, 'asset-held');
    expect(server.uploads, isEmpty);
    server.bulkAnswer = const SplatBulkAnswer(accept: false, assetId: 'asset-held', isTrashed: true);
    final trashed = await jobOf(requestOf(scene('axes_v2.spz'), force: true)).run();
    expect(trashed.state, SplatSaveState.inTrash);
  });

  test('the same scene saved again with another poster: already there, from the record of this device', () async {
    final spz = scene('axes_v2.spz');
    final first = await jobOf(requestOf(spz)).run();
    expect(first.state, SplatSaveState.done);
    server.calls.clear();

    final again = await jobOf(requestOf(spz, poster: splatPhotoFixture('poster_motion.jpg'))).run();
    expect(again.state, SplatSaveState.alreadyThere);
    expect(again.assetId, first.assetId);
    expect(again.savedAt, DateTime.utc(2026, 11, 4, 12));
    expect(server.calls, ['asset ${first.assetId}'], reason: 'the record, checked with the asset only');
    expect(server.uploads, hasLength(1));
  });

  test('saved from another device (no record here): found by the head of the splat photos of the server', () async {
    final spz = scene('axes_v2.spz');
    final first = await jobOf(requestOf(spz)).run();
    File('${dir.path}/support/splat_saves.json').deleteSync();
    server.calls.clear();

    final again = await jobOf(requestOf(spz)).run();
    expect(again.state, SplatSaveState.alreadyThere);
    expect(again.assetId, first.assetId);
    expect(server.calls, ['search _splat', 'head ${first.assetId}']);
  });

  test(
    'a record whose asset is gone from the server does not stop a new save; Save another copy skips the looks',
    () async {
      final spz = scene('axes_v2.spz');
      final first = await jobOf(requestOf(spz)).run();
      server.assets.remove(first.assetId);
      final again = await jobOf(requestOf(spz)).run();
      expect(again.state, SplatSaveState.done);
      expect(again.assetId, isNot(first.assetId));

      server.calls.clear();
      server.bulkAnswer = const SplatBulkAnswer(accept: true);
      final copy = await jobOf(requestOf(spz, poster: splatPhotoFixture('poster_motion.jpg'), force: true)).run();
      expect(copy.state, SplatSaveState.done);
      expect(server.calls.where((call) => call.startsWith('asset') || call.startsWith('search')), isEmpty);
      // The album made at the first save is found again, not made twice
      expect(server.albums.keys, ['album-1']);
    },
  );

  test('a PLY is converted as the maker converts it, its own sum kept as SplatSourceSha256', () async {
    final ply = scene('brush_sh3.ply');
    final status = await jobOf(requestOf(ply, album: false)).run();
    expect(status.state, SplatSaveState.done, reason: '$status');
    final upload = server.uploads.single;
    final made = writeSpzV2(readSplatPly(ply.readAsBytesSync()));
    expect(upload.body.sublist(upload.body.length - made.length), made);
    final xmp = SplatPhotoXmp.findIn(upload.body)!;
    expect(xmp.splatName, 'brush_sh3_splat.spz');
    expect(xmp.splatSourceSha256, sha256.convert(ply.readAsBytesSync()).toString());
    expect(xmp.splatSha256, sha256.convert(made).toString());
    expect(upload.source.filename, 'brush_sh3_splat.jpg');
    final check = await checkSplatPhotoTail(
      (offset, length) async => upload.body.sublist(offset, offset + length),
      fileLength: upload.body.length,
      xmp: xmp,
    );
    expect(check.problem, isNull);
    expect(check.head?.format, SplatFormat.spz);
  });

  test('a PLY above the limit of this device is not converted', () async {
    final status = await jobOf(requestOf(scene('brush_sh3.ply')), maxPlyBytes: 1000).run();
    expect(status.state, SplatSaveState.failed);
    expect(status.problem, SplatSaveProblem.plyTooLarge);
    expect(server.calls, isEmpty);
  });

  test('a version 4 whose poster cannot be drawn gets the card', () async {
    final job = SplatSaveJob(
      request: requestOf(scene('axes_v4.spz'), album: false),
      server: server,
      records: records,
      workFolder: () async => Directory('${dir.path}/cache'),
      drawPoster: (spz, head, up, mark) async => throw const FormatException('version 4 is not read here'),
      drawCard: (name, line, mark) async {
        cards++;
        expect(line, '686 gaussians');
        return splatPhotoFixture('poster.jpg');
      },
    );
    final status = await job.run();
    expect(status.state, SplatSaveState.done);
    expect(cards, 1);
    expect(SplatPhotoXmp.findIn(server.uploads.single.body)!.splatPoster, SplatPosterKind.card);
  });

  test('the failures in the words of the job: a 413, a connection closed, the quota, another refusal', () async {
    final cases = {
      UploadResult.error(statusCode: 413, errorMessage: 'Error(413) File is too large to upload'):
          SplatSaveProblem.refusedSize,
      UploadResult.error(errorMessage: 'ClientException: Connection closed while receiving data'):
          SplatSaveProblem.refusedSize,
      UploadResult.error(statusCode: 400, errorMessage: 'Quota has been exceeded!'): SplatSaveProblem.quota,
      UploadResult.error(statusCode: 500, errorMessage: 'Internal server error'): SplatSaveProblem.server,
    };
    for (final MapEntry(key: answer, value: problem) in cases.entries) {
      server = FakeSplatSaveServer(serverVersion: (2, 4, 0))..answer = (_) => answer;
      final status = await jobOf(requestOf(scene('axes_v2.spz'), force: true, album: false)).run();
      expect(status.state, SplatSaveState.failed, reason: answer.errorMessage);
      expect(status.problem, problem, reason: answer.errorMessage);
    }
  });

  test('a cancel stops the job, nothing sent and nothing left in the cache', () async {
    final job = jobOf(requestOf(scene('axes_v2.spz')));
    final states = <SplatSaveState>[];
    job.changes.listen((status) {
      states.add(status.state);
      if (status.state == SplatSaveState.drawing) {
        job.cancel();
      }
    });
    final status = await job.run();
    expect(status.state, SplatSaveState.cancelled);
    expect(server.uploads, isEmpty);
    expect(Directory('${dir.path}/cache').listSync(), isEmpty);
    expect(states.last, SplatSaveState.cancelled);
  });

  test('the records keep the last save of each scene per server, and the album of each server', () async {
    for (var i = 0; i < 3; i++) {
      await records.add(
        SplatSaveRecord(
          server: 'https://a/api',
          splatSha256: 'sum',
          assetId: 'asset-$i',
          carrierSha1: 'c$i',
          savedAt: DateTime.utc(2026, 11, i + 1),
        ),
      );
    }
    expect((await records.find('https://a/api', 'sum'))!.assetId, 'asset-2');
    expect(await records.find('https://b/api', 'sum'), isNull);
    await records.setAlbum('https://a/api', 'album-a');
    expect(await records.album('https://a/api'), 'album-a');
    expect(await records.album('https://b/api'), isNull);
    final json = jsonDecode(File('${dir.path}/support/splat_saves.json').readAsStringSync()) as Map;
    expect((json['saves'] as List).length, 1);
  });

  test('2.5.0 and later take the metadata field', () {
    expect(splatSaveTakesMetadata((2, 5, 0)), isTrue);
    expect(splatSaveTakesMetadata((2, 7, 5)), isTrue);
    expect(splatSaveTakesMetadata((3, 0, 0)), isTrue);
    expect(splatSaveTakesMetadata((2, 4, 9)), isFalse);
    expect(splatSaveTakesMetadata((1, 139, 4)), isFalse);
    expect(splatSaveTakesMetadata(null), isFalse);
  });
}
