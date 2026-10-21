import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/domain/services/video_location.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';

class _NoShare implements NetworkFileSystem {
  @override
  final source = const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas.local');

  @override
  Future<List<NetworkEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<NetworkEntry> stat(String path) => throw UnimplementedError();

  @override
  Future<Uint8List> readRange(String path, int offset, int length) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

/// A share in memory: its files by path, listed by folder
class _MemoryShare implements NetworkFileSystem {
  _MemoryShare(this.files, {this.id = 'nas'});

  final Map<String, Uint8List> files;
  final String id;
  final listed = <String>[];

  @override
  NetworkSource get source => NetworkSource(id: id, type: NetworkSourceType.smb, name: 'NAS', host: 'nas.local');

  NetworkEntry _entry(String path) => NetworkEntry(
    sourceId: id,
    path: path,
    isDirectory: false,
    size: files[path]!.length,
    modified: DateTime.utc(2026, 10, 1),
  );

  @override
  Future<List<NetworkEntry>> list(String path) async {
    listed.add(path);
    return [
      for (final file in files.keys)
        if (file.substring(0, file.lastIndexOf('/')) == (path == '/' ? '' : path)) _entry(file),
    ];
  }

  @override
  Future<NetworkEntry> stat(String path) async => _entry(path);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final bytes = files[path]!;
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(bytes.length, start + length));
  }

  @override
  Future<void> close() async {}
}

/// What the server says of a file, by its name
typedef _Answer = ({String? remoteId, bool isDuplicate, String? error});

