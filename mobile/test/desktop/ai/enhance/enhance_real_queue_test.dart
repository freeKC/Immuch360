// Enhance (AI) run for real through the queue of the app, by hand only (issue 23). The queue, its ConversionTools with
// a real DesktopAiSettingsStore, the writer of the app (SafeWriterOutput, its journal in the work folder), an AiProcessSession and the engine of each
// level are put together as desktop_conversion_tools.dart and DesktopEnhanceEngine put them together, from the files
// of the developer override (enhanceProbeFiles: the folder laid out as D:\DEV\immuch\ai-enhance-probe). Only the gate
// is left out: the card is named by the variables, as the probe of release 51 named it. Never in the CI.
//
//   IMMUCH360_ENHANCE_REAL=/mnt/d/DEV/immuch/ai-enhance-probe     the folder of the files
//   IMMUCH360_ENHANCE_PHOTO=/mnt/d/.../text3_in.jpg               the photo, copied into the work folder
//   IMMUCH360_ENHANCE_WORK=/mnt/d/DEV/immuch/release-53/issue23   where the photo, its versions and the session go
//   IMMUCH360_ENHANCE_LEVELS=sharpen,natural                      the levels to run, in order
//   IMMUCH360_ENHANCE_DEVICE=Vulkan1 IMMUCH360_ENHANCE_CARD="NVIDIA GeForce RTX 4060 Laptop GPU"
//   IMMUCH360_ENHANCE_ORT=/path/libonnxruntime.so.1.31.0          Natural under Linux (the probe holds the Windows DLL)
//
// Under WSL, sd-cli.exe of the probe is started through the interop of Windows: its paths are given in the form of
// Windows (D:\...), which is the only change to what the app starts.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/enhance/desktop_enhance.dart' show enhanceConversionEngine;
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_immersive_engine.dart';

final _env = Platform.environment;

/// A Windows program started from Linux (WSL): the paths of its arguments in the form of Windows
class _WslPaths implements ProcessRunner {
  const _WslPaths(this.inner);

  final ProcessRunner inner;

  static String windowsOf(String argument) => argument.replaceAllMapped(
    RegExp(r'/mnt/([a-z])/([^\s"]*)'),
    (match) => '${match.group(1)!.toUpperCase()}:\\${match.group(2)!.replaceAll('/', r'\')}',
  );

