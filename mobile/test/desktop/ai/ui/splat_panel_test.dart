// A splat scene in the panel of the conversions (plan 2026-11-01, section 2.1, points 5 and 6, lot SP7), from the
// states of the queue: "Done: 150,000 gaussians, 3.4 MiB, from 150 of 150 photos" or "of frames", the .ply kept for
// other 3D apps, the photos COLMAP could not place, the photos left out as blurred, the blurred frames of a video,
// Open folder and "How to open it in the headset" with the line of a folder of the network or of this computer; no
// View and no Delete for a file the computer neither shows nor marks as ours; the training with its step and the time
// left; a refusal of integrated graphics in the words of the splat scenes; a scene of fewer than half of its images
// placed, said from the poses to the result, and the work folder kept after a failure of COLMAP, named (lot SPF1); the
// matching of a video in blocks; and the close of the window that names the step of a scene being made.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/window/close_guard.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

import '../../../widget_tester_extensions.dart';

/// A queue that shows [shown]
class _ShownQueue extends ConversionQueueNotifier {
  _ShownQueue(this.shown);

  final ConversionQueueState shown;

  @override
  ConversionQueueState build() => shown;
}

/// The source of a splat scene as the queue shows it: the name the dialog gave it ("salon (150 photos)")
class _Named implements ConversionSource {
  const _Named(this.name);

  @override
  final String name;

  @override
  String? get folder => '/photos/salon';

  @override
  ImmersiveExif get exif => const ImmersiveExif();

  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) => throw UnimplementedError();

  @override
  Future<void> release() async {}
}

LocalAsset _photo(String name) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: AssetType.image,
  createdAt: DateTime(2026, 10, 20, 9),
  updatedAt: DateTime(2026, 10, 20, 9),
  width: 4000,
  height: 3000,
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

/// A job of a splat scene named [label], written to [written] when it is done
ConversionJob _splat(
  String id, {
  String label = 'salon (150 photos)',
  ConversionState state = ConversionState.done,
  String folder = '/photos/salon',
  String? written = '/photos/salon/salon_splat.spz',
  SplatResultDetails? details,
  bool fromVideo = false,
  int? step,
  int? steps,
  Duration? remaining,
  ImmersiveErrorCode? error,
  String? message,
  SplatPlaced? placed,
  String? keptFolder,
  SplatSubject subject = SplatSubject.place,
}) => ConversionJob(
  id: id,
  source: _Named(label),
  kind: ConversionKind.splatScene,
  batchIndex: 1,
  batchSize: 1,
  target: ConversionTarget(folder: folder, fileName: 'salon_splat.spz'),
  state: state,
  writtenPath: state == ConversionState.done ? written : null,
  details: details,
  fromVideo: fromVideo,
  step: step,
  steps: steps,
  remaining: remaining,
  error: error,
  message: message,
  placed: placed,
  keptFolder: keptFolder,
  splat: SplatSelection(
    members: const [],
    settings: SplatSettings(subject: subject),
  ),
);

