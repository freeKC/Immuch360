// Draws the poster of a splat with the app's renderer (lot L5 of the splat photos), for the measures of the plan's
// section 7 on ai1 and on the PC's processor: prints the times and the counts as JSON.
//
//   dart run tool/splat_photo/draw_splat_poster.dart SCENE.spz OUT.jpg [--up yUp|zUp|yDown] [--no-mark] [--keep N]

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_cloud.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_draw.dart';

Future<void> main(List<String> args) async {
  final plain = <String>[];
  String? up;
  var mark = true;
  var keep = splatPosterKeep;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--up':
        up = args[++i];
      case '--no-mark':
        mark = false;
      case '--keep':
        keep = int.parse(args[++i]);
      default:
        plain.add(args[i]);
    }
  }
  if (plain.length != 2) {
    stderr.writeln('draw_splat_poster.dart SCENE OUT.jpg [--up yUp|zUp|yDown] [--no-mark] [--keep N]');
    exit(2);
  }
  final file = File(plain[0]);
  final length = file.lengthSync();
  final raf = file.openSync();
  final head = raf.readSync(length < splatHeadBytes ? length : splatHeadBytes);
  raf.closeSync();
  final probe = probeSplatHead(Uint8List.fromList(head), length);
  if (probe is! SplatHead) {
    stderr.writeln('not a splat this reads: $probe');
    exit(1);
  }
  final clock = Stopwatch()..start();
  final drawing = await drawSplatPoster(file: file, head: probe, up: up, mark: mark, keep: keep);
  final total = clock.elapsedMilliseconds;
  File(plain[1]).writeAsBytesSync(drawing.jpeg);
  stdout.writeln(
    jsonEncode({
      'scene': file.uri.pathSegments.last,
      'gaussians': probe.gaussians,
      'kept': drawing.kept,
      'drawn': drawing.drawn,
      'upright': drawing.upright,
      'readMs': drawing.readMs,
      'drawMs': drawing.drawMs,
      'encodeMs': drawing.encodeMs,
      'totalMs': total,
      'jpegBytes': drawing.jpeg.length,
      'size': '${drawing.width}x${drawing.height}',
    }),
  );
}