  @override
  Future<RunningProcess> start(ProcessLaunch launch) {
    final windows = Platform.isLinux && launch.executable.toLowerCase().endsWith('.exe');
    stdout.writeln('start ${launch.executable} ${launch.arguments.map(windows ? windowsOf : (a) => a).join(' ')}');
    return inner.start(
      windows
          ? ProcessLaunch(
              executable: launch.executable,
              arguments: [for (final argument in launch.arguments) windowsOf(argument)],
              workingDirectory: launch.workingDirectory,
              environment: launch.environment,
              lowPriority: launch.lowPriority,
            )
          : launch,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final probe = _env['IMMUCH360_ENHANCE_REAL'];
  final skip = probe == null ? 'IMMUCH360_ENHANCE_REAL names no folder of the files of Enhance' : null;

  test(
    'each level enhances the photo through the queue of the app',
    () async {
      final work = Directory(_env['IMMUCH360_ENHANCE_WORK']!);
      final photos = Directory(p.join(work.path, 'photos'))..createSync(recursive: true);
      final photo = p.join(photos.path, p.basename(_env['IMMUCH360_ENHANCE_PHOTO']!));
      if (!File(photo).existsSync()) {
        File(_env['IMMUCH360_ENHANCE_PHOTO']!).copySync(photo);
      }
      final support = Directory(p.join(work.path, 'support'))..createSync(recursive: true);
      final session = AiProcessSession(folders: AiWorkFolders(Directory(p.join(work.path, 'session'))));
      final levels = [
        for (final name in _env['IMMUCH360_ENHANCE_LEVELS']!.split(',')) EnhanceLevel.values.byName(name),
      ];

      // The engine of a level as DesktopEnhanceEngine makes it for a job (_backendOf, then run)
      EnhanceEngine engineOf(EnhanceLevel level) {
        final files = enhanceProbeFiles(level, probe!)!;
        final EnhanceBackend backend;
        switch (level) {
          case EnhanceLevel.natural:
            final natural = files.natural!;
            backend = OrtNaturalBackend(
              files: VosrFiles(
                library: _env['IMMUCH360_ENHANCE_ORT'] ?? natural.library,
                imageEncoder: natural.imageEncoder,
                vaeEncoder: natural.vaeEncoder,
                transformer: natural.transformer,
                vaeDecoder: natural.vaeDecoder,
              ),
              modelSha256: vosrTransformerComponent.sha256!,
            );
          case EnhanceLevel.sharpen:
            final sharpen = files.sharpen!;
            final settings = SdCppSettings(
              sdCli: sharpen.sdCli,
              models: SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: sharpen.upscaler),
              device: _env['IMMUCH360_ENHANCE_DEVICE']!,
              card: SdCppCard(name: _env['IMMUCH360_ENHANCE_CARD']!, integrated: false),
              stallTimeout: const Duration(seconds: 180),
            );
            final runner = _WslPaths(session.runner(linuxLauncher: sharpen.linuxLauncher));
            backend = SdCppSharpenBackend(
              upscaler: SdCppUpscaler(runner: runner, settings: settings, modelSha256: upscalerComponent.sha256!),
            );
          case EnhanceLevel.rebuild:
            throw UnsupportedError('Rebuild details is not part of this run');
        }
        return EnhanceEngine(
          backend: backend,
          decodeOther: decodeWithEngine,
          workFolder: (id) => session.folders.create('enhance-$id'),
          dropWorkFolder: (folder) => session.folders.delete(folder),
        );
      }

      final container = ProviderContainer(
        overrides: [
          conversionToolsProvider.overrideWith(
            (ref) => ConversionTools(
              engine: FakeImmersiveEngine(),
              engines: {
                for (final level in levels) ConversionKind.enhanceAt(level): enhanceConversionEngine(engineOf(level)),
              },
              output: SafeWriterOutput(
                writer: SafeWriter(journal: InflightJournal(settingsDirectory: () async => support)),
                mayWriteInto: (folder) async => true,
              ),
              finder: ExistingVersionFinder(),
              creatorTool: 'Immuch360 Desktop 3.4.7 (issue 23 check)',
              software: 'Immuch360 Desktop 3.4.7',
              settings: DesktopAiSettingsStore(settingsDirectory: () async => support),
              processors: Platform.numberOfProcessors,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      for (final level in levels) {
        final clock = Stopwatch()..start();
        final id = container
            .read(conversionQueueProvider.notifier)
            .add(
              [
                ConversionRequest(
                  source: LocalFileSource(photo),
                  target: ConversionTarget(
                    folder: photos.path,
                    fileName: versionTargetName(ImmersiveKind.enhancedPhoto, p.basename(photo)),
                  ),
                ),
              ],
              kind: ConversionKind.enhanceAt(level),
              existing: ExistingVersionChoice.newVersion,
              enhance: EnhanceSettings(level: level, strength: level.defaultStrength),
            )
            .single;
        final ended = Completer<void>();
        var said = '';
        final subscription = container.listen(conversionQueueProvider, (_, next) {
          final job = next.byId(id)!;
          final now = '${job.state.name} ${job.perMille}';
          if (now != said && (job.perMille % 100 == 0 || job.state.isEnded)) {
            said = now;
            stdout.writeln('${level.name} ${clock.elapsed.inSeconds} s: $now ${job.step ?? ''}/${job.steps ?? ''}');
          }
          if (job.state.isEnded && !ended.isCompleted) {
            ended.complete();
          }
        });
        try {
          await ended.future.timeout(const Duration(minutes: 15));
        } finally {
          subscription.close();
        }
        final job = container.read(conversionQueueProvider).byId(id)!;
        stdout.writeln(
          '${level.name}: ${job.state.name} in ${clock.elapsed.inMilliseconds} ms, ${job.error?.name ?? ''} '
          '${job.message ?? ''} ${job.writtenPath ?? ''} ${job.details}',
        );
        expect(job.state, ConversionState.done, reason: '${job.error}: ${job.message}');
        expect(File(job.writtenPath!).lengthSync(), greaterThan(0));
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
