// Reads real raw 360° files of the development machine with the probe and the parsers, and prints what they give. Each
// file is only read, in place, and its test skipped unless its variable names it:
//   IMMUCH_OSV_SAMPLE=/path/to/CAM_20250715191201_0003_D.OSV (DJI Osmo 360)
//   IMMUCH_GOPRO_SAMPLE=/path/to/GS010013.360 (GoPro MAX)
//   IMMUCH_TWOTRACK_SAMPLE=/path/to/twotrack-x3.insv (two video tracks and an X3 trailer)
//   IMMUCH_INSP_SAMPLE=/path/to/IMG_20240908_133036_00_001.insp (Insta360 X3 photo)

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/exif_head.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// A reader of the file at [path] that counts its reads, closed at the end of the test
Future<({ByteRangeReader read, int size, List<(int, int)> reads})> _open(String path) async {
  final file = await File(path).open();
  addTearDown(file.close);
  final reads = <(int, int)>[];
  Future<Uint8List> read(int offset, int length) async {
    reads.add((offset, length));
    await file.setPosition(offset);
    return file.read(length);
  }

  return (read: read, size: await file.length(), reads: reads);
}

String? _sample(String variable) => Platform.environment[variable];

dynamic _skip(String variable) => _sample(variable) == null ? 'Set $variable to the path of the file' : false;

