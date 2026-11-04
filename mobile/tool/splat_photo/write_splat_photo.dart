// Writes one splat photo with the app's writer, for the measures of the splat photo lots (plan of 3 November 2026,
// section 10.2): dart run tool/splat_photo/write_splat_photo.dart SPZ POSTER OUT [NAME]. Prints what it wrote as JSON.
// Never shipped: a tool of the lots, run on the build host.

import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_exif.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('write_splat_photo.dart SPZ POSTER OUT [NAME]');
    exit(2);
  }
  final spz = File(args[0]);
  final out = File(args[2]);
  final name = args.length > 3 ? args[3] : spz.uri.pathSegments.last;
  final watch = Stopwatch()..start();
  final written = await writeSplatPhotoFileInIsolate(
    spz: spz,
    posterJpeg: File(args[1]).readAsBytesSync(),
    meta: SplatPhotoMeta(
      name: name,
      date: SplatPhotoDate.of(spz.lastModifiedSync()),
      software: 'Immuch360 lot L1',
      creatorTool: 'Immuch360 lot L1 (${Platform.operatingSystem})',
      description: 'Splat scene. Open it with Immuch360 to explore it.',
      poster: SplatPosterKind.render,
    ),
    out: out,
  );
  stdout.writeln(
    jsonEncode({
      'file': out.path,
      'name': splatPhotoNameFor(name),
      'bytes': written.length,
      'sha1': written.sha1,
      'head': written.headLength,
      'splatLength': written.xmp.splatLength,
      'splatSha256': written.xmp.splatSha256,
      'gaussians': written.xmp.splatGaussians,
      'version': written.xmp.splatVersion,
      'ms': watch.elapsedMilliseconds,
    }),
  );
}
