// The components of this computer installed from the files of the release (lot A3b), by hand only: the real catalogue,
// the real service, and the files of IMMUCH360_AI_COMPONENTS_MIRROR (the folder .github/desktop/ai/
// publish_ai_components.py fills before the publication, or the address of the published release). It proves that the
// release files, the catalogue and the service agree: each library unpacks to the size and SHA-256 of the catalogue,
// with its notices and its licence. Skipped unless IMMUCH360_AI_MIRROR_INSTALL names the folder to install into; the
// installed ONNX Runtime can then be given to the tests of test/desktop/ai/ort (IMMUCH360_ORT_LIB).
//
//   IMMUCH360_AI_COMPONENTS_MIRROR=/mnt/d/DEV/immuch/ai-immersive/components IMMUCH360_AI_MIRROR_INSTALL=/tmp/ai \
//     flutter test test/desktop/ai/components/mirror_install_test.dart
//
// IMMUCH360_AI_MIRROR_FEATURE names another feature (scene, panorama, stereoPanorama): its components are installed
// the same way, the files of 2 GiB or more from their parts, and those this version does not have yet (the engine of
// the panoramas until lot P2) are left out and said.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';

void main() {
  final folder = Platform.environment['IMMUCH360_AI_MIRROR_INSTALL'];
  final mirror = Platform.environment[aiComponentsMirrorVariable];
  final named = Platform.environment['IMMUCH360_AI_MIRROR_FEATURE'];
  final feature = AiFeature.values.where((feature) => feature.name == named).firstOrNull ?? AiFeature.stereoPhoto;
  final platform = switch (Abi.current()) {
    Abi.windowsX64 => AiPlatform.windowsX64,
    Abi.linuxX64 => AiPlatform.linuxX64,
    Abi.macosArm64 => AiPlatform.macosArm64,
    Abi.macosX64 => AiPlatform.macosX64,
    _ => null,
  };

  test(
    'the components of a feature of this computer, installed from the mirror, sums checked',
    () async {
      final service = AiComponentsService(folder: () async => Directory(folder!));
      final watch = Stopwatch()..start();

      for (final component in aiComponentsFor(platform!, feature: feature)) {
        if (!component.isComplete) {
          // ignore: avoid_print
          print('${component.id}: not in this version yet, left out');
          continue;
        }
        await service.install(component);
        final file = await service.verifiedFile(component);

        expect(file, isNotNull, reason: component.id);
        if (!component.isArchive) {
          expect(file!.lengthSync(), component.size);
        }
        expect((await service.licenceOf(component)).existsSync(), isTrue);
        final notices = await service.noticesOf(component);
        if (notices != null) {
          expect(notices.lengthSync(), component.notices!.size);
        }
        // ignore: avoid_print
        print('${component.id}: ${file!.path}, ${file.lengthSync()} bytes${component.isInParts ? ' from parts' : ''}');
      }
      // ignore: avoid_print
      print('installed in ${watch.elapsed.inMilliseconds} ms, ${await service.spaceUsed()} bytes in $folder');
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: folder == null || mirror == null
        ? 'set $aiComponentsMirrorVariable and IMMUCH360_AI_MIRROR_INSTALL to install from the files of the release'
        : platform == null
        ? 'no AI components for ${Abi.current()}'
        : null,
  );
}
