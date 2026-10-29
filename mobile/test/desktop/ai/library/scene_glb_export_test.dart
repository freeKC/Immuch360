// The .glb of a 3D scene for other 3D apps: the binary glTF of a photo of Immuch360 read whole and checked, refused for
// a photo that carries none and for one cut short; written beside then renamed, never onto the scene; the first free
// name next to the scene; "Export for other 3D apps (.glb)" through the save dialog of the system; and "Also save a .glb
// copy", next to each scene the queue makes, never for a version of another kind.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/library/scene_glb_export.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:path/path.dart' as p;

import '../../../widget_tester_extensions.dart';
import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_scene_engine.dart';

const _fixture = 'test/fixtures/ai_immersive/tiny_scene3D.jpg';

/// The save dialog of the test: it answers [answer] and keeps what it was asked
class _Pickers implements FilePickers {
  String? answer;
  final asked = <({String suggestedName, String? initialDirectory, List<String> extensions})>[];

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async => null;

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async {
    asked.add((suggestedName: suggestedName, initialDirectory: initialDirectory, extensions: extensions));
    return answer;
  }
}

/// The writer of the queue: the .part next to the target, renamed onto the final name
class _Output implements ConversionOutput {
  @override
  Future<String> begin(ConversionJob job) async {
    final target = job.target!;
    final path = p.join(target.folder, '.${target.fileName}.part');
    File(path).writeAsBytesSync(const []);
    return path;
  }

  @override
  Future<ConversionSaved> finish(
    ConversionJob job,
    String partPath, {
    required ImmersiveSource original,
    required AiWhenExists whenExists,
    String? replaceName,
  }) async {
    File(partPath).renameSync(job.target!.path);
    return ConversionSaved(path: job.target!.path, outcome: ConversionSaveOutcome.saved);
  }

