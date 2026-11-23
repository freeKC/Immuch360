// A small program that enhances one photo through the engine of "Enhance (AI)" of the app (EnhanceEngine and the
// backend of the level: SdCppSharpenBackend, SdCppRebuildBackend, OrtNaturalBackend), with no Flutter: compiled by
// `dart compile exe` in the windows job of the desktop workflow (artifact Immuch360-AI-tools-windows-x64), so that the
// three levels can run on a PC with a graphics card from the files of the published components, before the levels are
// offered (release 51). Only the choice of the card is left to the arguments: the app takes it from its probe of the
// cards (enhance_gpu.dart), here --device and --card name it, and sd-cli's own list checks it as in the app.
// It prints one JSON line per event, with the milliseconds since its start:
//   started   a program started (sd-cli), its id
//   progress  a stage of the engine, its thousandths, the tile done of all
//   ended     the result: made with the size, the bytes written and the time of each stage, or the code of its failure
//   gone      whether each program started is still running at its id after the end (it must not)
//
//   enhance_probe --level sharpen|rebuild|natural --in PHOTO.jpg --out FILE.jpg --work DIR [--strength N]
//                 sharpen: --sd-cli EXE --upscaler RealESRGAN_x4plus.pth
//                 rebuild: --sd-cli EXE --dit seedvr2_3b_int8_convrot.safetensors --vae seedvr2_ema_vae_fp16.safetensors
//                 natural: --ort onnxruntime.dll --vosr DIR (the four graphs under their asset names)
//                 [--device Vulkan1] [--card NAME] [--graphics-free BYTES] [--threads N]
// The photo must be a JPEG (the engine of Flutter decodes the other formats in the app, not here).

import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:path/path.dart' as p;

final _clock = Stopwatch()..start();

void _event(String name, [Map<String, Object?> values = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, 'ms': _clock.elapsedMilliseconds, ...values}));

/// Announces the programs it starts
class _Announcing implements ProcessRunner {
  _Announcing(this.inner);

  final ProcessRunner inner;
  final pids = <int>[];

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final process = await inner.start(launch);
    pids.add(process.pid);
    _event('started', {'pid': process.pid, 'executable': launch.executable});
    return process;
  }
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i++) {
    if (arguments[i].startsWith('--')) {
      options[arguments[i].substring(2)] = arguments[++i];
    }
  }
  String need(String name) => p.absolute(options[name] ?? (throw ArgumentError('--$name is missing')));
  final level = EnhanceLevel.values.byName(options['level'] ?? (throw ArgumentError('--level is missing')));
  final input = File(need('in'));
  final out = need('out');
  final work = Directory(need('work'))..createSync(recursive: true);
  final strength = int.parse(options['strength'] ?? '${level.defaultStrength}');
  final runner = _Announcing(ManagedProcessRunner.open());
  final cancel = NativeCancelFlag();

  SdCppSettings sdCpp(String sdCli, {String upscaler = ''}) => SdCppSettings(
    sdCli: sdCli,
    models: SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: upscaler),
    device: options['device'] ?? 'Vulkan1',
    card: options['card'] == null ? null : SdCppCard(name: options['card']!, integrated: false),
    threads: options['threads'] == null ? null : int.parse(options['threads']!),
  );
  final EnhanceBackend backend = switch (level) {
    EnhanceLevel.sharpen => SdCppSharpenBackend(
      upscaler: SdCppUpscaler(
        runner: runner,
        settings: sdCpp(need('sd-cli'), upscaler: need('upscaler')),
        modelSha256: upscalerComponent.sha256!,
      ),
    ),
    EnhanceLevel.rebuild => SdCppRebuildBackend(
      runner: runner,
      settings: sdCpp(need('sd-cli')),
      files: RebuildFiles(sdCli: need('sd-cli'), dit: need('dit'), vae: need('vae')),
      modelSha256: seedVr2DitComponent.sha256!,
      graphicsFree: options['graphics-free'] == null ? null : int.parse(options['graphics-free']!),
    ),
    EnhanceLevel.natural => OrtNaturalBackend(
      files: VosrFiles(
        library: need('ort'),
        imageEncoder: p.join(need('vosr'), vosrImageEncoderComponent.assetName),
        vaeEncoder: p.join(need('vosr'), vosrVaeEncoderComponent.assetName),
        transformer: p.join(need('vosr'), vosrTransformerComponent.assetName),
        vaeDecoder: p.join(need('vosr'), vosrVaeDecoderComponent.assetName),
      ),
      modelSha256: vosrTransformerComponent.sha256!,
      threads: options['threads'] == null ? null : int.parse(options['threads']!),
    ),
  };
  final engine = EnhanceEngine(
    backend: backend,
    workFolder: (id) => Directory(p.join(work.path, 'enhance-$id'))..createSync(recursive: true),
  );
  final bytes = input.readAsBytesSync();
  final part = '$out.part';
  final job = EnhanceJob(
    id: level.name,
    source: ImmersiveSource(name: p.basename(input.path), size: bytes.length, sha1: '', path: input.path),
    partPath: part,
    derivativeId: 'enhance-probe-${level.name}',
    creatorTool: 'Immuch360 enhance_probe',
    created: DateTime.now().toUtc().toIso8601String(),
    level: level,
    strength: strength,
  );
  var lastStage = '';
  var lastStep = -1;
  final result = await engine.run(
    job,
    cancel: cancel,
    onProgress: (progress) {
      final step = progress.step ?? -1;
      if (progress.stage.name != lastStage || step != lastStep) {
        lastStage = progress.stage.name;
        lastStep = step;
        _event('progress', {
          'stage': progress.stage.name,
          'perMille': progress.perMille,
          'step': progress.step,
          'steps': progress.steps,
        });
      }
    },
  );
  final times = {for (final entry in result.stageTimes.entries) entry.key.name: entry.value.inMilliseconds};
  if (result.error == null && File(part).existsSync()) {
    File(part).renameSync(out);
    _event('ended', {
      'result': 'made',
      'out': out,
      'bytes': File(out).lengthSync(),
      'model': backend.model,
      'fellBack': backend.fellBack,
      'stageMs': times,
    });
  } else {
    _event('ended', {'result': result.error?.name ?? 'noFile', 'message': result.message, 'stageMs': times});
  }
  for (final pid in runner.pids) {
    _event('gone', {'pid': pid, 'gone': processImageOf(pid) == null});
  }
  cancel.free();
}
