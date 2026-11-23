// The measure of the depth model on the graphics card (lot ai-360-3d-51), with the libraries the CI made: compiled by
// dart compile exe on the Windows runner (no Flutter), part of the artifact Immuch360-AI-tools-windows-x64. It opens
// Video Depth Anything Small as a 3D video job does (ort/depth_provider.dart: the devices, the plan, the check against
// the processor, the session of the card), times a few windows of 32 frames at SIDE x SIDE on it, then one on the
// processor, and compares the two maps. One JSON line per event.
//
//   depth_provider_probe --cpu LIBRARY --card LIBRARY --model FILE [--side 392] [--windows 2] [--device auto]
//   [--no-processor] [--allow-software]

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/ort/depth_provider.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';

void _emit(String event, Map<String, Object?> fields) => stdout.writeln(jsonEncode({'event': event, ...fields}));

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  final flags = <String>{};
  for (var i = 0; i < args.length; i++) {
    if (const {'--no-processor', '--allow-software'}.contains(args[i])) {
      flags.add(args[i]);
    } else {
      options[args[i]] = args[++i];
    }
  }
  final cpu = options['--cpu'];
  final model = options['--model'];
  if (cpu == null || model == null) {
    stderr.writeln('depth_provider_probe --cpu LIBRARY --card LIBRARY --model FILE [--side 392] [--windows 2]');
    exitCode = 2;
    return;
  }
  final side = int.parse(options['--side'] ?? '392');
  final windows = int.parse(options['--windows'] ?? '2');
  final settings = OrtSessionSettings.forThisComputer();
  final opening = Stopwatch()..start();
  final depth = openDepthSession(
    processorLibrary: cpu,
    cardLibrary: options['--card'],
    modelPath: model,
    width: side,
    height: side,
    settings: settings,
    choice: options['--device'] ?? depthDeviceAuto,
    allowSoftware: flags.contains('--allow-software'),
  );
  for (final line in depth.lines) {
    _emit('log', {'line': line});
  }
  _emit('opened', {
    'ms': opening.elapsedMilliseconds,
    'provider': '${depth.session.provider}',
    'plan': depth.plan.title,
  });
  final input = depthCheckInput(side: side);
  final shape = [1, 32, 3, side, side];
  Float32List? onCard;
  for (var i = 0; i < windows; i++) {
    final watch = Stopwatch()..start();
    onCard = depth.session.run(input, shape).values;
    _emit('window', {'on': '${depth.session.provider}', 'ms': watch.elapsedMilliseconds});
  }
  depth.session.close();
  if (flags.contains('--no-processor') || onCard == null || !depth.plan.isGraphicsCard) {
    return;
  }
  final processor = OrtRuntime.load(cpu).openSession(model, settings: settings);
  final watch = Stopwatch()..start();
  final reference = processor.run(input, shape).values;
  _emit('window', {'on': 'CPU', 'ms': watch.elapsedMilliseconds, 'threads': settings.intraOpThreads});
  processor.close();
  final difference = depthDifference(onCard, reference);
  _emit('compared', {'largest': difference.largest, 'mean': difference.mean});
}
