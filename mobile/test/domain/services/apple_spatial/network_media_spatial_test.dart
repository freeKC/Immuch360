import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';

import '../../../test_utils/heif_builder.dart';
import '../spherical_probe_fixtures.dart';

NetworkEntry _entry(String path, int size) =>
    NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: size, modified: DateTime.utc(2026, 10, 1));

void main() {
  // The head of an Apple ImageIO spatial photo (MIT licensed, see the note next to it), then zeros for its image data
  final sampleHead = File('test/fixtures/apple_spatial/udibr_fisheye_0S9A9186_head.bin').readAsBytesSync();
  final samplePhoto = Uint8List.fromList([...sampleHead, ...List.filled(300 * 1024, 0)]);

  test('a .heic share file holding a stereo pair is an Apple spatial photo', () async {
    final reader = RecordingReader(samplePhoto);
    final info = await NetworkMediaService().detect(_entry('/IMG_0001.HEIC', samplePhoto.length), reader.call);

    expect(info?.isAppleSpatial, isTrue);
    expect(info?.is360, isFalse);
    expect(info?.stereoPair?.leftItemId, 37);
    expect(info?.stereoPair?.rightItemId, 74);
    expect(info?.stereoPair?.pitmIdOffset, 129);
    expect(info?.multiview, isNull);
    // The head the GPano tags were looked for in holds the meta box: no read of its own
    expect(reader.reads.where((read) => read.$1 == 0), hasLength(1));
  });

  test('a photo under another name is not read for a pair', () async {
    final info = await NetworkMediaService().detect(
      _entry('/IMG_0001.jpg', samplePhoto.length),
      RecordingReader(samplePhoto).call,
    );

    expect(info?.isAppleSpatial, isFalse);
    expect(info?.stereoPair, isNull);
  });

  test('a flat HEIF photo is no spatial photo', () async {
    final flat = HeifBuilder(
      items: const [
        HeifItem(1, 'hvc1', properties: [1]),
      ],
      properties: [heifIspe(4032, 3024)],
    ).build();

    final info = await NetworkMediaService().detect(_entry('/flat.heif', flat.length), RecordingReader(flat).call);
    expect(info, isNotNull);
    expect(info!.isAppleSpatial, isFalse);
  });

  test('a video with two MV-HEVC layers is an Apple spatial video', () async {
    final video = Uint8List.fromList(
      mp4File(
        mp4Moov([
          mp4VideoTrack([
            mp4Box('lhvC', [1, ...mp4Zeros(20)]),
            mp4Box(
              'vexu',
              mp4Box('eyes', [
                ...mp4FullBox('stri', [3]),
                ...mp4FullBox('hero', [1]),
              ]),
            ),
          ], config: mp4HvcC()),
        ]),
      ),
    );

    final info = await NetworkMediaService().detect(_entry('/IMG_0002.MOV', video.length), RecordingReader(video).call);
    expect(info?.isAppleSpatial, isTrue);
    expect(info?.multiview?.heroEye, 1);
    expect(info?.stereoPair, isNull);
  });
}
