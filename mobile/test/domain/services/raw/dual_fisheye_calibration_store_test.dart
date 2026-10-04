import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';

import '../../../fixtures/raw/insta360.stub.dart';

void main() {
  late Directory directory;
  late File file;

  DualFisheyeCalibrationStore open() => DualFisheyeCalibrationStore(() async => file);

  /// The calibration of the real X3 photo as its trailer gives it, gravity included
  DualFisheyeCalibration fromFile() => parseInsta360OffsetV3(x3OffsetV3)!.copyWith(
    serial: x3Serial,
    cameraModel: x3Model,
    downBody: downBodyFromAccelerometer(const [-1.003906, -0.124023, 0.082031]),
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('dual_fisheye_calibrations');
    file = File('${directory.path}/support/dual_fisheye_calibrations.json');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('knows no camera before one was seen, without a file', () async {
    expect(await open().forSerial(x3Serial), isNull);
    expect(file.existsSync(), isFalse);
  });

  test(
    'keeps the calibration of a camera across launches, marked as cached and without the gravity of its shot',
    () async {
      final calibration = fromFile();
      await open().remember(x3Serial, calibration);

      final cached = await open().forSerial(x3Serial);

      expect(cached, isNotNull);
      expect(cached!.source, DualFisheyeSource.cachedSerial);
      expect(cached.serial, x3Serial);
      expect(cached.cameraModel, x3Model);
      expect(cached.model, DualFisheyeModel.mei);
      expect(cached.canvasSquare, 5952);
      expect(cached.downBody, [1, 0, 0]);
      expect([for (final lens in cached.lenses) lens.toJson()], [for (final lens in calibration.lenses) lens.toJson()]);
    },
  );

  test('takes the gravity of the shot it is asked for', () async {
    await open().remember(x3Serial, fromFile());

    final cached = await open().forSerial(x3Serial, downBody: const [0.9, 0.1, 0.4]);

    expect(cached!.downBody, [0.9, 0.1, 0.4]);
  });

  test('keeps each camera apart, and the latest calibration of each', () async {
    final store = open();
    await store.remember(x3Serial, fromFile());
    await store.remember('OTHER', nominalX3(5952).copyWith(source: DualFisheyeSource.file));
    final recalibrated = fromFile().copyWith(canvasSquare: 6000);
    await store.remember(x3Serial, recalibrated);

    final again = open();
    expect((await again.forSerial(x3Serial))!.canvasSquare, 6000);
    expect((await again.forSerial('OTHER'))!.lenses[0].cx, 2976);
    expect(await again.forSerial('NONE'), isNull);
    final json = jsonDecode(file.readAsStringSync()) as Map;
    expect(json['version'], 1);
    expect((json['cameras'] as Map).keys, unorderedEquals([x3Serial, 'OTHER']));
  });

  test('keeps the last calibration of each camera model, for the files that name their model only', () async {
    final store = open();
    await store.remember(x3Serial, fromFile());
    // Another X3, seen last
    await store.remember('OTHER', fromFile().copyWith(canvasSquare: 6000));

    final again = open();
    final cached = await again.forModel(x3Model, downBody: const [0.9, 0.1, 0.4]);
    expect(cached, isNotNull);
    expect(cached!.source, DualFisheyeSource.cachedSerial);
    expect(cached.cameraModel, x3Model);
    expect(cached.canvasSquare, 6000, reason: 'the last camera of the model');
    expect(cached.downBody, [0.9, 0.1, 0.4]);
    expect((await again.forModel(' $x3Model '))!.downBody, [1, 0, 0]);
    expect((await again.forSerial(x3Serial))!.canvasSquare, 5952, reason: 'each camera keeps its own');
    expect(await again.forModel('Insta360 X4'), isNull);
    final json = jsonDecode(file.readAsStringSync()) as Map;
    expect((json['models'] as Map).keys, [x3Model]);
  });

  test('keeps a calibration that names no camera model for its camera only', () async {
    final store = open();
    await store.remember(x3Serial, parseInsta360OffsetV3(x3OffsetV3)!);

    expect(await open().forSerial(x3Serial), isNotNull);
    expect(await open().forModel(x3Model), isNull);
    expect(await open().forModel(''), isNull);
  });

  test('keeps only the calibrations read from a file', () async {
    final store = open();
    await store.remember(x3Serial, nominalX3(5952));
    await store.remember(x3Serial, fromFile().copyWith(source: DualFisheyeSource.cachedSerial));
    await store.remember('', fromFile());

    expect(await open().forSerial(x3Serial), isNull);
    expect(await open().forSerial(''), isNull);
    expect(await open().forModel(x3Model), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('does not write the file again for the same calibration', () async {
    final store = open();
    await store.remember(x3Serial, fromFile());
    final written = file.lastModifiedSync();
    file.setLastModifiedSync(written.subtract(const Duration(hours: 1)));

    // Another shot of the same camera: another gravity, the same lenses
    await store.remember(x3Serial, fromFile().copyWith(downBody: const [0, 1, 0]));

    expect(file.lastModifiedSync(), written.subtract(const Duration(hours: 1)));
  });

  test('starts empty from a damaged file, and loses only a damaged camera', () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{not json');
    expect(await open().forSerial(x3Serial), isNull);

    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'cameras': {
          'BROKEN': {'model': 'nothing'},
          x3Serial: fromFile().toJson(),
        },
        'models': {
          'Insta360 BROKEN': {'model': 'nothing'},
          x3Model: fromFile().toJson(),
        },
      }),
    );
    expect(await open().forSerial('BROKEN'), isNull);
    expect((await open().forSerial(x3Serial))!.lenses, hasLength(2));
    expect(await open().forModel('Insta360 BROKEN'), isNull);
    expect((await open().forModel(x3Model))!.lenses, hasLength(2));
  });

  test('reads a file written before the camera models were kept', () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'cameras': {x3Serial: fromFile().toJson()},
      }),
    );

    expect(await open().forSerial(x3Serial), isNotNull);
    expect(await open().forModel(x3Model), isNull);
  });

  test('neither reads nor writes without a file', () async {
    final store = DualFisheyeCalibrationStore(() async => null);

    await store.remember(x3Serial, fromFile());

    expect(await store.forSerial(x3Serial), isNotNull, reason: 'kept for the session');
    expect(await store.forModel(x3Model), isNotNull, reason: 'kept for the session');
    expect(await DualFisheyeCalibrationStore(() async => null).forSerial(x3Serial), isNull);
    expect(await DualFisheyeCalibrationStore(() async => null).forModel(x3Model), isNull);
  });
}