void main() {
  test('probes a DJI Osmo 360 .OSV', () async {
    final file = await _open(_sample('IMMUCH_OSV_SAMPLE')!);

    final boxes = await listTopLevelBoxes(file.read);
    _print('top level boxes: $boxes');
    expect(boxes.map((box) => box.type), ['ftyp', 'free', 'free', 'mdat', 'moov', 'camd']);

    file.reads.clear();
    final probe = await probeSphericalMetadata(file.read);
    _print('probe: $probe (${file.reads.length} reads)');
    expect(probe.tracks.map((track) => (track.handlerType, track.codec)), [
      ('vide', 'hvc1'),
      ('vide', 'hvc1'),
      ('soun', 'mp4a'),
      ('meta', 'djmd'),
      ('meta', 'djmd'),
      ('meta', 'dbgi'),
      ('meta', 'dbgi'),
    ]);
    final videos = probe.videoTracks;
    expect(videos.map((track) => track.trackId), [1, 2]);
    for (final video in videos) {
      expect((video.codedWidth, video.codedHeight, video.codecs, video.bitDepth), (3840, 3840, 'hvc1.2.4.H156', 10));
      expect(video.handlerName, 'VideoHandler');
      expect(video.frameRate, closeTo(25, 0.01));
    }
    expect(probe.tracks[3].handlerName, 'CAM meta');
    expect(probe.tracks[5].handlerName, 'CAM dbgi');
    expect(rawMediaKindOfName('CAM_20250715191201_0003_D.OSV', isVideo: true), RawMediaKind.djiVideo);

    file.reads.clear();
    final dji = await readDjiOsvCalibration(file.read);
    final bytesRead = file.reads.fold(0, (sum, read) => sum + read.$2);
    _print('camd: $dji (${file.reads.length} reads, $bytesRead bytes)');
    _print('calibration: ${dji?.calibration.toJson()}');
    expect(
      (dji!.model, dji.serial, dji.firmware, dji.schema),
      ('Osmo 360', '95SXN6500213WL', '10.00.05.06', 'dvtm_oq101.proto'),
    );
    final calibration = dji.calibration;
    expect(calibration.model, DualFisheyeModel.kannalaBrandt);
    expect(calibration.canvasSquare, 3840);
    final [lens0, lens1] = calibration.lenses;
    expect(lens0.cx, closeTo(1920.85339355, 1e-4));
    expect(lens1.cx, closeTo(1910.76611328 + 3840, 1e-4));
    expect(lens0.k5, closeTo(0.00104408, 1e-8));
    expect(lens1.k5, closeTo(0.00095551, 1e-8));
    // Example D of docs/18-design-projections-and-parsers.md, section 3.5
    const viewToLens0 = [-0.999691, -0.023657, 0.007672, -0.023572, 0.999662, 0.010951, -0.007928, 0.010766, -0.999911];
    const viewToLens1 = [0.999933, -0.007031, -0.009205, 0.007135, 0.999911, 0.011292, 0.009124, -0.011357, 0.999894];
    for (var i = 0; i < 9; i++) {
      expect(lens0.viewToLens![i], closeTo(viewToLens0[i], 1e-5));
      expect(lens1.viewToLens![i], closeTo(viewToLens1[i], 1e-5));
    }
    expect(bytesRead, lessThan(512 * 1024));
  }, skip: _skip('IMMUCH_OSV_SAMPLE'));

  test('probes a GoPro MAX .360', () async {
    final file = await _open(_sample('IMMUCH_GOPRO_SAMPLE')!);

    final probe = await probeSphericalMetadata(file.read);
    _print('probe: $probe (${file.reads.length} reads)');
    expect(probe.tracks.map((track) => (track.trackId, track.handlerType, track.codec, track.handlerName)), [
      (1, 'vide', 'hvc1', 'GoPro H.265'),
      (2, 'soun', 'mp4a', 'GoPro AAC'),
      (3, 'tmcd', 'tmcd', 'GoPro TCD'),
      (4, 'meta', 'gpmd', 'GoPro MET'),
      (5, 'meta', 'fdsc', 'GoPro SOS'),
      (6, 'vide', 'hvc1', 'GoPro H.265'),
      (7, 'soun', 'in32', 'GoPro AMB'),
    ]);
    expect(probe.videoTracks.map((track) => track.frameRate), everyElement(closeTo(30000 / 1001, 0.01)));
    final geometry = goProEacGeometryOf(probe);
    _print('geometry: $geometry, ${geometry == null ? '' : goProCameraName(geometry)}');
    expect(geometry, const GoProEacGeometry(trackWidth: 4096, trackHeight: 1344));
    expect(goProCameraName(geometry!), 'GoPro MAX');
  }, skip: _skip('IMMUCH_GOPRO_SAMPLE'));

  test('probes a two-track .insv and reads its X3 trailer', () async {
    final file = await _open(_sample('IMMUCH_TWOTRACK_SAMPLE')!);

    final probe = await probeSphericalMetadata(file.read);
    _print('probe: $probe (${file.reads.length} reads)');
    expect(probe.videoTracks, hasLength(2));
    final [first, second] = probe.videoTracks;
    expect((first.codedWidth, first.codedHeight), (second.codedWidth, second.codedHeight));
    expect(first.trackId, isNot(second.trackId));

    final boxes = await listTopLevelBoxes(file.read);
    _print('top level boxes: $boxes');
    expect(boxes.map((box) => box.type), containsAllInOrder(['ftyp', 'moov']));

    final trailer = await readInsta360Trailer(file.read, file.size);
    _print('trailer: $trailer, track order ${insta360TrackOrder(trailer)}');
    expect(trailer, isNotNull);
    expect(trailer!.indexed, isFalse);
    expect(calibrationOf(trailer), isNotNull);
  }, skip: _skip('IMMUCH_TWOTRACK_SAMPLE'));

  test('reads the EXIF head and the trailer of an Insta360 X3 photo', () async {
    final path = _sample('IMMUCH_INSP_SAMPLE')!;
    final file = await _open(path);

    final head = parseExifHead(await file.read(0, exifHeadLength));
    _print('EXIF head: $head');
    expect(head!.make, 'Arashi Vision');
    expect(head.model, 'Insta360 X3');
    expect(head.makerNote, isNotNull);
    expect(parseInsta360PhotoHead(await file.read(0, exifHeadLength))!.imu, isNotNull);

    final trailer = await readInsta360Trailer(file.read, file.size);
    _print('trailer: $trailer');
    expect(trailer!.indexed, isFalse);
    expect(trailer.cameraModel, 'Insta360 X3');
    expect(calibrationOf(trailer), isNotNull);
    // A raw photo is never taken for an equirect one, whatever its size
    expect(
      isEquirectCameraPhoto(
        name: path.split('/').last,
        make: head.make,
        model: head.model,
        width: head.pixelWidth,
        height: head.pixelHeight,
      ),
      isFalse,
    );
  }, skip: _skip('IMMUCH_INSP_SAMPLE'));
}
