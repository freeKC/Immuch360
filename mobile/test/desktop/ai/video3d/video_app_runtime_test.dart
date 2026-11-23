import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/depth_provider.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_app_runtime.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';

import '../ort/ort_for_tests.dart';

Uint8List _frame(int index) {
  final rgb = Uint8List(28 * 28 * 3);
  for (var i = 0; i < rgb.length; i++) {
    rgb[i] = (i * 7 + index * (index < 37 ? 3 : 11)) % (index < 37 ? 90 : 250);
  }
  return rgb;
}

void main() {
  test('the flags and the request that keep the computer awake', () {
    expect(SystemSleepGuard.windowsHold, 0x80000001);
    expect(SystemSleepGuard.windowsRelease, 0x80000000);
    expect(SystemSleepGuard.linuxInhibit.$1, 'sleep:idle');
    expect(SystemSleepGuard.linuxInhibit.$4, 'block');
  });

  test('a program started for its bytes gives its output as it wrote it', skip: Platform.isWindows, () async {
    final runner = ManagedVideoProgramRunner(ManagedProcessRunner());
    final program = await runner.start('/bin/sh', ['-c', r"printf '\000\001\377'; echo oops >&2; exit 3"]);
    final bytes = await program.stdout.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    expect(bytes, [0, 1, 255]);
    expect(await program.exitCode, 3);
    expect(await program.errors, 'oops\n');
  });

  final ort = ortForTests();
  test('the worker isolate gives the frames of the worker in place, and stops when asked', skip: ort.skip, () async {
    final model = File('test/fixtures/ai_immersive/tiny_vda.onnx').absolute.path;
    final worker = await IsolateVideoFrameWorker.spawn(
      VideoWorkerSetup(
        ortLibrary: ort.library!,
        modelPath: model,
        eyeWidth: 28,
        eyeHeight: 28,
        modelWidth: 14,
        modelHeight: 14,
        parallax: 0.03,
        convergence: 0.5,
        half: false,
        edgeFade: true,
        alignment: VideoDepthAlignment.upstream,
        intraOpThreads: 1,
        lowPriority: false,
        // Compared byte for byte with the processor below: on Apple silicon "automatic" takes Core ML, whose depth
        // agrees within the check's 2 %, not to the bit
        depthDevice: depthDeviceProcessor,
      ),
    );
    final session = OrtRuntime.load(
      ort.library!,
    ).openSession(model, settings: const OrtSessionSettings(intraOpThreads: 1));
    addTearDown(session.close);
    final local = LocalVideoFrameWorker(
      ops: const DartVideoFrameOps(),
      model: (input, width, height) => session
          .runNamed({
            'frames': OrtTensor([1, vdaWindowLength, 3, height, width], input),
          })
          .values
          .single
          .values,
      eyeWidth: 28,
      eyeHeight: 28,
      modelWidth: 14,
      modelHeight: 14,
      relief: const VideoReliefSettings(parallax: 0.03),
    );
    final there = <VideoSbsFrame>[];
    final here = <VideoSbsFrame>[];
    for (var i = 0; i < 60; i++) {
      there.addAll(await worker.add(_frame(i)));
      here.addAll(await local.add(_frame(i)));
      if (i == 31) {
        // Right after the first window (the cut at 37 restarts the windows after it)
        expect(await worker.stateAfterWindow(), isNotNull);
      }
    }
    there.addAll(await worker.finish());
    here.addAll(await local.finish());
    expect(there.length, 60);
    for (var i = 0; i < 60; i++) {
      expect((there[i].index, there[i].holes), (here[i].index, here[i].holes));
      expect(base64.encode(there[i].bytes), base64.encode(here[i].bytes), reason: 'frame $i');
    }
    expect((await worker.counts()).cuts, (await local.counts()).cuts);
    // A stop asked from here ends the next window's run with VideoJobStopped
    worker.stop();
    final after = [for (var i = 0; i < 31; i++) _frame(i)];
    await expectLater(() async {
      for (final frame in after) {
        await worker.add(frame);
      }
      await worker.finish();
    }(), throwsA(isA<VideoJobStopped>()));
    await worker.close();
  });
}
