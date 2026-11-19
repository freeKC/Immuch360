// The integration of the 3D videos with the real FFmpeg program and the real model (video3d-plan.md, section 5), run
// by hand on the build host or by the desktop workflow: IMMUCH360_VIDEO3D_ARGS holds the JSON list of the arguments of
// test/desktop/ai/tools/video3d_probe.dart. Skipped without it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/video3d_probe.dart';

void main() {
  final given = Platform.environment['IMMUCH360_VIDEO3D_ARGS'];
  test(
    'the 3D videos of the clips given, through the real components',
    skip: given == null ? 'IMMUCH360_VIDEO3D_ARGS not set' : null,
    timeout: const Timeout(Duration(hours: 6)),
    () async {
      final args = (jsonDecode(given!) as List).cast<String>();
      expect(await runVideo3dProbe(args), 0);
    },
  );
}
