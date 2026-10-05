// Where the calibration of a raw dual fisheye file comes from: its trailer, the calibration kept for its camera or for
// its camera model, or the nominal values of an X3, read from a reader, the copy on the device, or the server with range
// requests (its head only when the server ignores them).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/raw/dji_osv.stub.dart';
import '../../fixtures/raw/insta360.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/remote_asset_factory.dart';

/// Reads [file] as a local file or a server does: fewer bytes at the end, none past it. Records each read.
ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

// Raw accelerometer values of 32 g full scale (1024 per g) around the gravity of the X3 photo
const _x3Raw = (32768 - 1028, 32768 - 127, 32768 + 84);

/// An X3 photo: the head of a JPEG with its MakerNote, then IMU samples, a thumbnail and the metadata
Uint8List _x3Photo({List<int>? metadata, bool imu = true}) => insta360File([
  if (imu) insta360Record(3, rawImuSamples([_x3Raw, _x3Raw])),
  insta360Record(2, List.filled(2000, 0x55)),
  insta360Record(1, metadata ?? x3Metadata(), format: 1),
], body: insta360PhotoHead());

Matcher _closeToList(List<double> expected, [double delta = 1e-6]) => predicate<List<double>>(
  (values) =>
      values.length == expected.length &&
      [for (var i = 0; i < values.length; i++) (values[i] - expected[i]).abs() <= delta].every((close) => close),
  'a list within $delta of $expected',
);

/// Serves [file] at [path] with range requests, suffix ranges included, as the server does (see [_NoRangeServer] for
/// one behind a proxy that drops them)
MockClient _server(Uint8List file, {String path = '/api/assets/remote/original', List<String>? log}) =>
    MockClient((request) async {
      final range = request.headers['range'] ?? '';
      log?.add(range);
      if (request.url.path != path) {
        return http.Response('', 404);
      }
      final suffix = RegExp(r'^bytes=-(\d+)$').firstMatch(range);
      final span = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
      final int start;
      final int end;
      if (suffix != null) {
        start = math.max(0, file.length - int.parse(suffix.group(1)!));
        end = file.length - 1;
      } else if (span != null) {
        start = int.parse(span.group(1)!);
        end = math.min(file.length - 1, int.parse(span.group(2)!));
      } else {
        return http.Response.bytes(file, 200);
      }
      return http.Response.bytes(
        Uint8List.sublistView(file, start, end + 1),
        206,
        headers: {'content-range': 'bytes $start-$end/${file.length}'},
      );
    });

/// Answers every request with 200 and the whole of [file], whatever its range, as a server behind a proxy that ignores
/// ranges does; sends it in chunks of 1 KB and counts the bytes sent, so that a transfer cut short shows
class _NoRangeServer extends http.BaseClient {
  _NoRangeServer(this.file);

  final Uint8List file;

  /// The range header of each request
  final ranges = <String>[];

  /// Bytes sent, over all the requests
  var sent = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    ranges.add(request.headers['range'] ?? '');
    Stream<List<int>> body() async* {
      for (var start = 0; start < file.length; start += 1024) {
        final chunk = Uint8List.sublistView(file, start, math.min(file.length, start + 1024));
        sent += chunk.length;
        yield chunk;
      }
    }

    return http.StreamedResponse(body(), 200, contentLength: file.length);
  }
}

/// The MakerNote of a photo taken with the camera leaning, far from the gravity of [_x3Photo]
const _leaningMakerNote = '-0.500000_-0.850000_0.150000_0.010000_0.020000_0.030000';
const _leaningAccelerometer = [-0.5, -0.85, 0.15];

