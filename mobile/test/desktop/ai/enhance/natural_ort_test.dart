// Natural through the real ONNX Runtime (release 53), on the tiny graphs of make_tiny_vosr.py, which have the inputs
// and outputs of the four graphs of VOSR 2.0 and give back each tile as the average of its blocks of 8 x 8 pixels: the
// whole backend (its worker isolate, its sessions, its tiles, the blend and the colour fix) on the processor, and on
// the macOS runner through Core ML, against the processor. IMMUCH360_ORT_LIB names the library (the CI's steps of
// ONNX Runtime), IMMUCH360_ORT_COREML asks for the Core ML check (Apple silicon only).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

const _fixtures = 'test/fixtures/ai_immersive';

VosrFiles _files(String library) {
  String graph(String part) => p.absolute(_fixtures, 'tiny_vosr_$part.onnx');
  return VosrFiles(
    library: library,
    imageEncoder: graph('image_encoder'),
    vaeEncoder: graph('vae_encoder'),
    transformer: graph('transformer'),
    vaeDecoder: graph('vae_decoder'),
  );
}

/// A picture of blocks of 8 x 8 pixels, each of its own colour: what the tiny graphs give back as it is
SbsDecoded _blocks(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = 4 * (y * width + x);
      final block = (x ~/ 8) * 131 + (y ~/ 8) * 71;
      rgba[i] = 30 + block % 190;
      rgba[i + 1] = 30 + (block * 7) % 190;
      rgba[i + 2] = 30 + (block * 13) % 190;
      rgba[i + 3] = 255;
    }
  }
  return SbsDecoded(width: width, height: height, rgba: rgba);
}

int _worst(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final difference = (a[i] - b[i]).abs();
    if (difference > worst) {
      worst = difference;
    }
  }
  return worst;
}

void main() {
  final library = Platform.environment['IMMUCH360_ORT_LIB'];
  final coreMl = Platform.environment['IMMUCH360_ORT_COREML'] != null;
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('natural-ort-'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<(Uint8List, List<(int, int)>, List<String>)> run(OrtProvider provider, SbsDecoded picture) async {
    final backend = OrtNaturalBackend(files: _files(library!), modelSha256: 'tiny', threads: 2, provider: provider);
    final steps = <(int, int)>[];
    final out = await backend.enhance(
      picture,
      workFolder: temp.path,
      seed: 42,
      cancel: NativeCancelFlag(),
      onStep: (done, all) => steps.add((done, all)),
    );
    return (out, steps, backend.notes);
  }

  test(
    'on the processor: four tiles of a photo of 600 x 520, given back as it was',
    skip: library == null ? 'IMMUCH360_ORT_LIB not set' : null,
    () async {
      final picture = _blocks(600, 520);
      final (out, steps, notes) = await run(OrtProvider.cpu, picture);
      expect(steps.last, (4, 4));
      expect(_worst(out, picture.rgba), lessThanOrEqualTo(2));
      expect(notes, isEmpty);
    },
  );

  test(
    'through Core ML on Apple silicon: every graph opened with Core ML, the same picture as the processor',
    skip: library == null || !coreMl ? 'IMMUCH360_ORT_COREML not set' : null,
    () async {
      final picture = _blocks(600, 520);
      final (cpu, _, _) = await run(OrtProvider.cpu, picture);
      final watch = Stopwatch()..start();
      final (out, steps, notes) = await run(OrtProvider.coreMl, picture);
      // ignore: avoid_print
      print('Natural through Core ML on the tiny graphs in ${watch.elapsedMilliseconds} ms:\n${notes.join('\n')}');
      expect(steps.last, (4, 4));
      expect(notes.where((note) => note.contains('opened with Core ML')), hasLength(4));
      expect(notes.where((note) => note.contains('processor')), isEmpty);
      expect(_worst(out, cpu), lessThanOrEqualTo(3));
      expect(_worst(out, picture.rgba), lessThanOrEqualTo(3));
    },
  );
}