void main() {
  late Map<String, int> sizes;
  late List<String> openedFolders;

  setUp(() {
    sizes = {'/photos/salon/salon_splat.spz': 3612448, '/nas/splats/salon_splat.spz': 3612448};
    openedFolders = [];
  });

  Future<void> pumpPanel(
    WidgetTester tester,
    List<ConversionJob> jobs, {
    Map<String, ConversionJobInfo> infos = const {},
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      const Scaffold(body: ConversionsPanel()),
      overrides: [
        conversionQueueProvider.overrideWith(() => _ShownQueue(ConversionQueueState(jobs: jobs))),
        splatFileSizeProvider.overrideWith((ref, path) async => sizes[path]),
        conversionFolderOpenerProvider.overrideWithValue((folder) async => openedFolders.add(folder)),
        conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
        aiFeaturesEnabledProvider.overrideWith((ref) => true),
      ],
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(ConversionsPanel)));
    container.read(conversionJobInfoProvider.notifier).addAll(infos);
    await tester.pumpAndSettle();
  }

  Finder inRow(String id, Finder finder) => find.descendant(of: find.byKey(ValueKey('ai_job_$id')), matching: finder);

  testWidgets('a scene of photos done: its gaussians, its size, its photos placed; Open folder and the headset line', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      [
        _splat(
          'conversion-1',
          details: const SplatResultDetails(
            gaussians: 150000,
            images: 150,
            placed: 150,
            subject: SplatSubject.place,
            scale: 0.42,
          ),
        ),
      ],
      infos: {'conversion-1': ConversionJobInfo(asset: _photo('IMG_0000.jpg'))},
    );

    expect(inRow('conversion-1', find.text('salon (150 photos)')), findsOneWidget);
    expect(inRow('conversion-1', find.text('Photos to splat scene')), findsOneWidget);
    expect(
      inRow('conversion-1', find.text('Done: 150,000 gaussians, 3.4 MiB, from 150 of 150 photos')),
      findsOneWidget,
    );
    expect(inRow('conversion-1', find.text('/photos/salon/salon_splat.spz')), findsOneWidget);
    expect(inRow('conversion-1', find.byKey(const Key('ai_job_splat_partial'))), findsNothing);
    expect(inRow('conversion-1', find.byKey(const Key('ai_job_splat_blurred_photos'))), findsNothing);
    expect(inRow('conversion-1', find.byKey(const Key('ai_job_splat_ply'))), findsNothing);
    // No viewer of splat scenes on the computer, and a .spz carries no XMP to tell it is ours
    expect(inRow('conversion-1', find.byKey(const Key('ai_job_view'))), findsNothing);
    expect(inRow('conversion-1', find.byKey(const Key('ai_job_delete'))), findsNothing);
    // Saved on this computer: how the headset gets the file, never "Share this computer", which serves the media of
    // the library only (seen in the test build T1)
    expect(
      tester.widget<Text>(inRow('conversion-1', find.byKey(const Key('ai_job_local_only')))).data,
      "Your headset cannot see this folder: choose a folder on your NAS, or copy the file to the headset's Download "
      'folder.',
    );
    expect(inRow('conversion-1', find.textContaining('Share this computer')), findsNothing);

    await tester.tap(inRow('conversion-1', find.byKey(const Key('ai_job_open_folder'))));
    await tester.pump();
    expect(openedFolders, ['/photos/salon']);

    await tester.tap(inRow('conversion-1', find.byKey(const Key('ai_job_splat_headset'))));
    await tester.pumpAndSettle();
    expect(find.text('How to open it in the headset'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const Key('ai_job_splat_headset_dialog')),
        matching: find.text(
          "Your headset cannot see this folder: choose a folder on your NAS, or copy the file to the headset's "
          'Download folder.',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('ai_job_splat_headset_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_job_splat_headset_dialog')), findsNothing);
  });

  testWidgets('a scene of a video on the NAS: frames left out, blurred frames, the .ply, and the headset line', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      [
        _splat(
          'conversion-2',
          label: 'Salon tour.mp4',
          folder: '/nas/splats',
          written: '/nas/splats/salon_splat.spz',
          fromVideo: true,
          details: const SplatResultDetails(
            gaussians: 148211,
            images: 150,
            placed: 120,
            subject: SplatSubject.place,
            scale: 0.42,
            fromVideo: true,
            blurred: 52,
            plyBytes: 35400000,
          ),
        ),
      ],
      infos: const {'conversion-2': ConversionJobInfo(isNetwork: true)},
    );

    expect(inRow('conversion-2', find.text('Video to splat scene')), findsOneWidget);
    expect(
      inRow('conversion-2', find.text('Done: 148,211 gaussians, 3.4 MiB, from 120 of 150 frames')),
      findsOneWidget,
    );
    expect(
      inRow(
        'conversion-2',
        find.text('30 of 150 frames could not be placed and were left out: the scene may miss what only they saw.'),
      ),
      findsOneWidget,
    );
    expect(
      inRow(
        'conversion-2',
        find.text(
          'Many frames of this video are blurred (52 of 202): the scene may be poor. Film more slowly, with more light.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      inRow('conversion-2', find.text('Also saved for other 3D apps: salon_splat.ply (33.8 MiB)')),
      findsOneWidget,
    );

    await tester.tap(inRow('conversion-2', find.byKey(const Key('ai_job_splat_headset'))));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'In the headset: open this folder in Network shares, then salon_splat.spz, Explore the splat scene. Turn on '
        "Large splats (experimental) in the headset's settings to see all 148,211 gaussians.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('photos left out as blurred are said: the user chose 150, the scene was made of 140', (tester) async {
    SplatResultDetails blurred(int count) => SplatResultDetails(
      gaussians: 150000,
      images: 150 - count,
      placed: 150 - count,
      subject: SplatSubject.place,
      scale: 0.42,
      blurred: count,
    );
    await pumpPanel(tester, [
      _splat('conversion-6', details: blurred(10)),
      _splat('conversion-7', details: blurred(1)),
      _splat('conversion-8', details: blurred(0)),
    ]);

    expect(
      inRow('conversion-6', find.text('Done: 150,000 gaussians, 3.4 MiB, from 140 of 140 photos')),
      findsOneWidget,
    );
    expect(inRow('conversion-6', find.text('10 photos left out: blurred')), findsOneWidget);
    expect(inRow('conversion-7', find.text('1 photo left out: blurred')), findsOneWidget);
    expect(inRow('conversion-8', find.byKey(const Key('ai_job_splat_done'))), findsOneWidget);
    expect(inRow('conversion-8', find.byKey(const Key('ai_job_splat_blurred_photos'))), findsNothing);
    // Not the sentence of the frames of a video, which says a share of the frames
    expect(inRow('conversion-6', find.byKey(const Key('ai_job_splat_blurred'))), findsNothing);
  });

  testWidgets('a few blurred frames are not said, nor the photos left out above nine in ten placed', (tester) async {
    await pumpPanel(tester, [
      _splat(
        'conversion-3',
        fromVideo: true,
        details: const SplatResultDetails(
          gaussians: 150000,
          images: 150,
          placed: 140,
          subject: SplatSubject.object,
          scale: 1,
          fromVideo: true,
          blurred: 20,
        ),
      ),
    ]);
    expect(inRow('conversion-3', find.byKey(const Key('ai_job_splat_done'))), findsOneWidget);
    expect(inRow('conversion-3', find.byKey(const Key('ai_job_splat_blurred'))), findsNothing);
    expect(inRow('conversion-3', find.byKey(const Key('ai_job_splat_partial'))), findsNothing);
  });

  testWidgets('a scene being trained: its step and the time left; refused on integrated graphics, in its words', (
    tester,
  ) async {
    await pumpPanel(tester, [
      _splat(
        'conversion-4',
        state: ConversionState.training,
        step: 12400,
        steps: 20000,
        remaining: const Duration(minutes: 3),
      ),
      _splat(
        'conversion-5',
        state: ConversionState.failed,
        error: ImmersiveErrorCode.gpuUnavailable,
        message: AiGateReason.splatGpuIntegrated.name,
      ),
    ]);
    expect(inRow('conversion-4', find.textContaining('Training the splat')), findsOneWidget);
    expect(inRow('conversion-4', find.text('step 12,400 of 20,000, about 3 min left')), findsOneWidget);
    expect(inRow('conversion-4', find.byKey(const Key('ai_job_splat_headset'))), findsNothing);
    expect(
      inRow(
        'conversion-5',
        find.text(
          'Integrated graphics are not supported for splat scenes yet: a dedicated graphics card with Vulkan is needed',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('fewer than half of the images placed: said while the scene trains and in its result, instead of the '
      'images left out', (tester) async {
    await pumpPanel(tester, [
      _splat(
        'conversion-9',
        state: ConversionState.training,
        fromVideo: true,
        step: 400,
        steps: 20000,
        placed: const SplatPlaced(68, 139),
      ),
      _splat(
        'conversion-10',
        fromVideo: true,
        placed: const SplatPlaced(68, 139),
        details: const SplatResultDetails(
          gaussians: 129325,
          images: 139,
          placed: 68,
          subject: SplatSubject.object,
          scale: 0.05,
          fromVideo: true,
          blurred: 11,
        ),
      ),
      _splat(
        'conversion-11',
        state: ConversionState.training,
        step: 400,
        steps: 20000,
        placed: const SplatPlaced(129, 139),
      ),
    ]);

    const line = '68 of 139 images placed in 3D: the scene may be incomplete';
    expect(inRow('conversion-9', find.text(line)), findsOneWidget);
    expect(inRow('conversion-9', find.byKey(const Key('ai_job_splat_incomplete'))), findsOneWidget);
    expect(
      inRow('conversion-10', find.text('Done: 129,325 gaussians, 3.4 MiB, from 68 of 139 frames')),
      findsOneWidget,
    );
    expect(inRow('conversion-10', find.text(line)), findsOneWidget);
    expect(inRow('conversion-10', find.byKey(const Key('ai_job_splat_partial'))), findsNothing);
    // 129 of 139: nothing said while it trains
    expect(inRow('conversion-11', find.byKey(const Key('ai_job_splat_incomplete'))), findsNothing);
  });

  testWidgets('a failure of COLMAP: its refusal, and the work folder kept until the next scene named; none after a '
      'Cancel', (tester) async {
    const kept = r'C:\Users\freek\AppData\Local\Temp\immuch360-ai\splat-e263f1e4fcd3d331';
    await pumpPanel(tester, [
      _splat('conversion-12', state: ConversionState.failed, error: ImmersiveErrorCode.posesStalled, keptFolder: kept),
      _splat('conversion-13', state: ConversionState.failed, error: ImmersiveErrorCode.tooFewImages, message: '12/24'),
    ]);

    expect(
      inRow(
        'conversion-12',
        find.text(
          'The prepared images and the work files are kept until the next scene or for 24 h, for Retry and for a '
          'diagnosis: $kept',
        ),
      ),
      findsOneWidget,
    );
    expect(inRow('conversion-12', find.byKey(const Key('ai_job_retry'))), findsOneWidget);
    expect(inRow('conversion-13', find.byKey(const Key('ai_job_splat_work_kept'))), findsNothing);
  });

  testWidgets('too few images placed (lot SPF2): no Retry, which would place the same ones; what to do instead, in '
      'the words of photos, of a video of an object, of a video of a place; the folder kept for a diagnosis', (
    tester,
  ) async {
    const kept = r'C:\Users\freek\AppData\Local\Temp\immuch360-ai\splat-e263f1e4fcd3d331';
    await pumpPanel(tester, [
      _splat(
        'conversion-14',
        state: ConversionState.failed,
        fromVideo: true,
        subject: SplatSubject.object,
        error: ImmersiveErrorCode.notEnoughOverlap,
        message: '40/139',
        keptFolder: kept,
      ),
      _splat(
        'conversion-15',
        state: ConversionState.failed,
        fromVideo: true,
        error: ImmersiveErrorCode.notEnoughOverlap,
        message: '30/140',
      ),
      _splat(
        'conversion-16',
        state: ConversionState.failed,
        error: ImmersiveErrorCode.notEnoughOverlap,
        message: '20/96',
      ),
    ]);

    expect(
      inRow(
        'conversion-14',
        find.text(
          'Only 40 of 139 frames could be placed in 3D, and a Retry would place the same ones. Film the object again '
          'from 20 to 30 cm away at least, so that it stays sharp, set a plain object on a surface with a pattern (a '
          'newspaper, a printed cloth), and walk around it several times, at two heights.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      inRow(
        'conversion-15',
        find.text(
          'Only 30 of 140 frames could be placed in 3D, and a Retry would place the same ones. Film the place again, '
          'walking slowly, looking across it rather than at plain walls, windows and mirrors.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      inRow(
        'conversion-16',
        find.text(
          'Only 20 of 96 photos could be placed in 3D, and a Retry would place the same ones. Add photos: take them a '
          'step apart, each one seeing most of what the previous one saw, and avoid plain walls, windows and mirrors.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      inRow(
        'conversion-14',
        find.text(
          'The prepared images and the work files are kept until the next scene or for 24 h, for a diagnosis: $kept',
        ),
      ),
      findsOneWidget,
    );
    for (final id in ['conversion-14', 'conversion-15', 'conversion-16']) {
      expect(inRow(id, find.byKey(const Key('ai_job_retry'))), findsNothing, reason: id);
    }
  });

  testWidgets('an object with nothing found under it: said that it may lie tilted; nothing for an object set upright, '
      'nor for a place (lot SPF2)', (tester) async {
    SplatResultDetails details(SplatSubject subject, SplatUpright upright) => SplatResultDetails(
      gaussians: 129325,
      images: 139,
      placed: 129,
      subject: subject,
      scale: 0.53,
      fromVideo: true,
      upright: upright,
    );
    await pumpPanel(tester, [
      _splat('conversion-17', fromVideo: true, details: details(SplatSubject.object, SplatUpright.imageOrientation)),
      _splat('conversion-18', fromVideo: true, details: details(SplatSubject.object, SplatUpright.supportPlane)),
      _splat('conversion-19', fromVideo: true, details: details(SplatSubject.place, SplatUpright.imageOrientation)),
    ]);

    expect(
      inRow(
        'conversion-17',
        find.text('No surface was found under the object: it is set upright as the images had it, and may lie tilted.'),
      ),
      findsOneWidget,
    );
    expect(inRow('conversion-18', find.byKey(const Key('ai_job_splat_upright'))), findsNothing);
    expect(inRow('conversion-19', find.byKey(const Key('ai_job_splat_upright'))), findsNothing);
  });

  testWidgets('the frames of a video are matched in blocks, as photos are', (tester) async {
    await pumpPanel(tester, [
      _splat('conversion-14', state: ConversionState.matching, fromVideo: true, step: 4, steps: 16),
    ]);
    expect(
      inRow('conversion-14', find.textContaining('Placing the photos in 3D: matching, block 4 of 16')),
      findsOneWidget,
    );
  });

  group('the close of the window', () {
    Future<void> pumpClose(WidgetTester tester, List<ConversionJob> jobs) => tester.pumpConsumerWidget(
      const DesktopCloseDialog(reasons: {DesktopCloseReason.conversions, DesktopCloseReason.splat}),
      overrides: [conversionQueueProvider.overrideWith(() => _ShownQueue(ConversionQueueState(jobs: jobs)))],
    );

    test('a splat scene being made is a reason, not one waiting nor one ended', () {
      Set<DesktopCloseReason> reasonsWith(List<ConversionJob> jobs) {
        final container = ProviderContainer(
          overrides: [conversionQueueProvider.overrideWith(() => _ShownQueue(ConversionQueueState(jobs: jobs)))],
        );
        addTearDown(container.dispose);
        container.read(conversionQueueProvider);
        return container.read(desktopCloseReasonsProvider)();
      }

      expect(reasonsWith([_splat('a', state: ConversionState.matching, step: 4, steps: 9)]), {
        DesktopCloseReason.conversions,
        DesktopCloseReason.splat,
      });
      expect(reasonsWith([_splat('a', state: ConversionState.waiting)]), {DesktopCloseReason.conversions});
      expect(reasonsWith([_splat('a')]), isEmpty);
    });

    testWidgets('names the step of the scene: the training with its step and the time left, the matching with its '
        'block', (tester) async {
      await pumpClose(tester, [
        _splat('a', state: ConversionState.training, step: 12400, steps: 20000, remaining: const Duration(minutes: 3)),
      ]);
      expect(
        find.text(
          'A splat scene is being made (Training the splat, step 12,400 of 20,000, about 3 min left). Closing stops it.',
        ),
        findsOneWidget,
      );
      expect(find.text('3D conversions are running: quitting stops them.'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpClose(tester, [_splat('a', state: ConversionState.matching, step: 4, steps: 9)]);
      expect(
        find.text('A splat scene is being made (Placing the photos in 3D: matching, block 4 of 9). Closing stops it.'),
        findsOneWidget,
      );
    });

    testWidgets('beside other conversions, both lines', (tester) async {
      await pumpClose(tester, [
        _splat('a', state: ConversionState.training, step: 12400, steps: 20000),
        ConversionJob(
          id: 'b',
          source: LocalFileSource('/photos/b.jpg'),
          batchIndex: 1,
          batchSize: 1,
          target: ConversionTarget.nextTo('/photos/b.jpg'),
        ),
      ]);
      expect(find.textContaining('A splat scene is being made'), findsOneWidget);
      expect(find.text('3D conversions are running: quitting stops them.'), findsOneWidget);
    });
  });
}
