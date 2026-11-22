// The marks of a 360° 3D video (lot ai-360-3d-51) written into an MP4 and read back by the app's own parser
// (probeSphericalMetadata) and the rule of its 360° viewers (resolveSphereView): st3d top and bottom, sv3d of a whole
// equirectangular sphere, the XML of Spherical Video V1; the chunk offsets moved with the moov so that every sample
// is still where they say; a moov after the media data left in place; marks of an earlier writer replaced, not
// doubled; the SA3D box of a spatial sound track put back.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/video3d/spherical_mp4_writer.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:path/path.dart' as p;

import 'tiny_mp4.dart';

Future<SphericalProbe> _probe(Uint8List bytes) => probeSphericalMetadata(
  (offset, length) async =>
      Uint8List.sublistView(bytes, offset.clamp(0, bytes.length), (offset + length).clamp(0, bytes.length)),
);

/// The chunk offsets of each track of [bytes], in the order of the tracks
List<int> _offsets(Uint8List bytes) {
  final top = parseMp4Boxes(bytes);
  final moov = top.firstWhere((box) => box.type == 'moov');
  return [
    for (final trak in moov.children!.where((box) => box.type == 'trak'))
      ByteData.sublistView(trak.child('mdia')!.child('minf')!.child('stbl')!.child('stco')!.payload!).getUint32(8),
  ];
}

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('spherical_mp4'));
  tearDown(() => folder.deleteSync(recursive: true));

  Future<Uint8List> mark(Uint8List input, {List<Uint8List?> sa3d = const []}) async {
    final from = p.join(folder.path, 'in.mp4');
    final to = p.join(folder.path, 'out.mp4');
    File(from).writeAsBytesSync(input);
    await writeSphericalMp4(from, to, audioSa3d: sa3d);
    return File(to).readAsBytesSync();
  }

  test('an MP4 with no mark reads as a flat video; marked, the app reads a 360° video top and bottom of a whole '
      'sphere, and its viewers show it so', () async {
    final input = tinyMp4(width: 64, height: 64);
    final before = await _probe(input);
    expect((before.hasSphericalMetadata, before.stereo), (false, null));

    final output = await mark(input);
    final after = await _probe(output);
    expect(after.hasSphericalMetadata, isTrue);
    expect(after.stereo, StereoLayout.topBottom);
    expect(after.halfSphere, isFalse);
    final view = resolveSphereView(fileName: 'trip_360_3D.mp4', width: 64, height: 64, probe: after);
    expect(view.layout, StereoLayout.topBottom);
    expect(view.coverage, SphereCoverage.full);

    // The XML of Spherical Video V1 in the video track, as ExifTool reads its ProjectionType
    final text = String.fromCharCodes(output);
    expect(text, contains('<GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>'));
    expect(text, contains('<GSpherical:StereoMode>top-bottom</GSpherical:StereoMode>'));
    expect(text, contains('<GSpherical:Spherical>true</GSpherical:Spherical>'));
  });

  test(
    'the moov grows before the media data: every chunk offset moves with it, each sample still where it says',
    () async {
      final input = tinyMp4();
      final output = await mark(input);
      final grown = output.length - input.length;
      expect(grown, greaterThan(100));
      final before = _offsets(input);
      final after = _offsets(output);
      expect(after, [before[0] + grown, before[1] + grown]);
      expect(Uint8List.sublistView(output, after[0], after[0] + tinyVideoChunk.length), tinyVideoChunk);
      expect(Uint8List.sublistView(output, after[1], after[1] + tinyAudioChunk.length), tinyAudioChunk);
    },
  );

  test('a moov after the media data: the offsets stay, the media data is copied as it was', () async {
    final input = tinyMp4(moovLast: true);
    final output = await mark(input);
    expect(_offsets(output), _offsets(input));
    final at = _offsets(output).first;
    expect(Uint8List.sublistView(output, at, at + tinyVideoChunk.length), tinyVideoChunk);
    expect((await _probe(output)).stereo, StereoLayout.topBottom);
  });

  test('the marks of an earlier writer are replaced, never doubled', () async {
    final input = tinyMp4(videoExtra: [st3dBox(StereoLayout.leftRight).toBytes(), sv3dEquirectangularBox().toBytes()]);
    expect((await _probe(input)).stereo, StereoLayout.leftRight);
    final once = await mark(input);
    final twice = await mark(once);
    expect(twice.length, once.length);
    expect((await _probe(twice)).stereo, StereoLayout.topBottom);
    final moov = parseMp4Boxes(twice).firstWhere((box) => box.type == 'moov');
    final video = moov.children!.firstWhere((box) => box.type == 'trak' && trackHandler(box) == 'vide');
    final entry = sampleEntriesOf(video).single;
    expect(entry.children!.where((box) => box.type == 'st3d').length, 1);
    expect(entry.children!.where((box) => box.type == 'sv3d').length, 1);
    expect(video.children!.where((box) => box.type == 'uuid').length, 1);
  });

  test('the SA3D box of a spatial sound track of the source is put back in the track the mux copied', () async {
    // version 0, ambisonic type 0, order 1, ACN, SN3D, 4 channels 0 to 3
    final sa3d = Uint8List.fromList([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]);
    final source = tinyMp4(audioExtra: [tinyBox('SA3D', sa3d)]);
    final sourcePath = p.join(folder.path, 'source.mp4');
    File(sourcePath).writeAsBytesSync(source);
    final read = await readAudioSa3d(sourcePath);
    expect(read.single, sa3d);

    final output = await mark(tinyMp4(), sa3d: read);
    final moov = parseMp4Boxes(output).firstWhere((box) => box.type == 'moov');
    expect(audioSa3dOf(moov).single, sa3d);
    // Not twice when the output has one already
    final again = await mark(output, sa3d: read);
    final moovAgain = parseMp4Boxes(again).firstWhere((box) => box.type == 'moov');
    final audio = moovAgain.children!.firstWhere((box) => box.type == 'trak' && trackHandler(box) == 'soun');
    expect(sampleEntriesOf(audio).single.children!.where((box) => box.type == 'SA3D').length, 1);
    // A source with no spatial sound gives nothing to put back
    expect((await readAudioSa3d(p.join(folder.path, 'out.mp4'))).single, sa3d);
    final plainPath = p.join(folder.path, 'plain.mp4');
    File(plainPath).writeAsBytesSync(tinyMp4());
    expect(await readAudioSa3d(plainPath), [null]);
  });

  test('a file with no moov or no video track is refused, nothing written over the input', () async {
    final from = p.join(folder.path, 'not.mp4');
    File(from).writeAsBytesSync(tinyBox('free', List.filled(32, 0)));
    expect(writeSphericalMp4(from, p.join(folder.path, 'x.mp4')), throwsFormatException);
    expect(File(from).lengthSync(), 40);
  });
}
