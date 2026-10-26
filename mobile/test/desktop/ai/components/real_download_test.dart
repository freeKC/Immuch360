// The real download of a depth model, by hand only: the release first (404 until ai-components-1 is published), then
// the official source pinned to its commit, through its real redirects, with the system's certificates and the sum of
// the catalogue. Skipped unless IMMUCH360_AI_REAL_DOWNLOAD names a folder, where the file is left, so that it can serve
// as the local mirror of the tests (IMMUCH360_AI_COMPONENTS_MIRROR). About 100 MB.
//
//   IMMUCH360_AI_REAL_DOWNLOAD=/some/folder flutter test test/desktop/ai/components/real_download_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:path/path.dart' as p;

void main() {
  final folder = Platform.environment['IMMUCH360_AI_REAL_DOWNLOAD'];

  for (final component in [depthModelOnnxComponent, depthModelTfliteComponent]) {
    test(
      '${component.id}: from the release or the official source, its sum checked',
      () async {
        final target = File(p.join(folder!, component.assetName));
        final part = File(p.join(folder, 'tmp', '${component.assetName}.part'));
        var last = 0;
        final watch = Stopwatch()..start();

        final source = await AiComponentDownloader(mirror: () => null).download(
          component,
          target: target,
          part: part,
          onProgress: (received, total) {
            if (received - last >= 20 << 20 || received == total) {
              last = received;
              // ignore: avoid_print
              print('${component.id}: $received of $total bytes');
            }
          },
        );

        // ignore: avoid_print
        print('${component.id}: from $source in ${watch.elapsed.inSeconds} s');
        expect(target.lengthSync(), component.size);
      },
      timeout: const Timeout(Duration(minutes: 20)),
      skip: folder == null ? 'set IMMUCH360_AI_REAL_DOWNLOAD to a folder to download the real models' : null,
    );
  }
}