void main() {
  late Directory directory;
  late DualFisheyeCalibrationStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('dual_fisheye_provider');
    store = DualFisheyeCalibrationStore(() async => File('${directory.path}/calibrations.json'));
  });

  tearDown(() => directory.deleteSync(recursive: true));

  group('resolveDualFisheyeCalibration', () {
    test('takes the calibration of the trailer, levelled by its IMU, and keeps it for the camera', () async {
      final file = _x3Photo();

      final resolved = await resolveDualFisheyeCalibration(
        read: _reader(file),
        fileSize: file.length,
        isPhoto: true,
        store: store,
      );

      final calibration = resolved.calibration;
      expect(resolved.readFailed, isFalse);
      expect(calibration.source, DualFisheyeSource.file);
      expect(calibration.model, DualFisheyeModel.mei);
      expect(calibration.serial, x3Serial);
      expect(calibration.canvasSquare, 5952);
      expect(calibration.downBody, _closeToList(downBodyFromAccelerometer([-1028 / 1024, -127 / 1024, 84 / 1024])));
      await pumpEventQueue();
      expect((await store.forSerial(x3Serial))?.source, DualFisheyeSource.cachedSerial);
    });

    test('levels a photo without IMU samples with the sample of its MakerNote', () async {
      final file = _x3Photo(imu: false);

      final calibration = (await resolveDualFisheyeCalibration(
        read: _reader(file),
        fileSize: file.length,
        isPhoto: true,
        store: store,
      )).calibration;

      expect(calibration.source, DualFisheyeSource.file);
      expect(calibration.downBody, _closeToList(downBodyFromAccelerometer([-1.003906, -0.124023, 0.082031])));
    });

    test('takes the calibration kept for the camera when the trailer has none', () async {
      final kept = await resolveDualFisheyeCalibration(
        read: _reader(_x3Photo()),
        fileSize: _x3Photo().length,
        isPhoto: true,
        store: store,
      );
      await pumpEventQueue();
      final file = _x3Photo(metadata: x3Metadata(offsetV1: null, offsetV3: null));

      final calibration = (await resolveDualFisheyeCalibration(
        read: _reader(file),
        fileSize: file.length,
        isPhoto: true,
        store: store,
      )).calibration;

      expect(calibration.source, DualFisheyeSource.cachedSerial);
      expect(calibration.serial, x3Serial);
      expect(calibration.downBody, _closeToList(kept.calibration.downBody));
      expect(
        [for (final lens in calibration.lenses) lens.toJson()],
        [for (final lens in kept.calibration.lenses) lens.toJson()],
      );
    });

    test('falls back on the nominal values of an X3, levelled by the MakerNote of a photo', () async {
      final file = Uint8List.fromList([...insta360PhotoHead(), 0xff, 0xd9]);

      final resolved = await resolveDualFisheyeCalibration(
        read: _reader(file),
        fileSize: file.length,
        isPhoto: true,
        store: store,
        frameSquare: 1440,
      );

      expect(resolved.readFailed, isFalse);
      expect(resolved.calibration.source, DualFisheyeSource.nominal);
      expect(resolved.calibration.canvasSquare, 1440);
      expect(resolved.calibration.downBody, _closeToList(downBodyFromAccelerometer([-1.003906, -0.124023, 0.082031])));
      expect(resolved.calibration.cameraModel, x3Model, reason: 'named by the EXIF');
    });

    test(
      'takes the last calibration of the model a photo without trailer names in its EXIF, levelled by its MakerNote',
      () async {
        // An earlier photo of the camera, with its trailer
        final kept = await resolveDualFisheyeCalibration(
          read: _reader(_x3Photo()),
          fileSize: _x3Photo().length,
          isPhoto: true,
          store: store,
        );
        await pumpEventQueue();
        // A member of an HDR group: no trailer, and the EXIF names the model, not the camera
        final file = Uint8List.fromList([...insta360PhotoHead(makerNote: _leaningMakerNote), 0xff, 0xd9]);

        final resolved = await resolveDualFisheyeCalibration(
          read: _reader(file),
          fileSize: file.length,
          isPhoto: true,
          store: store,
          frameSquare: 1440,
        );

        final calibration = resolved.calibration;
        expect(resolved.readFailed, isFalse);
        expect(calibration.source, DualFisheyeSource.cachedSerial);
        expect(calibration.cameraModel, x3Model);
        expect(calibration.canvasSquare, 5952);
        expect(
          [for (final lens in calibration.lenses) lens.toJson()],
          [for (final lens in kept.calibration.lenses) lens.toJson()],
        );
        expect(calibration.downBody, _closeToList(downBodyFromAccelerometer(_leaningAccelerometer)));
      },
    );

    test('prefers the calibration of the camera to the last one of its model', () async {
      final own = parseInsta360OffsetV3(x3OffsetV3)!.copyWith(serial: x3Serial, cameraModel: x3Model);
      await store.remember(x3Serial, own);
      // Another X3, seen last
      await store.remember('OTHER', own.copyWith(canvasSquare: 6000));

      Future<DualFisheyeCalibration> resolve(Uint8List file) async => (await resolveDualFisheyeCalibration(
        read: _reader(file),
        fileSize: file.length,
        isPhoto: true,
        store: store,
      )).calibration;

      // The camera named by a trailer without calibration, by the EXIF, then a camera never seen
      final byTrailer = await resolve(_x3Photo(metadata: x3Metadata(offsetV1: null, offsetV3: null)));
      final byExif = await resolve(Uint8List.fromList([...insta360PhotoHead(serial: x3Serial), 0xff, 0xd9]));
      final unseen = await resolve(Uint8List.fromList([...insta360PhotoHead(serial: 'UNSEEN'), 0xff, 0xd9]));

      expect((byTrailer.source, byTrailer.canvasSquare), (DualFisheyeSource.cachedSerial, 5952));
      expect((byExif.source, byExif.canvasSquare), (DualFisheyeSource.cachedSerial, 5952));
      expect((unseen.source, unseen.canvasSquare), (DualFisheyeSource.cachedSerial, 6000));
    });

    test('takes a video without trailer as upright, without reading its head', () async {
      final reads = <(int, int)>[];
      final file = Uint8List(100 * 1024);

      final calibration = (await resolveDualFisheyeCalibration(
        read: _reader(file, reads),
        fileSize: file.length,
        isPhoto: false,
        store: store,
      )).calibration;

      expect(calibration.source, DualFisheyeSource.nominal);
      expect(calibration.downBody, [1, 0, 0]);
      expect(reads, [(file.length - 64 * 1024, 64 * 1024)]);
    });

    test('tells a read that failed, with the nominal values', () async {
      final resolved = await resolveDualFisheyeCalibration(
        read: (_, _) async => throw const SocketException('share gone'),
        fileSize: 1000,
        isPhoto: true,
        store: store,
      );

      expect(resolved.readFailed, isTrue);
      expect(resolved.calibration.source, DualFisheyeSource.nominal);
    });
  });

  group('openHttpRangeFile', () {
    test('reads the tail with a suffix range, learns the size, and reads the rest with ranges', () async {
      final file = Uint8List.fromList([for (var i = 0; i < 1000; i++) i % 256]);
      final log = <String>[];
      final client = _server(file, path: '/file', log: log);

      final opened = await openHttpRangeFile(client, Uri.parse('http://server/file'), tailLength: 100);

      expect(opened!.size, 1000);
      expect(await opened.read(950, 10), [for (var i = 950; i < 960; i++) i % 256]);
      expect(log, ['bytes=-100'], reason: 'the bytes of the tail are not read twice');
      expect(await opened.read(10, 5), [10, 11, 12, 13, 14]);
      expect(log, ['bytes=-100', 'bytes=10-14']);
    });

    test('keeps the head of the file when the server ignores ranges, and stops the transfer there', () async {
      final file = Uint8List.fromList([for (var i = 0; i < 1024 * 1024; i++) i % 251]);
      final client = _NoRangeServer(file);

      final opened = await openHttpRangeFile(client, Uri.parse('http://server/file'));

      expect(opened, isNotNull);
      expect(opened!.size, isNull, reason: 'the end of the file cannot be read');
      expect(await opened.read(0, 4096), Uint8List.sublistView(file, 0, 4096));
      expect(await opened.read(100, 10), Uint8List.sublistView(file, 100, 110));
      expect(client.ranges, ['bytes=-65536'], reason: 'the head came with the answer to the first request');
      expect(client.sent, lessThan(16 * 1024), reason: 'not the whole file');
    });

    test('gives nothing when the server answers with an error', () async {
      final client = _server(Uint8List(1000), path: '/other');

      expect(await openHttpRangeFile(client, Uri.parse('http://server/file')), isNull);
    });
  });

  group('DualFisheyeCalibrationService', () {
    late MockStorageRepository storage;

    setUp(() => storage = MockStorageRepository());

    DualFisheyeCalibrationService service(http.Client client, {Duration timeout = const Duration(seconds: 5)}) =>
        DualFisheyeCalibrationService(
          store: store,
          storage: storage,
          client: () => client,
          serverEndpoint: () => 'http://server/api',
          headers: () => const {'x-immich-user-token': 'token'},
          timeout: timeout,
        );

    test('reads the original of a server asset by ranges, once', () async {
      final log = <String>[];
      final file = _x3Photo();
      final calibrations = service(_server(file, log: log));
      final asset = RemoteAssetFactory.create(id: 'remote', name: 'IMG_001.insp', width: 11968, height: 5984);

      final calibration = await calibrations.forAsset(asset);
      final again = await calibrations.forAsset(asset);

      expect(calibration.source, DualFisheyeSource.file);
      expect(again, same(calibration));
      expect(log.first, 'bytes=-65536');
      expect(log, hasLength(lessThanOrEqualTo(4)), reason: 'a few range reads, not the whole file');
    });

    test('levels a server photo with its MakerNote when the server ignores ranges, without the whole file', () async {
      // A photo of more than 1 MB whose trailer the server does not let the app reach
      final file = insta360File(
        [insta360Record(1, x3Metadata(), format: 1)],
        body: [
          ...insta360PhotoHead(makerNote: _leaningMakerNote),
          ...Uint8List(1024 * 1024),
        ],
      );
      final client = _NoRangeServer(file);

      final calibration = await service(
        client,
      ).forAsset(RemoteAssetFactory.create(id: 'remote', name: 'IMG_001.insp', width: 11968, height: 5984));

      expect(calibration.source, DualFisheyeSource.nominal);
      expect(calibration.cameraModel, x3Model);
      expect(calibration.downBody, _closeToList(downBodyFromAccelerometer(_leaningAccelerometer)));
      expect(client.ranges, hasLength(1));
      expect(client.sent, lessThan(16 * 1024), reason: 'not the whole file');
    });

    test('takes the calibration of the model of a server photo when the server ignores ranges', () async {
      await store.remember(x3Serial, parseInsta360OffsetV3(x3OffsetV3)!.copyWith(cameraModel: x3Model));
      final file = insta360File(
        [insta360Record(1, x3Metadata(), format: 1)],
        body: [
          ...insta360PhotoHead(makerNote: _leaningMakerNote),
          ...Uint8List(1024 * 1024),
        ],
      );

      final calibration = await service(
        _NoRangeServer(file),
      ).forAsset(RemoteAssetFactory.create(id: 'remote', name: 'IMG_001.insp'));

      expect(calibration.source, DualFisheyeSource.cachedSerial);
      expect(calibration.canvasSquare, 5952);
      expect(calibration.downBody, _closeToList(downBodyFromAccelerometer(_leaningAccelerometer)));
    });

    test('reads the copy on the device first', () async {
      final file = File('${directory.path}/IMG_001.insp')..writeAsBytesSync(_x3Photo());
      when(() => storage.getFileForAsset('local')).thenAnswer((_) async => file);
      final calibrations = service(MockClient((_) async => throw StateError('no server read expected')));

      final calibration = await calibrations.forAsset(
        RemoteAssetFactory.create(id: 'remote', name: 'IMG_001.insp', localId: 'local'),
      );

      expect(calibration.source, DualFisheyeSource.file);
    });

    test('keeps the result of a reader, but reads again after a failure', () async {
      final file = _x3Photo();
      final reads = <(int, int)>[];
      var fail = true;
      final calibrations = service(MockClient((_) async => http.Response('', 500)));
      Future<DualFisheyeCalibration> resolve() => calibrations.forReader(
        'share:a',
        read: (offset, length) async {
          if (fail) {
            throw const SocketException('share gone');
          }
          return _reader(file, reads)(offset, length);
        },
        fileSize: file.length,
        isPhoto: true,
      );

      expect((await resolve()).source, DualFisheyeSource.nominal);
      fail = false;
      expect((await resolve()).source, DualFisheyeSource.file);
      final count = reads.length;
      expect((await resolve()).source, DualFisheyeSource.file);
      expect(reads, hasLength(count));
    });
  });

  group('gravity and layout hints', () {
    Future<DualFisheyeCalibration> resolve(
      Uint8List file, {
      bool isPhoto = false,
      DualFisheyeCalibrationStore? within,
    }) async => (await resolveDualFisheyeCalibration(
      read: _reader(file),
      fileSize: file.length,
      isPhoto: isPhoto,
      store: within ?? store,
      frameSquare: 3840,
    )).calibration;

    test('tell where gravity came from: the IMU of the trailer, the MakerNote of a photo, or nowhere', () async {
      expect((await resolve(_x3Photo(), isPhoto: true)).gravity, GravitySource.imu);
      expect((await resolve(_x3Photo(imu: false), isPhoto: true)).gravity, GravitySource.makerNote);
      final upright = await resolve(Uint8List.fromList(List.filled(1000, 0)));
      expect(upright.gravity, GravitySource.none);
      expect(upright.source, DualFisheyeSource.nominal);
      expect(upright.layoutHints, isNull);
    });

    test('give the layout fields of the trailer to a calibration of the file, of the cache or nominal', () async {
      final x5 = insta360File([insta360Record(1, x5Metadata(), format: 1)], body: List.filled(100, 0));
      final withoutCalibration = insta360File([
        insta360Record(1, x5Metadata(offsetV6: '1_2_3'), format: 1),
      ], body: List.filled(100, 0));

      final fromFile = await resolve(x5);
      // The same camera: the calibration kept for it
      await pumpEventQueue();
      final cached = await resolve(withoutCalibration);
      final nominal = await resolve(withoutCalibration, within: DualFisheyeCalibrationStore(() async => null));

      expect(fromFile.source, DualFisheyeSource.file);
      expect(fromFile.lenses.first.k4, x5K4);
      expect(cached.source, DualFisheyeSource.cachedSerial);
      expect(nominal.source, DualFisheyeSource.nominal);
      for (final calibration in [fromFile, cached, nominal]) {
        final hints = calibration.layoutHints!;
        expect(
          (hints.fileLayout, hints.trackOrder, hints.streamLayout, hints.imageCategory, hints.groupIdentity),
          (2, 1, 3, 2, x5GroupIdentity),
        );
      }
      // Never kept with the calibration of the camera
      await resolve(x5);
      await pumpEventQueue();
      expect((await store.forModel(x5Model))?.layoutHints, isNull);
    });

    test('give the window of the sensor a video frame shows (field 27)', () async {
      final video = insta360File([
        insta360Record(1, [
          ...pbBytesField(27, [
            ...pbVarintField(1, 5952),
            ...pbVarintField(2, 5952),
            ...pbVarintField(3, 5760),
            ...pbVarintField(4, 5760),
          ]),
          ...x3Metadata(),
        ], format: 1),
      ], body: List.filled(100, 0));

      final hints = (await resolve(video)).layoutHints!;

      expect(hints.videoWindow, (areaWidth: 5952, areaHeight: 5952, width: 5760, height: 5760, offsetX: 0, offsetY: 0));
    });
  });

  group('calibrations of raw video inputs', () {
    RawVideoInput input(String key, Uint8List? file, {List<(int, int)>? reads, String name = 'VID_00_001.insv'}) =>
        RawVideoInput(
          name: name,
          key: key,
          url: 'file:///$name',
          open: () async => file == null ? null : (size: file.length, read: _reader(file, reads), close: () async {}),
        );

    DualFisheyeCalibrationService service() => DualFisheyeCalibrationService(
      store: store,
      storage: MockStorageRepository(),
      client: () => throw UnimplementedError('no server'),
      serverEndpoint: () => null,
      headers: () => const {},
    );

    test('forInput reads the trailer of the file the input opens, once per key', () async {
      final reads = <(int, int)>[];
      final calibrations = service();
      final file = insta360File([insta360Record(1, x3Metadata(), format: 1)], body: List.filled(100, 0));

      final calibration = await calibrations.forInput(input('share:a', file, reads: reads), frameSquare: 2880);
      final count = reads.length;
      final again = await calibrations.forInput(input('share:a', file, reads: reads), frameSquare: 2880);

      expect(calibration.source, DualFisheyeSource.file);
      expect(calibration.cameraModel, x3Model);
      expect(again, same(calibration));
      expect(reads, hasLength(count));
      expect((await calibrations.forInput(input('share:b', null), frameSquare: 2880)).canvasSquare, 2880);
    });

    test('forDji reads the camd box of an Osmo 360 file, else gives its nominal values', () async {
      final calibrations = service();
      final osv = djiOsvFile();
      final reads = <(int, int)>[];

      final read = await calibrations.forDji(input('share:osv', osv, reads: reads, name: 'CAM_0003_D.OSV'));
      final count = reads.length;
      expect(await calibrations.forDji(input('share:osv', osv, reads: reads, name: 'CAM_0003_D.OSV')), same(read));
      final nominal = await calibrations.forDji(
        input('share:none', djiOsvFile(camd: const []), name: 'CAM_0004_D.OSV'),
      );

      expect(read.model, DualFisheyeModel.kannalaBrandt);
      expect(read.source, DualFisheyeSource.file);
      expect(read.cameraModel, djiModel);
      expect(read.canvasSquare, 3840);
      expect(reads, hasLength(count), reason: 'kept in memory');
      expect(nominal.source, DualFisheyeSource.nominal);
      expect(nominal.cameraModel, 'Osmo 360');
      // Never kept for the camera: every file carries its own
      await pumpEventQueue();
      expect(await store.forModel(djiModel), isNull);
    });

    test('forDji tries again after a failed read', () async {
      final calibrations = service();
      var fail = true;
      final osv = djiOsvFile();
      final failing = RawVideoInput(
        name: 'CAM_0003_D.OSV',
        key: 'share:osv',
        url: 'file:///CAM_0003_D.OSV',
        open: () async => (
          size: osv.length,
          read: (int offset, int length) async {
            if (fail) {
              throw const SocketException('share gone');
            }
            return _reader(osv)(offset, length);
          },
          close: () async {},
        ),
      );

      expect((await calibrations.forDji(failing)).source, DualFisheyeSource.nominal);
      fail = false;
      expect((await calibrations.forDji(failing)).source, DualFisheyeSource.file);
    });
  });
}
