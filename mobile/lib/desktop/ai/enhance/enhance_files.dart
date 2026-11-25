// Where the files of each level of "Enhance (AI)" are on this computer: the AI components the app downloads, or, for
// a developer test only, the folder of the probe of 23 November 2026.
//
// The components (ai_enhance_manifest.dart): Sharpen takes the sd-cli and x4plus of the 360° panoramas, Rebuild details
// the sd-cli of the script mode and SeedVR2 3B with its VAE, Natural the ONNX Runtime of the 3D photos and the four
// graphs of VOSR. A level whose components are incomplete in this version (the sd-cli of Rebuild details until
// ai-components-7 is published), or are in ai-components-7 while it is not published (Rebuild details and Natural:
// aiEnhanceComponentsPublished), is "not in this version yet". On a Mac with an Apple chip (release 53) Sharpen and
// Rebuild details take the Metal build of that sd-cli (sdCppSeedVr2MacArmComponent, with x4plus for Sharpen, SeedVR2
// for Rebuild details): "not in this version yet" until it is published (aiEnhanceMacEnginePublished).
//
// The developer override, off by default: when the variable IMMUCH360_ENHANCE_PROBE names a folder laid out as the
// probe's (D:\DEV\immuch\ai-enhance-probe on the owner's PC: engines\shipped\, engines\sdcpp-master-1117-0d71f96-win-vulkan\,
// downloads\seedvr2\, downloads\vosr2-int8\), each level whose files are all there takes them from it, Windows only
// (the programs there are .exe). Nothing is downloaded or copied; the app's log says the folder is used.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart' show linuxLauncherName;
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_enhance_manifest.dart';
import 'package:path/path.dart' as p;

/// The variable of the developer override
const enhanceProbeVariable = 'IMMUCH360_ENHANCE_PROBE';

/// The files of Sharpen: sd-cli and x4plus
class SharpenFiles {
  const SharpenFiles({required this.sdCli, required this.upscaler, this.linuxLauncher});

  final String sdCli;
  final String upscaler;
  final String? linuxLauncher;
}

/// The files of one level, of the kind of that level, and where they come from
class EnhanceFiles {
  const EnhanceFiles({this.sharpen, this.rebuild, this.natural, this.fromProbe = false});

  final SharpenFiles? sharpen;
  final RebuildFiles? rebuild;
  final VosrFiles? natural;

  /// Taken from the folder of the developer override
  final bool fromProbe;
}

/// The components [level] needs on [platform], in the order they are downloaded; empty where the level does not run
List<AiComponent> enhanceComponentsOf(EnhanceLevel level, AiPlatform platform) {
  final windows = platform == AiPlatform.windowsX64;
  final linux = platform == AiPlatform.linuxX64;
  final appleChip = platform == AiPlatform.macosArm64;
  return switch (level) {
    EnhanceLevel.sharpen when windows || linux || appleChip => [
      windows
          ? sdCppWindowsComponent
          : linux
          ? sdCppLinuxComponent
          : sdCppSeedVr2MacArmComponent,
      upscalerComponent,
    ],
    EnhanceLevel.rebuild when windows || linux || appleChip => [
      windows
          ? sdCppSeedVr2WindowsComponent
          : linux
          ? sdCppSeedVr2LinuxComponent
          : sdCppSeedVr2MacArmComponent,
      seedVr2DitComponent,
      seedVr2VaeComponent,
    ],
    EnhanceLevel.natural when windows || linux || platform == AiPlatform.macosArm64 => [
      switch (platform) {
        AiPlatform.windowsX64 => onnxRuntimeWindowsComponent,
        AiPlatform.linuxX64 => onnxRuntimeLinuxComponent,
        _ => onnxRuntimeMacArmComponent,
      },
      ...vosrComponents,
    ],
    _ => const [],
  };
}

/// What the components of [level] give on [platform]: the files when all are installed, else those missing (to
/// download) or, for a component of this version without its size or sum, of ai-components-7 while it is not
/// published ([published], aiEnhanceComponentsPublished), or the Metal engine while it is not published
/// ([macPublished], aiEnhanceMacEnginePublished), the level is not in this version yet
typedef EnhanceComponentsFound = ({EnhanceFiles? files, List<AiComponent> missing, bool notInThisVersion});