  @override
  Future<void> discard(String partPath) async {
    final file = File(partPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('scene_glb_export'));
  tearDown(() => root.deleteSync(recursive: true));

  /// A copy of the scene of the fixtures, named [name]
  String scene(String name) => File(_fixture).copySync(p.join(root.path, name)).path;

  List<String> names() => [for (final entry in root.listSync()) p.basename(entry.path)]..sort();

  test('the scene of a photo of Immuch360, read whole and checked', () async {
    final glb = await sceneGlbOf(scene('salon_scene3D.jpg'));
    expect(glb, FakeSceneTail.fixture.glb);
    expect(String.fromCharCodes(glb.sublist(0, 4)), 'glTF');
  });

  test('refused for a photo that carries no scene, and for a scene cut short', () async {
    Future<SceneGlbProblem?> problemOf(String path) async {
      try {
        await sceneGlbOf(path);
        return null;
      } on SceneGlbException catch (error) {
        return error.problem;
      }
    }

    final plain = File(p.join(root.path, 'salon.jpg'))..writeAsBytesSync(List.generate(500, (i) => i & 0xff));
    expect(await problemOf(plain.path), SceneGlbProblem.notScene);
    final cut = File(scene('cut_scene3D.jpg'));
    final bytes = cut.readAsBytesSync();
    cut.writeAsBytesSync(Uint8List.sublistView(bytes, 0, bytes.length - 10));
    expect(await problemOf(cut.path), SceneGlbProblem.missing);
    expect(await problemOf(p.join(root.path, 'gone_scene3D.jpg')), SceneGlbProblem.missing);
  });

  test('written beside, then renamed onto its name; never onto the scene itself', () async {
    final path = scene('salon_scene3D.jpg');
    final before = File(path).readAsBytesSync();
    final glb = await sceneGlbOf(path);

    await writeSceneGlb(glb, p.join(root.path, 'salon.glb'), scenePath: path);
    expect(File(p.join(root.path, 'salon.glb')).readAsBytesSync(), glb);
    expect(names(), ['salon.glb', 'salon_scene3D.jpg'], reason: 'no partial file left');

    await expectLater(
      writeSceneGlb(glb, path, scenePath: path),
      throwsA(isA<SceneGlbException>().having((error) => error.problem, 'problem', SceneGlbProblem.writeFailed)),
    );
    expect(File(path).readAsBytesSync(), before);

    await expectLater(
      writeSceneGlb(glb, p.join(root.path, 'missing', 'salon.glb'), scenePath: path),
      throwsA(isA<SceneGlbException>().having((error) => error.problem, 'problem', SceneGlbProblem.writeFailed)),
    );
    expect(names(), ['salon.glb', 'salon_scene3D.jpg']);
  });

  test('the copy next to a scene takes the first free name', () {
    final path = p.join(root.path, 'salon_scene3D.jpg');
    expect(freeGlbPathNextTo(path), p.join(root.path, 'salon_scene3D.glb'));
    File(p.join(root.path, 'salon_scene3D.glb')).writeAsStringSync('mine');
    File(p.join(root.path, 'salon_scene3D (1).glb')).writeAsStringSync('mine too');
    expect(freeGlbPathNextTo(path), p.join(root.path, 'salon_scene3D (2).glb'));
  });

  testWidgets('"Export for other 3D apps (.glb)": the save dialog next to the scene, the .glb where the user says', (
    tester,
  ) async {
    final path = scene('salon_scene3D.jpg');
    final exports = Directory(p.join(root.path, 'exports'))..createSync();
    final pickers = _Pickers()..answer = p.join(exports.path, 'mine');
    filePickers = pickers;
    addTearDown(() => filePickers = const SystemFilePickers());
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('export'),
            onPressed: () => unawaited(exportSceneGlb(context, path)),
            child: const Text('export'),
          ),
        ),
      ),
    );

    final written = File(p.join(exports.path, 'mine.glb'));
    await tester.tap(find.byKey(const Key('export')));
    // The files are read and written for real: real time and frames until the message shows
    for (var step = 0; step < 300 && find.byType(SnackBar).evaluate().isEmpty; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }

    expect(pickers.asked.single.suggestedName, 'salon_scene3D.glb');
    expect(pickers.asked.single.initialDirectory, root.path);
    expect(pickers.asked.single.extensions, ['glb']);
    expect(written.readAsBytesSync(), FakeSceneTail.fixture.glb, reason: '.glb added to a name without it');
    expect(find.text('Saved in ${exports.path}: mine.glb'), findsOneWidget);

    // Closed without a place: nothing written
    pickers.answer = null;
    await tester.tap(find.byKey(const Key('export')));
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(pickers.asked, hasLength(2));
    expect(exports.listSync(), hasLength(1));
  });

  test('"Also save a .glb copy": next to each scene the queue makes, never for a 3D photo', () async {
    final container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWithValue(
          ConversionTools(
            engine: FakeImmersiveEngine(),
            engines: fakeConversionEngines(scene: FakeSceneEngine()),
            output: _Output(),
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    ConversionRequest request(String name, ConversionKind kind) {
      final path = p.join(root.path, name);
      File(path).writeAsBytesSync(List.generate(100, (i) => (i * 7 + name.length) & 0xff));
      return ConversionRequest(
        source: LocalFileSource(path),
        target: ConversionTarget.nextTo(path, kind: kind),
      );
    }

    final queue = container.read(conversionQueueProvider.notifier);
    final copies = container.read(sceneGlbCopiesProvider.notifier);
    final scenes = queue.add([
      request('salon.jpg', ConversionKind.sceneFromPhoto),
    ], kind: ConversionKind.sceneFromPhoto);
    final photos = queue.add([request('jardin.jpg', ConversionKind.sbsFromPhoto)]);
    copies.follow([...scenes, ...photos]);
    for (var wait = 0; wait < 200; wait++) {
      final jobs = container.read(conversionQueueProvider).jobs;
      if (jobs.every((job) => job.state.isEnded) && container.read(sceneGlbCopiesProvider).containsKey(scenes.single)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final copy = container.read(sceneGlbCopiesProvider)[scenes.single]!;
    expect(copy.path, p.join(root.path, 'salon_scene3D.glb'));
    expect(File(copy.path!).readAsBytesSync(), FakeSceneTail.fixture.glb);
    expect(container.read(sceneGlbCopiesProvider).containsKey(photos.single), isFalse);
    expect(names(), [
      'jardin.jpg',
      'jardin_3D_LRF_Full_SBS.jpg',
      'salon.jpg',
      'salon_scene3D.glb',
      'salon_scene3D.jpg',
    ]);
  });
}
