// The quality of a splat scene (lot Q1, quality-measure-2026-11-05.md): the settings of each of the three lines, the
// key of their work folders, the arguments Brush gets, the size the images are prepared at, the memory model that sets
// the definition of Maximum on synthetic computers and sources, the time and the size each line tells.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_quality.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_time.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';
import 'package:immich_mobile/desktop/ai/ui/splat_plan.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

const _gib = 1024 * 1024 * 1024;

/// [count] frames of a video of [width] x [height]
List<SplatImageSize> _frames(int count, int width, int height) => List.filled(count, (width: width, height: height));

/// A photo or a video of the library of [width] x [height]
SplatCandidate _candidate(String name, int? width, int? height, {bool video = false}) => SplatCandidate(
  asset: LocalAsset(
    id: 'id-$name',
    name: name,
    type: video ? AssetType.video : AssetType.image,
    createdAt: DateTime(2026, 11, 5, 9),
    updatedAt: DateTime(2026, 11, 5, 9),
    width: width,
    height: height,
    durationMs: video ? 60000 : null,
    playbackStyle: video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
    isEdited: false,
  ),
);

/// The value after [flag] in [arguments]
String _after(List<String> arguments, String flag) => arguments[arguments.indexOf(flag) + 1];

void main() {
  group('the settings of each quality', () {
    test('Headset is splat-v1 as it was, and the default', () {
      final headset = SplatSettings.of(SplatQuality.headset);
      expect(headset, const SplatSettings());
      expect(
        (headset.steps, headset.maxGaussians, headset.trainingResolution, headset.photoLongSide, headset.quality),
        (20000, 150000, 1024, 1600, SplatQuality.headset),
      );
      expect(headset.headsetGaussians, 150000);
      expect(SplatQuality.headset.hasHeadsetCopy, isFalse);
      expect(const SplatSelection(members: []).settings.quality, SplatQuality.headset);
    });

    test('Detailed: 30 000 steps, a million at most, images prepared and trained at 1 920 pixels', () {
      final detailed = SplatSettings.of(SplatQuality.detailed, subject: SplatSubject.object, keepPly: true);
      expect(
        (detailed.steps, detailed.maxGaussians, detailed.trainingResolution, detailed.photoLongSide),
        (30000, 1000000, 1920, 1920),
      );
      expect((detailed.subject, detailed.keepPly, detailed.headsetGaussians), (SplatSubject.object, true, 150000));
      expect(SplatQuality.detailed.hasHeadsetCopy, isTrue);
    });

    test('Maximum: Detailed at the definition the memory gave, with the ceiling of Brush; 1 920 when none', () {
      final maximum = SplatSettings.of(SplatQuality.maximum, maximumResolution: 3200);
      expect(
        (maximum.steps, maximum.maxGaussians, maximum.trainingResolution, maximum.photoLongSide),
        (30000, 10000000, 3200, 3200),
      );
      final none = SplatSettings.of(SplatQuality.maximum);
      expect((none.trainingResolution, none.photoLongSide), (1920, 1920));
      // Never under the definition of Detailed
      expect(SplatSettings.of(SplatQuality.maximum, maximumResolution: 1200).photoLongSide, 1920);
    });

    test('the key of the work folder holds the quality and the size of the images prepared', () {
      final keys = {for (final quality in SplatQuality.values) SplatSettings.of(quality).key};
      expect(keys, hasLength(3));
      expect(SplatSettings.of(SplatQuality.detailed).key, contains(';detailed;1920'));
      expect(const SplatSettings().key, endsWith(';headset;1600'));
      expect(
        SplatSettings.of(SplatQuality.maximum, maximumResolution: 2560).key,
        isNot(SplatSettings.of(SplatQuality.maximum, maximumResolution: 3200).key),
      );
      // The .ply and the cap of the copy for the headset change no training: the same folder
      expect(
        SplatSettings.of(SplatQuality.detailed, keepPly: true).key,
        const SplatSettings(
          quality: SplatQuality.detailed,
          steps: 30000,
          maxGaussians: 1000000,
          trainingResolution: 1920,
          photoLongSide: 1920,
          headsetGaussians: 1000,
        ).key,
      );
    });

    test('the arguments Brush gets for each quality', () {
      List<String> arguments(SplatSettings settings) => brushArguments(
        dataset: 'D:/work/dataset',
        export: 'D:/work/brush',
        steps: settings.steps,
        maxGaussians: settings.maxGaussians,
        shDegree: settings.shDegree,
        resolution: settings.trainingResolution,
      );
      final headset = arguments(SplatSettings.of(SplatQuality.headset));
      expect(
        [
          for (final flag in ['--total-steps', '--max-splats', '--sh-degree', '--max-resolution'])
            _after(headset, flag),
        ],
        ['20000', '150000', '3', '1024'],
      );
      final detailed = arguments(SplatSettings.of(SplatQuality.detailed));
      expect(
        [
          for (final flag in ['--total-steps', '--max-splats', '--max-resolution', '--export-every'])
            _after(detailed, flag),
        ],
        ['30000', '1000000', '1920', '30000'],
      );
      final maximum = arguments(SplatSettings.of(SplatQuality.maximum, maximumResolution: 3840));
      expect(
        [
          for (final flag in ['--total-steps', '--max-splats', '--max-resolution']) _after(maximum, flag),
        ],
        ['30000', '10000000', '3840'],
      );
    });
  });

  group('the memory model of Maximum', () {
    test('the model of the measure: 1.3 GB, 5 bytes a pixel loaded, 2.2 KB a gaussian', () {
      // The place in 8K of the measure, its 125 frames prepared at 1 920 x 1 080 and 754 752 gaussians: 4.39 GB measured
      final place = splatBrushMemory(_frames(125, 1920, 1080), 1920, gaussians: 754752);
      expect(place / 1e9, closeTo(4.39, 0.2));
      // The room of M1, 150 photos of 1 557 x 1 038 never enlarged, 842 964 gaussians: 4.41 GB
      expect(splatBrushMemory(_frames(150, 1557, 1038), 3840, gaussians: 842964) / 1e9, closeTo(4.41, 0.2));
      // 125 frames of 4K and 800 000 gaussians: some 8.2 GB, as the measure says
      expect(splatBrushMemory(_frames(125, 3840, 2160), 3840, gaussians: 800000) / 1e9, closeTo(8.2, 0.3));
      // Frames reduced to the definition: 8K frames at 1 920 count as 1 920 x 1 080
      expect(splatBrushMemory(_frames(10, 7680, 4320), 1920), splatBrushMemory(_frames(10, 1920, 1080), 1920));
      expect(splatBrushCardMemory() / 1e9, closeTo(3.26, 0.05));
    });

    test('a video of 1080p, or photos no larger: the same as Detailed, whatever the memory', () {
      expect(
        splatMaximumResolution(images: _frames(150, 1920, 1080), physical: 64 * _gib, available: 60 * _gib),
        isNull,
      );
      expect(
        splatMaximumResolution(images: _frames(150, 1557, 1038), physical: 64 * _gib, available: 60 * _gib),
        isNull,
      );
    });

    test('an 8K video: its own definition on a computer of 64 GB, what half of 16 GB holds, nothing when short', () {
      final frames = _frames(150, 7680, 4320);
      expect(splatMaximumResolution(images: frames, physical: 64 * _gib, available: 50 * _gib), 7680);

      // A computer of 16 GB that sees 15.6 GiB, 12 GiB free: half of it, 7.8 GiB
      final physical = (15.6 * _gib).round();
      final found = splatMaximumResolution(images: frames, physical: physical, available: 12 * _gib)!;
      expect(found % SplatV1.maximumResolutionStep, 0);
      expect(found, inExclusiveRange(1920, 7680));
      final budget = splatMaximumBudget(physical: physical, available: 12 * _gib)!;
      expect(budget, (physical * 0.5).floor());
      expect(splatBrushMemory(frames, found), lessThanOrEqualTo(budget));
      expect(splatBrushMemory(frames, found + SplatV1.maximumResolutionStep), greaterThan(budget));
      // 9 GiB free: the memory free less 1.5 GiB bounds it, lower
      final lower = splatMaximumResolution(images: frames, physical: physical, available: 9 * _gib)!;
      expect(lower, lessThan(found));
      expect(splatMaximumBudget(physical: physical, available: 9 * _gib), 9 * _gib - SplatV1.colmapMemoryReserve);

      // The same computer with 4 GiB free (the PC of the measure, the VM of WSL holding its share): the memory free
      // less 1.5 GiB holds no more than Detailed
      expect(splatMaximumResolution(images: frames, physical: physical, available: 4 * _gib), isNull);
      expect(splatMaximumBudget(physical: physical, available: 4 * _gib), 4 * _gib - SplatV1.colmapMemoryReserve);
    });

    test('nothing known, or a card too small for a million gaussians: the same as Detailed', () {
      final frames = _frames(150, 3840, 2160);
      expect(splatMaximumResolution(images: frames, physical: null), isNull);
      expect(splatMaximumResolution(images: frames, physical: 64 * _gib, cardMemory: 3 * _gib), isNull);
      expect(splatMaximumResolution(images: frames, physical: 64 * _gib, cardMemory: 8 * _gib), 3840);
      expect(splatMaximumResolution(images: [...frames, (width: 0, height: 0)], physical: 64 * _gib), isNull);
      expect(splatMaximumResolution(images: const [], physical: 64 * _gib), isNull);
      // Photos of several sizes: the largest bounds it
      expect(
        splatMaximumResolution(
          images: [..._frames(100, 4000, 3000), ..._frames(50, 6000, 4000)],
          physical: 128 * _gib,
          available: 120 * _gib,
        ),
        6000,
      );
    });

    test('the sizes of the images of a plan: each photo, or the frames of the video at its size', () {
      expect(splatImageSizesOf(const SplatSelectionPlan()), isEmpty);
      final photos = SplatSelectionPlan(
        used: [_candidate('a.jpg', 4000, 3000), _candidate('b.jpg', 3000, 4000), _candidate('c.jpg', null, null)],
      );
      expect(splatImageSizesOf(photos), [
        (width: 4000, height: 3000),
        (width: 3000, height: 4000),
        (width: 0, height: 0),
      ]);
      // A size the library does not know: Maximum the same as Detailed
      expect(splatMaximumResolution(images: splatImageSizesOf(photos), physical: 64 * _gib), isNull);
      final video = SplatSelectionPlan(
        used: [_candidate('walk.mp4', 7680, 4320, video: true)],
        isVideo: true,
        videoDuration: const Duration(minutes: 1),
      );
      expect(splatImageSizesOf(video), _frames(video.images, 7680, 4320));
      expect(video.images, SplatV1.videoFrames);
    });
  });

  group('what each line tells', () {
    test('the sizes: 150 000 gaussians for Headset, the scene for Detailed and Maximum, 24 bytes each', () {
      expect(splatSpzBytesOf(SplatQuality.headset, SplatSubject.place), 150000 * 24);
      expect(splatSpzBytesOf(SplatQuality.detailed, SplatSubject.place), 850000 * 24);
      expect(splatSpzBytesOf(SplatQuality.maximum, SplatSubject.object), 150000 * 24);
      expect(splatPlyBytesOf(SplatQuality.detailed, SplatSubject.place) / 1e6, closeTo(200, 2));
      expect(splatPlyBytesOf(SplatQuality.headset, SplatSubject.place) / 1e6, closeTo(35.4, 0.1));
      expect(splatHeadsetCopyBytes, 3600000);
    });

    test('the .spz of Headset for an object: the copy cropped to it, about 1.1 MiB; the .ply whole', () {
      expect(splatPlannedGaussiansOf(SplatQuality.headset, SplatSubject.object), 48000);
      expect(splatSpzBytesOf(SplatQuality.headset, SplatSubject.object) / 1e6, inInclusiveRange(1.0, 1.2));
      expect(splatPlannedGaussiansOf(SplatQuality.headset, SplatSubject.place), 150000);
      // Detailed and Maximum: the .spz holds the whole scene, an object too
      expect(splatPlannedGaussiansOf(SplatQuality.detailed, SplatSubject.object), 150000);
      expect(splatPlannedGaussiansOf(SplatQuality.maximum, SplatSubject.place), 850000);
      // The .ply keeps every gaussian of the export, the crop is the copy's only
      expect(splatPlyBytesOf(SplatQuality.headset, SplatSubject.object), 150000 * 236);
      expect(splatPlyBytesOf(SplatQuality.detailed, SplatSubject.object), 150000 * 236);
    });

    test('the training of Detailed five times that of Headset, Maximum by its pixels', () {
      expect(splatTrainingFactorOf(const SplatSettings()), 1.0);
      expect(splatTrainingFactorOf(const SplatSettings(steps: 10000)), 0.5);
      expect(splatTrainingFactorOf(SplatSettings.of(SplatQuality.detailed)), 5.0);
      expect(splatTrainingFactorOf(SplatSettings.of(SplatQuality.maximum)), 5.0);
      expect(splatTrainingFactorOf(SplatSettings.of(SplatQuality.maximum, maximumResolution: 3840)), 20.0);
    });

    test('the training kept: that of Headset and of Detailed (measured factors), never that of Maximum', () {
      expect(splatKeepsTrainingOf(const SplatSettings()), isTrue);
      expect(splatKeepsTrainingOf(SplatSettings.of(SplatQuality.detailed)), isTrue);
      expect(splatKeepsTrainingOf(SplatSettings.of(SplatQuality.maximum)), isFalse);
      expect(splatKeepsTrainingOf(SplatSettings.of(SplatQuality.maximum, maximumResolution: 2816)), isFalse);
      SplatTimeModel modelOf(SplatSettings settings) => SplatTimeModel(
        reference: splatTimingsOf(splatSceneDefaultTimings),
        stages: ImmersiveStage.splatOf(video: false),
        images: 75,
        video: false,
        steps: settings.steps,
        trainingFactor: splatTrainingFactorOf(settings),
        keepsTraining: splatKeepsTrainingOf(settings),
      );

      const took = Duration(minutes: 40);
      expect(modelOf(const SplatSettings()).kept(ImmersiveStage.training, took), took);
      expect(modelOf(SplatSettings.of(SplatQuality.detailed)).kept(ImmersiveStage.training, took), took * (1 / 5));
      // Maximum at 2 816 pixels: divided by 10.75 it would be kept as 3 min 43 s, from a scaling never measured
      final maximum = modelOf(SplatSettings.of(SplatQuality.maximum, maximumResolution: 2816));
      expect(maximum.normalized(ImmersiveStage.training, took).inSeconds, 223);
      expect(maximum.kept(ImmersiveStage.training, took), isNull);
      // Its other steps are kept as for every quality, by the images
      expect(maximum.kept(ImmersiveStage.features, const Duration(seconds: 8)), const Duration(seconds: 16));

      // What the queue keeps after a Maximum scene: the training stays what it was, the rest is merged
      final kept = AiTimings.merged(
        {
          'splatScene': {'training': 450000, 'features': 15000},
        },
        'splatScene',
        {
          for (final stage in [ImmersiveStage.features, ImmersiveStage.training])
            if (maximum.kept(stage, stage == ImmersiveStage.training ? took : const Duration(seconds: 8))
                case final time?)
              stage.name: time.inMilliseconds,
        },
      );
      expect(kept['splatScene'], {'training': 450000, 'features': 15500});
    });

    test('a one minute video: about 12 min for Headset by the defaults, Detailed some 4 times longer', () {
      const timings = AiTimings({}, 24);
      final images = splatVideoFrameCount(const Duration(minutes: 1));
      final headset = splatTimeOf(timings, images: images, video: true);
      final detailed = splatTimeOf(
        timings,
        images: images,
        video: true,
        settings: SplatSettings.of(SplatQuality.detailed),
      );
      expect(headset.total.inMinutes, inInclusiveRange(9, 13));
      expect(detailed.poses, headset.poses, reason: 'the poses are the same at every quality');
      expect(detailed.training, headset.training * 5);
      expect(detailed.total.inMinutes, inInclusiveRange(25, 40));
      // On a computer that measured its own scene, its times
      const measured = AiTimings({
        'splatSceneVideo': {'training': 60000},
      }, 24);
      expect(
        splatTimeOf(measured, images: images, video: true, settings: SplatSettings.of(SplatQuality.detailed)).training,
        const Duration(minutes: 5),
      );
    });
  });
}
