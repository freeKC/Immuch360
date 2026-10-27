// The panel of the conversions and the button of the app bar, with the real queue and the fake engine: per photo its
// name, kind, state in the words of the spec, "n of m", destination, quality flags and actions (Cancel, Retry, Open
// folder, View by the path of the opened files, Delete this 3D photo asked first and refused for a file that is not
// ours); at the bottom Cancel all, Retry failed, Clear finished, and Resume after a disk full; the button that shows
// the jobs under way. Then "Delete this 3D photo" from the Versions of the details, whose row goes at once, and the
// files it never deletes: ours without a DerivativeId, and any other.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/library/versions_section.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_bar_button.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;

import '../../../widget_tester_extensions.dart';
import '../fakes/fake_immersive_engine.dart';

/// The engine of the test: the fake of a photo by its name, else one that ends well
class _Engines implements ImmersiveEngine {
  final byName = <String, FakeImmersiveEngine>{};
  final fallback = FakeImmersiveEngine(qualityFlags: const [ReliefQualityFlag.dark]);

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) => (byName[job.source.name] ?? fallback).run(job, cancel: cancel, onProgress: onProgress);

  @override
  Future<void> dispose() async {}
}

/// The writer of the test: the .part next to the target, renamed onto the final name; a disk full when asked
class _Output implements ConversionOutput {
  ImmersiveErrorCode? failFinish;

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
    final code = failFinish;
    if (code != null) {
      throw ConversionException(code);
    }
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
  late String photos;
  late _Engines engines;
  late _Output output;
  late List<String> openedFolders;
  late List<String> viewed;

