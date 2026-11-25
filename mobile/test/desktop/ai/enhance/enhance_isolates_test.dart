// Issue 23: "Enhance (AI)" through the queue of the app as it runs there, the isolates real. The tools of the queue
// hold a real DesktopAiSettingsStore (its futures go nowhere an isolate is), each level runs the real EnhanceEngine
// with its real backend: Sharpen and Rebuild details on sd-cli as it answers (the fakes of fake_enhance_tools.dart
// play the program), Natural spawning its worker on a runtime that is not there. Before the fix, every photo of every
// level failed at once with "Illegal argument in isolate message: object is unsendable - Library:'dart:async' Class:
// _Future": the closures EnhanceEngine.run gave Isolate.run carried the progress callback of the queue.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart' show SbsCodecChoice;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/desktop_enhance.dart' show enhanceConversionEngine;
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/app_progress.dart';
import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_enhance_tools.dart';
import '../fakes/fake_immersive_engine.dart';

const _fixture = 'test/fixtures/ai_immersive/codec/quality_90.jpg';

class _Memory implements MemoryProbe {
  const _Memory();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 64 << 30, available: 48 << 30);
}

void main() {
  late Directory root;
  late Directory photos;
  late DesktopAiSettingsStore settings;
  late ProviderContainer container;

  EnhanceEngine engineOf(EnhanceBackend backend) => EnhanceEngine(
    backend: backend,
    codecs: SbsCodecChoice.dart,
    memory: const _Memory(),
    workFolder: (id) => Directory(p.join(root.path, 'work-$id'))..createSync(),
  );

  SdCppSettings sdCpp() => SdCppSettings(
    sdCli: p.join(root.path, 'sd-cli'),
    models: const SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: ''),
    device: 'Vulkan1',
    card: const SdCppCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', integrated: false),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('enhance_isolates');
    addTearDown(() => root.deleteSync(recursive: true));
    photos = Directory(p.join(root.path, 'photos'))..createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    settings = DesktopAiSettingsStore(settingsDirectory: () async => support);
    SdCppDevice.forgetLearned();
    final engines = {
      EnhanceLevel.sharpen: engineOf(SdCppSharpenBackend(upscaler: FakeX4Upscaler())),
      EnhanceLevel.rebuild: engineOf(
        SdCppRebuildBackend(
          runner: FakeSeedVr2Runner(),
          settings: sdCpp(),
          files: const RebuildFiles(sdCli: 'sd-cli', dit: '/m/dit.safetensors', vae: '/m/vae.safetensors'),
          modelSha256: 'c3dec8bcc5916843a8a858572970597462e1f2dc598d6dfd818f6cd40f53a157',
          graphicsFree: 7 << 30,
        ),
      ),
      EnhanceLevel.natural: engineOf(
        OrtNaturalBackend(
          files: VosrFiles(
            library: p.join(root.path, 'no-runtime', 'libonnxruntime.so'),
            imageEncoder: p.join(root.path, 'image_encoder.onnx'),
            vaeEncoder: p.join(root.path, 'vae_encoder.onnx'),
            transformer: p.join(root.path, 'transformer.onnx'),
            vaeDecoder: p.join(root.path, 'vae_decoder.onnx'),
          ),
          modelSha256: 'ab' * 32,
          threads: 2,
        ),
      ),
    };
    container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: FakeImmersiveEngine(),
            engines: {
              for (final MapEntry(key: level, value: engine) in engines.entries)
                ConversionKind.enhanceAt(level): enhanceConversionEngine(engine),
            },
            output: FakeConversionOutput(),
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.4.7 (linux)',
            settings: settings,
            memory: const _Memory(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  ConversionQueueState current() => container.read(conversionQueueProvider);

  Future<ConversionJob> enhanced(EnhanceLevel level) async {
    final path = p.join(photos.path, 'photo.jpg');
    File(_fixture).copySync(path);
    final id = container.read(conversionQueueProvider.notifier).add([
      ConversionRequest(
        source: LocalFileSource(path, hash: (path, cancel) async => 'c2hh'),
        target: ConversionTarget(
          folder: photos.path,
          fileName: versionTargetName(ImmersiveKind.enhancedPhoto, 'photo.jpg'),
        ),
      ),
    ], kind: ConversionKind.enhanceAt(level)).single;
    final ended = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!ended.isCompleted && next.byId(id)!.state.isEnded) {
        ended.complete();
      }
    });
    try {
      if (!current().byId(id)!.state.isEnded) {
        await ended.future.timeout(const Duration(seconds: 60));
      }
    } finally {
      subscription.close();
    }
    return current().byId(id)!;
  }

  test('the settings store of the tools is what no isolate takes (the guard is not vacuous)', () async {
    await expectUnsendable(settings);
  });

  for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
    test('${level.name}: the photo is enhanced through the queue of the app, its isolates real', () async {
      final job = await enhanced(level);
      expect(job.state, ConversionState.done, reason: '${job.error}: ${job.message}');
      final written = File(job.writtenPath!).readAsBytesSync();
      final decoded = const DartSbsCodec().decodeJpeg(written);
      expect(decoded.width, greaterThan(0));
      expect(ImmersiveXmp.findIn(written), isA<EnhancedPhotoXmp>());
    });
  }

  test('natural: the photo reaches the worker of VOSR, which says its runtime is missing', () async {
    final job = await enhanced(EnhanceLevel.natural);
    expect(job.state, ConversionState.failed);
    expect(job.message, isNot(contains('isolate message')));
    expect(job.error, ImmersiveErrorCode.componentsMissing, reason: job.message);
  });
}