void main() {
  late Directory directory;
  late UploadRecordStore records;
  late MockForegroundUploadService uploads;
  late NetworkUploadService sut;
  late List<List<String>> sent;
  late Map<String, _Answer> answers;

  /// What the server says of the assets of the files recorded, by asset id: there by default
  late Map<String, Future<bool> Function()> assets;
  late List<String> asked;
  late List<NetworkUploadItem> items;
  final fileSystem = _NoShare();

  NetworkEntry file(String path, {int size = 10}) =>
      NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: size, modified: DateTime.utc(2026, 10, 1));

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const SourceUploadCallbacks());
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('network_upload');
    records = UploadRecordStore(() async => File('${directory.path}/records.json'));
    uploads = MockForegroundUploadService();
    assets = {};
    asked = [];
    sut = NetworkUploadService(uploads, records, (remoteId) {
      asked.add(remoteId);
      return assets[remoteId]?.call() ?? Future.value(true);
    });
    sent = [];
    items = [];
    answers = {};
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final given = invocation.positionalArguments.single as List<NetworkUploadItem>;
      items.addAll(given);
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      sent.add([for (final item in given) item.entry.path]);
      for (final item in given) {
        callbacks.onProgress?.call(item.id, 5, 10);
        final answer =
            answers[item.entry.name] ?? (remoteId: 'new-${item.entry.name}', isDuplicate: false, error: null);
        final remoteId = answer.remoteId;
        if (remoteId != null) {
          callbacks.onSuccess?.call(item.id, remoteId, isDuplicate: answer.isDuplicate);
        } else {
          callbacks.onError?.call(item.id, answer.error!);
        }
      }
    });
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('sends the files and records them with their asset', () async {
    answers['b.jpg'] = (remoteId: 'old-b', isDuplicate: true, error: null);
    final progress = <String, double>{};
    final outcomes = <String, NetworkUploadOutcome>{};

    final summary = await sut.upload(
      fileSystem,
      [file('/a.jpg'), file('/b.jpg')],
      cancelToken: Completer<void>(),
      listener: NetworkUploadListener(
        onProgress: (id, value) => progress[id] = value,
        onFinished: (id, outcome) => outcomes[id] = outcome,
      ),
    );

    expect(sent, [
      ['/a.jpg', '/b.jpg'],
    ]);
    expect(summary.sent, 1);
    expect(summary.duplicates, 1);
    expect(summary.failed, 0);
    expect(summary.cancelled, isFalse);
    expect(progress, {'nas:/a.jpg': 0.5, 'nas:/b.jpg': 0.5});
    expect(outcomes, {'nas:/a.jpg': NetworkUploadOutcome.sent, 'nas:/b.jpg': NetworkUploadOutcome.duplicate});
    expect((await records.find(file('/a.jpg')))?.remoteId, 'new-a.jpg');
    expect((await records.find(file('/b.jpg')))?.remoteId, 'old-b', reason: 'the server has it too');
  });

  test('does not read again a file sent before, unchanged since, that the server still has', () async {
    await records.add(file('/a.jpg'), 'earlier');
    final outcomes = <String, NetworkUploadOutcome>{};

    final summary = await sut.upload(
      fileSystem,
      [file('/a.jpg'), file('/b.jpg')],
      cancelToken: Completer<void>(),
      listener: NetworkUploadListener(onFinished: (id, outcome) => outcomes[id] = outcome),
    );

    expect(asked, ['earlier'], reason: 'only the file recorded is asked about');
    expect(sent, [
      ['/b.jpg'],
    ]);
    expect(summary.sent, 1);
    expect(summary.duplicates, 1);
    expect(outcomes['nas:/a.jpg'], NetworkUploadOutcome.duplicate);
  });

  test('sends again a file whose asset the server deleted or trashed, and forgets the old asset', () async {
    await records.add(file('/a.jpg'), 'deleted');
    assets['deleted'] = () async => false;
    answers['a.jpg'] = (remoteId: null, isDuplicate: false, error: 'offline');

    final summary = await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
    expect(summary.duplicates, 0);
    expect(summary.failed, 1);
    expect(await records.find(file('/a.jpg')), isNull, reason: 'not on the server, whatever became of the send');
  });

  test('sends again a file the server cannot tell about, and keeps its record until it answers', () async {
    await records.add(file('/a.jpg'), 'earlier');
    assets['earlier'] = () async => throw Exception('offline');
    answers['a.jpg'] = (remoteId: null, isDuplicate: false, error: 'offline');

    await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
    expect((await records.find(file('/a.jpg')))?.remoteId, 'earlier');
  });

  test('records a file as it was right before it was sent, not as it was listed', () async {
    final listed = file('/a.jpg', size: 10);
    final grown = NetworkEntry(
      sourceId: 'nas',
      path: '/a.jpg',
      isDirectory: false,
      size: 25,
      modified: DateTime.utc(2026, 10, 1, 0, 5),
    );
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final item = (invocation.positionalArguments.single as List<NetworkUploadItem>).single;
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      callbacks.onSending?.call(item.id, grown);
      callbacks.onSuccess?.call(item.id, 'new-a', isDuplicate: false);
    });

    await sut.upload(fileSystem, [listed], cancelToken: Completer<void>());

    expect((await records.find(grown))?.remoteId, 'new-a');
    expect(await records.find(listed), isNull);
  });

  test('stops asking the server about the files recorded once cancelled', () async {
    final cancelToken = Completer<void>();
    await records.add(file('/a.jpg'), 'asset-a');
    await records.add(file('/b.jpg'), 'asset-b');
    assets['asset-a'] = () async {
      cancelToken.complete();
      return true;
    };

    final summary = await sut.upload(fileSystem, [file('/a.jpg'), file('/b.jpg')], cancelToken: cancelToken);

    expect(asked, ['asset-a']);
    expect(summary.cancelled, isTrue);
  });

  test('sends again a file that changed since it was sent', () async {
    await records.add(file('/a.jpg'), 'earlier');

    await sut.upload(fileSystem, [file('/a.jpg', size: 11)], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
    expect(asked, isEmpty, reason: 'no record of the file as it is now');
  });

  test('counts the failures, says why the last one failed, and does not record them', () async {
    answers['a.jpg'] = (remoteId: null, isDuplicate: false, error: 'Quota has been exceeded!');

    final summary = await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>());

    expect(summary.failed, 1);
    expect(summary.lastError, 'Quota has been exceeded!');
    expect(await records.find(file('/a.jpg')), isNull);
  });

  test('leaves out the folders and the files given twice', () async {
    await sut.upload(fileSystem, [
      file('/a.jpg'),
      const NetworkEntry(sourceId: 'nas', path: '/Holidays', isDirectory: true),
      file('/a.jpg'),
    ], cancelToken: Completer<void>());

    expect(sent, [
      ['/a.jpg'],
    ]);
  });

  test('says when it was cancelled', () async {
    final summary = await sut.upload(fileSystem, [file('/a.jpg')], cancelToken: Completer<void>()..complete());

    expect(summary.cancelled, isTrue);
  });

  group('drone files', () {
    late List<(String, double, double)> placedVideos;
    late Map<String, NetworkMediaInfo?> infos;

    NetworkUploadService droneService({VideoPlaceOutcome outcome = VideoPlaceOutcome.placed}) => NetworkUploadService(
      uploads,
      records,
      (remoteId) async => true,
      mediaInfo: (fileSystem, entry) async => infos[entry.name],
      placeVideo: (remoteId, latitude, longitude) async {
        placedVideos.add((remoteId, latitude, longitude));
        return outcome;
      },
    );

    setUp(() {
      placedVideos = [];
      infos = {};
    });

    Uint8List srt(double latitude, double longitude) => Uint8List.fromList(
      utf8.encode(
        '1\n00:00:00,000 --> 00:00:00,033\n<font size="28">FrameCnt: 1, DiffTime: 33ms\n2026-10-21 14:31:00.000\n'
        '[latitude: 0.000000] [longitude: 0.000000] </font>\n\n'
        '2\n00:00:00,033 --> 00:00:00,066\n<font size="28">FrameCnt: 2, DiffTime: 33ms\n2026-10-21 14:31:00.033\n'
        '[latitude: $latitude] [longitude: $longitude] </font>\n',
      ),
    );

    test('sends a sidecar with the spheres without GPano tags, only with the option on', () async {
      final share = _MemoryShare({
        '/DJI_0042.JPG': Uint8List(10),
        '/DJI_0043.JPG': Uint8List(10),
        '/PANO_0001.JPG': Uint8List(10),
      });
      infos['DJI_0042.JPG'] = const NetworkMediaInfo(cameraEquirect: true, frameWidth: 8192, frameHeight: 4096);
      // A flat photo, and a sphere whose GPano tags already say so
      infos['DJI_0043.JPG'] = const NetworkMediaInfo(frameWidth: 4000, frameHeight: 3000);
      infos['PANO_0001.JPG'] = const NetworkMediaInfo(
        gpano: (projectionType: 'equirectangular', crop: null, initialView: null),
        cameraEquirect: true,
        frameWidth: 8192,
        frameHeight: 4096,
      );
      answers['PANO_0001.JPG'] = (remoteId: 'old-pano', isDuplicate: true, error: null);
      final entries = [for (final path in share.files.keys) await share.stat(path)];

      final off = await droneService().upload(share, entries, cancelToken: Completer<void>());
      expect(items.every((item) => item.sidecarXmp == null), isTrue);
      expect(off.spheresTagged, 0);

      items.clear();
      await records.load().then((loaded) => loaded.clear());
      final on = await droneService().upload(
        share,
        entries,
        cancelToken: Completer<void>(),
        options: const NetworkUploadOptions(tagSpheres: true),
      );
      final sidecars = {for (final item in items) item.entry.name: item.sidecarXmp};
      expect(sidecars['DJI_0042.JPG'], contains('GPano:FullPanoWidthPixels="8192"'));
      expect(sidecars['DJI_0043.JPG'], isNull);
      expect(sidecars['PANO_0001.JPG'], isNull);
      expect(on.spheresTagged, 1);
    });

    test('counts a tagged sphere the server had already apart', () async {
      final share = _MemoryShare({'/DJI_0042.JPG': Uint8List(10)});
      infos['DJI_0042.JPG'] = const NetworkMediaInfo(cameraEquirect: true, frameWidth: 8192, frameHeight: 4096);
      answers['DJI_0042.JPG'] = (remoteId: 'old', isDuplicate: true, error: null);

      final summary = await droneService().upload(
        share,
        [await share.stat('/DJI_0042.JPG')],
        cancelToken: Completer<void>(),
        options: const NetworkUploadOptions(tagSpheres: true),
      );

      expect(summary.spheresTagged, 0);
      expect(summary.spheresAlreadyThere, 1);
    });

    test('skips the files the server refuses, with their names', () async {
      final share = _MemoryShare({
        '/CAM_0001_D.OSV': Uint8List(10),
        '/GS010013.360': Uint8List(10),
        '/a.jpg': Uint8List(10),
      });
      final outcomes = <String, NetworkUploadOutcome>{};

      final summary = await droneService().upload(
        share,
        [for (final path in share.files.keys) await share.stat(path)],
        cancelToken: Completer<void>(),
        listener: NetworkUploadListener(onFinished: (id, outcome) => outcomes[id] = outcome),
      );

      expect(sent, [
        ['/a.jpg'],
      ]);
      expect(summary.refused, ['CAM_0001_D.OSV', 'GS010013.360']);
      expect(outcomes['nas:/CAM_0001_D.OSV'], NetworkUploadOutcome.refused);
    });

    test('places each video with an .SRT beside it once, from its first fix, new or duplicate', () async {
      final share = _MemoryShare({
        '/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4': Uint8List(10),
        '/DCIM/DJI_001/DJI_20261021143100_0002_D.SRT': srt(45.25, 6.5),
        '/DCIM/DJI_001/DJI_20261021143200_0003_D.MP4': Uint8List(10),
        '/DCIM/DJI_001/dji_20261021143200_0003_d.srt': srt(44.75, 5.5),
        // No flight data
        '/DCIM/DJI_001/DJI_20261021143300_0004_D.MP4': Uint8List(10),
      });
      answers['DJI_20261021143200_0003_D.MP4'] = (remoteId: 'old-3', isDuplicate: true, error: null);
      final videos = [
        for (final path in share.files.keys)
          if (path.endsWith('.MP4')) await share.stat(path),
      ];

      final summary = await droneService().upload(share, videos, cancelToken: Completer<void>());

      expect(placedVideos, [('new-DJI_20261021143100_0002_D.MP4', 45.25, 6.5), ('old-3', 44.75, 5.5)]);
      expect(summary.placed, 2);
      expect(share.listed, ['/DCIM/DJI_001'], reason: 'the folder is listed once');
    });

    test('counts the places that wait for the server, and places nothing with the option off', () async {
      final share = _MemoryShare({'/DJI_0002_D.MP4': Uint8List(10), '/DJI_0002_D.SRT': srt(45.25, 6.5)});
      final video = await share.stat('/DJI_0002_D.MP4');

      final waiting = await droneService(
        outcome: VideoPlaceOutcome.pending,
      ).upload(share, [video], cancelToken: Completer<void>());
      expect(waiting.placed, 0);
      expect(waiting.placesPending, 1);

      placedVideos.clear();
      await records.load().then((loaded) => loaded.clear());
      await droneService().upload(
        share,
        [video],
        cancelToken: Completer<void>(),
        options: const NetworkUploadOptions(placeVideos: false),
      );
      expect(placedVideos, isEmpty);
    });

    test('records the files of a drone by their name, size and date, sent once whatever the plug', () async {
      final viaDrone = _MemoryShare({'/DCIM/DJI_001/DJI_0001.JPG': Uint8List(10)}, id: 'tree:drone');
      final viaReader = _MemoryShare({'/DJI_001/DJI_0001.JPG': Uint8List(10)}, id: 'tree:reader');

      await droneService().upload(viaDrone, [
        await viaDrone.stat('/DCIM/DJI_001/DJI_0001.JPG'),
      ], cancelToken: Completer<void>());
      final again = await droneService().upload(viaReader, [
        await viaReader.stat('/DJI_001/DJI_0001.JPG'),
      ], cancelToken: Completer<void>());

      expect(sent.expand((batch) => batch), ['/DCIM/DJI_001/DJI_0001.JPG'], reason: 'not sent again');
      expect(again.duplicates, 1);
      expect(networkDeviceAssetId(await viaDrone.stat('/DCIM/DJI_001/DJI_0001.JPG')), startsWith('import-'));
      expect(
        networkDeviceAssetId(await viaDrone.stat('/DCIM/DJI_001/DJI_0001.JPG')),
        networkDeviceAssetId(await viaReader.stat('/DJI_001/DJI_0001.JPG')),
      );
    });
  });
}