Future<EnhanceComponentsFound> enhanceComponentFiles(
  EnhanceLevel level,
  AiPlatform platform,
  AiComponentFiles components, {
  bool published = aiEnhanceComponentsPublished,
  bool macPublished = aiEnhanceMacEnginePublished,
}) async {
  final needed = enhanceComponentsOf(level, platform);
  if (needed.isEmpty ||
      needed.any((component) => !component.isComplete) ||
      (!published && needed.any((component) => component.releaseTag == aiComponentsEnhanceReleaseTag)) ||
      (!macPublished && needed.contains(sdCppSeedVr2MacArmComponent))) {
    return (files: null, missing: const <AiComponent>[], notInThisVersion: true);
  }
  final found = <String, String>{};
  final missing = <AiComponent>[];
  for (final component in needed) {
    final file = await components.verifiedFile(component);
    if (file == null) {
      missing.add(component);
    } else {
      found[component.id] = file.path;
    }
  }
  if (missing.isNotEmpty) {
    return (files: null, missing: missing, notInThisVersion: false);
  }
  String launcherBeside(String program) => p.join(p.dirname(program), linuxLauncherName);
  final linux = platform == AiPlatform.linuxX64;
  final files = switch (level) {
    EnhanceLevel.sharpen => EnhanceFiles(
      sharpen: SharpenFiles(
        sdCli: found[needed[0].id]!,
        upscaler: found[upscalerComponent.id]!,
        linuxLauncher: linux ? launcherBeside(found[needed[0].id]!) : null,
      ),
    ),
    EnhanceLevel.rebuild => EnhanceFiles(
      rebuild: RebuildFiles(
        sdCli: found[needed[0].id]!,
        dit: found[seedVr2DitComponent.id]!,
        vae: found[seedVr2VaeComponent.id]!,
        linuxLauncher: linux ? launcherBeside(found[needed[0].id]!) : null,
      ),
    ),
    EnhanceLevel.natural => EnhanceFiles(
      natural: VosrFiles(
        library: found[needed[0].id]!,
        imageEncoder: found[vosrImageEncoderComponent.id]!,
        vaeEncoder: found[vosrVaeEncoderComponent.id]!,
        transformer: found[vosrTransformerComponent.id]!,
        vaeDecoder: found[vosrVaeDecoderComponent.id]!,
      ),
    ),
  };
  return (files: files, missing: const <AiComponent>[], notInThisVersion: false);
}

/// The folder of the developer override when [environment] names one that exists, on Windows only
String? enhanceProbeFolder({Map<String, String>? environment, bool? windows}) {
  final folder = (environment ?? Platform.environment)[enhanceProbeVariable]?.trim();
  if (folder == null || folder.isEmpty || !(windows ?? Platform.isWindows) || !Directory(folder).existsSync()) {
    return null;
  }
  return folder;
}

/// The files of [level] in the probe's [folder], null when one of them is not there
EnhanceFiles? enhanceProbeFiles(EnhanceLevel level, String folder) {
  String at(List<String> parts) => p.joinAll([folder, ...parts]);
  bool all(List<String> paths) => paths.every((path) => File(path).existsSync());
  switch (level) {
    case EnhanceLevel.sharpen:
      final files = SharpenFiles(
        sdCli: at(['engines', 'shipped', 'sd-cpp-vulkan-win-x64', 'sd-cli.exe']),
        upscaler: at(['engines', 'shipped', 'models', 'RealESRGAN_x4plus.pth']),
      );
      return all([files.sdCli, files.upscaler]) ? EnhanceFiles(sharpen: files, fromProbe: true) : null;
    case EnhanceLevel.rebuild:
      final files = RebuildFiles(
        sdCli: at(['engines', 'sdcpp-master-1117-0d71f96-win-vulkan', 'sd-cli.exe']),
        dit: at(['downloads', 'seedvr2', 'seedvr2_3b_int8_convrot.safetensors']),
        vae: at(['downloads', 'seedvr2', 'seedvr2_ema_vae_fp16.safetensors']),
      );
      return all([files.sdCli, files.dit, files.vae]) ? EnhanceFiles(rebuild: files, fromProbe: true) : null;
    case EnhanceLevel.natural:
      String graph(String part) => at(['downloads', 'vosr2-int8', part, 'model.onnx']);
      final files = VosrFiles(
        library: at(['engines', 'shipped', 'onnxruntime-1.31.0', 'onnxruntime.dll']),
        imageEncoder: graph('image_encoder'),
        vaeEncoder: graph('vae_encoder'),
        transformer: graph('transformer'),
        vaeDecoder: graph('vae_decoder'),
      );
      return all([files.library, files.imageEncoder, files.vaeEncoder, files.transformer, files.vaeDecoder])
          ? EnhanceFiles(natural: files, fromProbe: true)
          : null;
  }
}
