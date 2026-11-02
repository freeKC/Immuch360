// A small program that runs the last step of a splat scene (lot SP3, splat_files.dart) on a real export of Brush, with
// no Flutter: compiled by `dart compile exe`, it is the essay of the lot on the computer of the measure (150 000
// gaussians of degree 3 in under 3 s in an isolate), and a way for the next lots to turn an export into the files the
// headset reads. It prints one JSON line: what was written, the scale and its rule, the bytes of each file, what the
// probe of the headset says of each (splat_header.dart), and the milliseconds the isolate took.
//
//   splat_convert EXPORT.ply OUT.spz [--ply OUT.ply] [--subject place|object] [--model SPARSE_DIR] [--sh N]
//
// --model reads the centres of the cameras from the images.bin of a COLMAP model (the frame of the export), which a
// place needs to find its floor.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/splat/splat_files.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

import '../fakes/fake_colmap_model.dart';

Future<void> main(List<String> args) async {
  final positional = <String>[];
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--') && i + 1 < args.length) {
      options[args[i].substring(2)] = args[++i];
    } else {
      positional.add(args[i]);
    }
  }
  if (positional.length != 2) {
    stderr.writeln('splat_convert EXPORT.ply OUT.spz [--ply OUT.ply] [--subject place|object] [--model DIR] [--sh N]');
    exit(64);
  }
  final model = options['model'];
  final cameras = model == null ? null : cameraCentres(model);
  final watch = Stopwatch()..start();
  final written = await writeSplatFiles(
    brushPly: positional[0],
    spzPath: positional[1],
    plyPath: options['ply'],
    subject: SplatSubject.values.byName(options['subject'] ?? 'place'),
    cameras: cameras,
    shDegree: int.parse(options['sh'] ?? '${SplatV1.shDegree}'),
  );
  final milliseconds = watch.elapsedMilliseconds;
  String probe(String? path) {
    if (path == null) {
      return '';
    }
    final bytes = File(path).readAsBytesSync();
    return '${probeSplatHead(Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, splatHeadBytes)), bytes.length)}';
  }

  stdout.writeln(
    jsonEncode({
      'milliseconds': milliseconds,
      'gaussians': written.gaussians,
      'dropped': written.dropped,
      'shDegree': written.shDegree,
      'scale': written.scale.factor,
      'rule': written.scale.rule.name,
      'sizeBefore': written.scale.sizeBefore,
      'cameraHeight': written.scale.cameraHeight,
      'cameras': cameras == null ? 0 : cameras.length ~/ 3,
      'spzBytes': written.spzBytes,
      'plyBytes': written.plyBytes,
      'spzProbe': probe(positional[1]),
      'plyProbe': probe(options['ply']),
    }),
  );
}

/// The centre of each camera of the COLMAP model in [folder]: -R^T t of its pose (qvec w x y z, tvec)
Float64List cameraCentres(String folder) {
  final model = FakeColmapModel.readFrom(Directory(folder));
  if (model == null) {
    stderr.writeln('no COLMAP model in $folder');
    exit(66);
  }
  final out = Float64List(3 * model.images.length);
  for (var k = 0; k < model.images.length; k++) {
    final [w, x, y, z] = model.images[k].qvec;
    final [tx, ty, tz] = model.images[k].tvec;
    // The rows of R, from the unit quaternion
    final r = [
      [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
      [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
      [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ];
    for (var i = 0; i < 3; i++) {
      out[3 * k + i] = -(r[0][i] * tx + r[1][i] * ty + r[2][i] * tz);
    }
  }
  return out;
}
