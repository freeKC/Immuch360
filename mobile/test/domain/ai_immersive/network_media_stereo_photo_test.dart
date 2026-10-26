import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';

import '../../test_utils/heif_builder.dart';
import 'stereo_photo_fixtures.dart';

NetworkEntry _entry(String path, int? size) =>
    NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: size, modified: DateTime.utc(2026, 10, 27));

/// What a share says of [file] at [path], and the reads it made
Future<(NetworkMediaInfo?, List<(int, int)>)> _detect(String path, Uint8List file, {bool withSize = true}) async {
  final reader = RecordingReader(file);
  final info = await NetworkMediaService().detect(_entry(path, withSize ? file.length : null), reader.call);
  return (info, reader.reads);
}

// A file longer than the GPano windows, so that its tail is read too
Uint8List _long(Uint8List head) => Uint8List.fromList([...head, ...List.filled(300 * 1024, 0)]);

void main() {
  test('our side by side photo on a share: two eyes, not 360°, read no more than an ordinary photo', () async {
    final oursFile = _long(jpegFile(width: 8000, height: 3000, xmp: ourXmp()));
    final flatFile = _long(jpegFile(width: 4000, height: 3000));
    final (ours, oursReads) = await _detect('/Photos/salon_3D_LRF_Full_SBS.jpg', oursFile);
    final (flat, flatReads) = await _detect('/Photos/IMG_0001.jpg', flatFile);

    expect(ours?.stereoPhoto?.isOurs, isTrue);
    expect(ours?.stereoPhoto?.eyes, StereoEyes.full);
    expect(ours?.stereoPhoto?.isEstimatedRelief, isTrue);
    expect(ours?.is360, isFalse);
    expect(flat?.stereoPhoto, isNull);
    expect(flat?.is360, isFalse);
    // The head the GPano tags were looked for in, then the tail, and nothing more
    expect(oursReads, [(0, 131072), (oursFile.length - 131072, 131072)]);
    expect(flatReads, [(0, 131072), (flatFile.length - 131072, 131072)]);
  });

  test('an ordinary photo of unknown size: one read, as before', () async {
    final (info, reads) = await _detect('/Photos/IMG_0002.jpg', jpegFile(width: 4000, height: 3000), withSize: false);

    expect(info?.stereoPhoto, isNull);
    expect(reads, [(0, 131072)]);
  });

  test('the side by side photo of a square drone photo (2:1) does not become a sphere', () async {
    final file = jpegFile(
      width: 8000,
      height: 4000,
      xmp: ourXmp(eyeWidth: 4000, eyeHeight: 4000, sourceName: 'DJI_0001.JPG'),
    );
    final (info, _) = await _detect('/Drone/DJI_0001_3D_LRF_Full_SBS.jpg', file);

    expect(info?.is360, isFalse);
    expect(info?.cameraEquirect, isFalse);
    expect(info?.isUntaggedSphere, isFalse);
    expect(info?.stereoPhoto?.eyes, StereoEyes.full);
  });

  test('trip_180_3D_LRF_Full_SBS.jpg with our XMP is two flat eyes, not a VR180', () async {
    final file = jpegFile(width: 6000, height: 3000, xmp: ourXmp(eyeWidth: 3000, sourceName: 'trip_180.jpg'));
    final (info, _) = await _detect('/Trips/trip_180_3D_LRF_Full_SBS.jpg', file);

    expect(info?.stereoPhoto?.isOurs, isTrue);
    expect(info?.stereoPhoto?.eyeOrder, EyeOrder.leftRight);
    expect(info?.is360, isFalse);
    // The VR180 rule of the name does not change: it only applies to a file viewed as 360°
    expect(
      guessSphereCoverage(fileName: 'trip_180_3D_LRF_Full_SBS.jpg', width: null, height: null),
      SphereCoverage.half,
    );
  });

  test('a file of iw3 on a share: told by its name, its frame read in the PNG header', () async {
    final (full, _) = await _detect('/iw3/photo_LRF_Full_SBS.png', pngFile(width: 8064, height: 3024));
    expect(full?.stereoPhoto, const FlatStereoPhoto(eyes: StereoEyes.full));
    expect(full?.stereoPhoto?.isOurs, isFalse);

    final (half, _) = await _detect('/iw3/photo_LR.png', pngFile(width: 4032, height: 3024));
    expect(half?.stereoPhoto, const FlatStereoPhoto(eyes: StereoEyes.half));

    final (crossed, _) = await _detect('/iw3/photo_RLF_cross.png', pngFile(width: 8064, height: 3024));
    expect(crossed?.stereoPhoto?.eyeOrder, EyeOrder.rightLeft);
  });

  test('a flat 3:1 panorama stays flat', () async {
    final (info, _) = await _detect('/Photos/PANO_0001.jpg', jpegFile(width: 6000, height: 2000));

    expect(info?.stereoPhoto, isNull);
    expect(info?.is360, isFalse);
  });

  test('a 360° photo with a side by side name stays a 360° photo', () async {
    final (info, _) = await _detect(
      '/Photos/street_sbs.jpg',
      jpegFile(width: 8000, height: 4000, segments: [gpanoSegment()]),
    );

    expect(info?.is360, isTrue);
    expect(info?.stereoPhoto, isNull);
  });

  test('a FormatVersion 2 file is shown flat, made by a newer version', () async {
    final (info, _) = await _detect(
      '/Photos/salon_3D_LRF_Full_SBS.jpg',
      jpegFile(width: 8000, height: 3000, xmp: ourXmp(formatVersion: 2)),
    );

    expect(info?.stereoPhoto?.isNewerFormat, isTrue);
    expect(info?.stereoPhoto?.request, isNull);
  });
}