  setUp(() {
    root = Directory.systemTemp.createTempSync('conversions_panel');
    photos = p.join(root.path, 'Photos');
    Directory(photos).createSync();
    engines = _Engines();
    output = _Output();
    openedFolders = [];
    viewed = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  List<Override> overrides({bool enabled = true}) => [
    conversionToolsProvider.overrideWithValue(
      ConversionTools(
        engine: engines,
        output: output,
        finder: ExistingVersionFinder(),
        creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
      ),
    ),
    conversionFolderOpenerProvider.overrideWithValue((folder) async => openedFolders.add(folder)),
    versionOpenerProvider.overrideWithValue(viewed.add),
    conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
    aiFeaturesEnabledProvider.overrideWith((ref) => enabled),
  ];

  ConversionRequest photo(String name) {
    final path = p.join(photos, name);
    File(path).writeAsBytesSync(List.generate(100, (i) => (i * 5 + name.length) & 0xff));
    return ConversionRequest(source: LocalFileSource(path), target: ConversionTarget.nextTo(path));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var step = 0; step < 30; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<ProviderContainer> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(const Scaffold(body: ConversionsPanel()), overrides: overrides());
    return ProviderScope.containerOf(tester.element(find.byType(ConversionsPanel)));
  }

  Finder inRow(String id, Finder finder) => find.descendant(of: find.byKey(ValueKey('ai_job_$id')), matching: finder);

  testWidgets('each photo: its name, kind, state, place in the batch, destination and actions', (tester) async {
    engines.byName['b.jpg'] = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
    final container = await pumpPanel(tester);
    final queue = container.read(conversionQueueProvider.notifier);
    final ids = queue.add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')]);
    container.read(conversionJobInfoProvider.notifier).addAll({ids[0]: const ConversionJobInfo(isNetwork: false)});
    await settle(tester);

    // The honesty label under the title
    expect(find.text('Relief estimated by AI'), findsOneWidget);
    // a.jpg done: its 3D photo, the quality flag, saved on this computer only, and its actions
    final written = p.join(photos, 'a_3D_LRF_Full_SBS.jpg');
    expect(inRow(ids[0], find.text('a.jpg')), findsOneWidget);
    expect(inRow(ids[0], find.text('2D to 3D SBS  •  1 of 3')), findsOneWidget);
    expect(inRow(ids[0], find.text('Done')), findsOneWidget);
    expect(inRow(ids[0], find.text(written)), findsOneWidget);
    expect(inRow(ids[0], find.text('Dark photo: the relief may be wrong')), findsOneWidget);
    expect(inRow(ids[0], find.byKey(const Key('ai_job_local_only'))), findsOneWidget);
    expect(inRow(ids[0], find.byKey(const Key('ai_job_cancel'))), findsNothing);
    // b.jpg computing, held; c.jpg waiting
    expect(inRow(ids[1], find.textContaining('Computing')), findsOneWidget);
    expect(inRow(ids[1], find.byType(LinearProgressIndicator)), findsOneWidget);
    expect(inRow(ids[1], find.text(photos)), findsOneWidget, reason: 'where its 3D photo goes');
    expect(inRow(ids[2], find.text('Waiting')), findsOneWidget);

    // Open folder and View, by the path of the opened files
    await tester.tap(inRow(ids[0], find.byKey(const Key('ai_job_open_folder'))));
    await tester.pump();
    expect(openedFolders, [photos]);
    await tester.tap(inRow(ids[0], find.byKey(const Key('ai_job_view'))));
    await tester.pump();
    expect(viewed, [written]);

    // Cancel the one waiting, then the one under way
    await tester.tap(inRow(ids[2], find.byKey(const Key('ai_job_cancel'))));
    await settle(tester);
    expect(inRow(ids[2], find.text('Cancelled')), findsOneWidget);
    await tester.tap(inRow(ids[1], find.byKey(const Key('ai_job_cancel'))));
    engines.byName['b.jpg']!.release();
    await settle(tester);
    expect(inRow(ids[1], find.text('Cancelled')), findsOneWidget);
    expect(Directory(photos).listSync().map((entry) => p.basename(entry.path)).toSet(), {
      'a.jpg',
      'b.jpg',
      'c.jpg',
      'a_3D_LRF_Full_SBS.jpg',
    });

    // Retry runs a cancelled one again
    engines.byName.remove('b.jpg');
    await tester.tap(inRow(ids[1], find.byKey(const Key('ai_job_retry'))));
    await settle(tester);
    expect(inRow(ids[1], find.text('Done')), findsOneWidget);
  });

  testWidgets('a 3D photo on a network folder is not "saved on this computer only"; the edits of Immich are said', (
    tester,
  ) async {
    final container = await pumpPanel(tester);
    final ids = container.read(conversionQueueProvider.notifier).add([photo('nas.jpg'), photo('here.jpg')]);
    container.read(conversionJobInfoProvider.notifier).addAll({
      ids[0]: const ConversionJobInfo(isNetwork: true, serverEdits: true),
      ids[1]: const ConversionJobInfo(isNetwork: false),
    });
    await settle(tester);

    expect(inRow(ids[0], find.text('Done')), findsOneWidget);
    expect(inRow(ids[0], find.byKey(const Key('ai_job_local_only'))), findsNothing);
    expect(inRow(ids[0], find.text('Edits made in Immich, except the rotation, are not applied')), findsOneWidget);
    expect(inRow(ids[1], find.byKey(const Key('ai_job_local_only'))), findsOneWidget);
    expect(inRow(ids[1], find.text('Edits made in Immich, except the rotation, are not applied')), findsNothing);
  });

  test('Delete never touches a file with our XMP but no DerivativeId, nor one without our XMP', () async {
    const noId = StereoPhotoXmp(
      eyes: StereoEyes.full,
      eyeOrder: EyeOrder.leftRight,
      eyeWidth: 8,
      eyeHeight: 6,
      origin: ImmersiveOrigin.estimatedDepth,
      sourceName: 'salon.jpg',
    );
    const blankId = StereoPhotoXmp(
      eyes: StereoEyes.full,
      eyeOrder: EyeOrder.leftRight,
      eyeWidth: 8,
      eyeHeight: 6,
      origin: ImmersiveOrigin.estimatedDepth,
      derivativeId: '  ',
    );
    final withoutId = File(p.join(photos, 'a_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(fakeSbsJpeg(xmp: noId));
    final blank = File(p.join(photos, 'b_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(fakeSbsJpeg(xmp: blankId));
    final plain = File(p.join(photos, 'c_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(List.generate(300, (i) => i & 0xff));
    expect(StereoPhotoXmp.findIn(withoutId.readAsBytesSync()), isNotNull, reason: 'our packet is there');

    expect(await deleteOurVersion(withoutId.path), VersionDeleteOutcome.refused);
    expect(await deleteOurVersion(blank.path), VersionDeleteOutcome.refused);
    expect(await deleteOurVersion(plain.path), VersionDeleteOutcome.refused);
    expect([withoutId, blank, plain].every((file) => file.existsSync()), isTrue);
    expect(await deleteOurVersion(p.join(photos, 'gone_3D_LRF_Full_SBS.jpg')), VersionDeleteOutcome.failed);
  });

  testWidgets('a failure says why; Retry failed, Cancel all and Clear finished act on the whole queue', (tester) async {
    engines.byName['broken.jpg'] = FakeImmersiveEngine(failAt: ImmersiveStage.decoding);
    engines.byName['slow.jpg'] = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
    final container = await pumpPanel(tester);
    final queue = container.read(conversionQueueProvider.notifier);
    final ids = queue.add([photo('broken.jpg'), photo('slow.jpg'), photo('next.jpg')]);
    await settle(tester);

    expect(inRow(ids[0], find.text('Failed')), findsOneWidget);
    expect(inRow(ids[0], find.text('This photo could not be read')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai_conversions_cancel_all')));
    engines.byName['slow.jpg']!.release();
    await settle(tester);
    expect(container.read(conversionQueueProvider).jobs.map((job) => job.state), [
      ConversionState.failed,
      ConversionState.cancelled,
      ConversionState.cancelled,
    ]);

    engines.byName.remove('broken.jpg');
    await tester.tap(find.byKey(const Key('ai_conversions_retry_failed')));
    await settle(tester);
    expect(inRow(ids[0], find.text('Done')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai_conversions_clear_finished')));
    await tester.pump();
    expect(container.read(conversionQueueProvider).jobs, isEmpty);
    expect(find.byKey(const Key('ai_conversions_clear_finished')), findsNothing);
  });

  testWidgets('a disk full pauses the queue: the panel says so, and Resume runs that photo again', (tester) async {
    output.failFinish = ImmersiveErrorCode.diskFull;
    final container = await pumpPanel(tester);
    final id = container.read(conversionQueueProvider.notifier).add([photo('salon.jpg')]).single;
    await settle(tester);

    expect(find.text('Disk full: free some space, then Resume'), findsOneWidget);
    expect(inRow(id, find.text('Disk full')), findsOneWidget);

    output.failFinish = null;
    await tester.tap(find.byKey(const Key('ai_conversions_resume')));
    await settle(tester);
    expect(find.byKey(const Key('ai_conversions_paused')), findsNothing);
    expect(inRow(id, find.text('Done')), findsOneWidget);
  });

  testWidgets('Delete this 3D photo asks first, deletes ours, and refuses a file that is not ours', (tester) async {
    final container = await pumpPanel(tester);
    final ids = container.read(conversionQueueProvider.notifier).add([photo('a.jpg'), photo('b.jpg')]);
    await settle(tester);
    final ours = File(p.join(photos, 'a_3D_LRF_Full_SBS.jpg'));
    final foreign = File(p.join(photos, 'b_3D_LRF_Full_SBS.jpg'));
    expect(ours.existsSync() && foreign.existsSync(), isTrue);
    // A file of the user took the name of the second one meanwhile
    foreign.writeAsBytesSync(List.generate(300, (i) => i & 0xff));

    // Asked first: Cancel keeps it
    await tester.tap(inRow(ids[0], find.byKey(const Key('ai_job_delete'))));
    await tester.pumpAndSettle();
    expect(find.text('Delete this 3D photo? The original stays as it is.\na_3D_LRF_Full_SBS.jpg'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(ours.existsSync(), isTrue);

    await tester.tap(inRow(ids[0], find.byKey(const Key('ai_job_delete'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_delete_confirm_yes')));
    await settle(tester);
    expect(ours.existsSync(), isFalse);
    expect(File(p.join(photos, 'a.jpg')).existsSync(), isTrue, reason: 'the original stays');
    expect(find.byKey(ValueKey('ai_job_${ids[0]}')), findsNothing, reason: 'its job is gone from the panel');
    expect(container.read(deletedVersionsProvider), {ours.path}, reason: 'left out of the details until the next scan');

    await tester.tap(inRow(ids[1], find.byKey(const Key('ai_job_delete'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_delete_confirm_yes')));
    await settle(tester);
    expect(foreign.existsSync(), isTrue);
    expect(find.text('This file was not made by Immuch360, so it is not deleted'), findsOneWidget);
  });

  testWidgets('the button of the app bar: absent with no job or with the AI features off, the jobs under way', (
    tester,
  ) async {
    engines.byName['a.jpg'] = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
    await tester.pumpConsumerWidget(const Scaffold(body: DesktopConversionsBarButton()), overrides: overrides());
    expect(find.byKey(const Key('ai_conversions_button')), findsNothing);

    final container = ProviderScope.containerOf(tester.element(find.byType(DesktopConversionsBarButton)));
    container.read(conversionQueueProvider.notifier).add([photo('a.jpg'), photo('b.jpg')]);
    await settle(tester);
    expect(find.byKey(const Key('ai_conversions_button')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai_conversions_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_conversions_panel')), findsOneWidget);
    engines.byName['a.jpg']!.release();
    await settle(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpConsumerWidget(
      const Scaffold(body: DesktopConversionsBarButton()),
      overrides: overrides(enabled: false),
    );
    final again = ProviderScope.containerOf(tester.element(find.byType(DesktopConversionsBarButton)));
    again.read(conversionQueueProvider.notifier).add([photo('c.jpg')]);
    await settle(tester);
    expect(find.byKey(const Key('ai_conversions_button')), findsNothing);
  });

  testWidgets('Delete this 3D photo from the Versions of the details: ours deleted, a foreign file kept', (
    tester,
  ) async {
    final xmp = StereoPhotoXmp.estimated(
      eyeWidth: 8,
      eyeHeight: 6,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: 'salon.jpg',
      sourceSize: 100,
      sourceSha1: 'c3VtIG9mIHNhbG9u',
      sourceQuarterTurns: 0,
      created: '2026-10-27T10:12:00+01:00',
      creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
    );
    final ours = File(p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(fakeSbsJpeg(xmp: xmp));
    final foreign = File(p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg'))
      ..writeAsBytesSync(List.generate(300, (i) => i & 0xff));
    VersionFile version(File file) => VersionFile(
      file: LibraryFile(
        assetId: 'id-${p.basename(file.path)}',
        path: file.path,
        name: p.basename(file.path),
        kind: LibraryMediaKind.image,
        size: file.lengthSync(),
        modifiedMs: 0,
        createdSeconds: 0,
        mimeType: 'image/jpeg',
        cloudOnly: false,
        available: true,
      ),
      origin: IndexedOrigin.estimated,
    );
    final original = LocalAsset(
      id: 'id-salon',
      name: 'salon.jpg',
      type: AssetType.image,
      createdAt: DateTime(2026, 10, 20),
      updatedAt: DateTime(2026, 10, 20),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );
    var asked = 0;
    await tester.pumpConsumerWidget(
      Scaffold(
        body: SingleChildScrollView(child: DesktopVersionsTiles(asset: original)),
      ),
      overrides: [
        photoVersionsProvider(original).overrideWith((ref) async {
          asked++;
          return PhotoVersions(versions: [version(ours), version(foreign)]);
        }),
        versionThumbnailProvider.overrideWithValue((file) => const ColoredBox(color: Colors.grey)),
        versionOpenerProvider.overrideWithValue(viewed.add),
      ],
    );
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('desktop_version_delete_id-salon_3D_LRF_Full_SBS.jpg')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_delete_confirm_yes')));
    await settle(tester);
    expect(ours.existsSync(), isFalse);
    expect(asked, 2, reason: 'the versions are read again');
    // The index still lists it until the next scan of its folder: its row goes all the same
    expect(find.byKey(const ValueKey('desktop_version_delete_id-salon_3D_LRF_Full_SBS.jpg')), findsNothing);
    expect(find.byKey(const ValueKey('desktop_version_delete_id-salon_3D_LRF_Full_SBS (1).jpg')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('desktop_version_delete_id-salon_3D_LRF_Full_SBS (1).jpg')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_delete_confirm_yes')));
    await settle(tester);
    expect(foreign.existsSync(), isTrue);
    expect(find.text('This file was not made by Immuch360, so it is not deleted'), findsOneWidget);
    expect(viewed, isEmpty, reason: 'the delete button does not open the version');

    // Made again at the same place, it comes back
    ours.writeAsBytesSync(fakeSbsJpeg(xmp: xmp));
    ProviderScope.containerOf(
      tester.element(find.byType(DesktopVersionsTiles)),
    ).invalidate(photoVersionsProvider(original));
    await settle(tester);
    expect(find.byKey(const ValueKey('desktop_version_delete_id-salon_3D_LRF_Full_SBS.jpg')), findsOneWidget);
  });
}
