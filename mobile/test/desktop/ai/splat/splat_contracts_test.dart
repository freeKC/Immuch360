// The contracts of the splat scenes (store/m2/splat-maker-2026-11-01/plan-2026-11-01.md, lot SP0), which the lots of
// the formats, the runners, the inputs, the engine and the screens build on: the kind of file and its name, the steps
// and their states, the failures and the counts they carry, the spec of a job and what it tells at the end, the kind
// of the queue on the lane of the graphics card whose engine tells the whole time left, the memory it holds, the
// feature and its group held back with entries that have no sums yet, the settings, and the words of the panel.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/components_tile.dart';

import '../creator/english_texts.dart';
import '../fakes/fake_gpu_probe.dart';

const _gib = 1024 * 1024 * 1024;
const _lead = ImmersiveSource(name: 'DSCF4667.JPG', size: 4182311, sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=', path: '/p');

class _Member implements SplatMember {
  _Member(this.name);

  @override
  final String name;

  @override
  DateTime? get taken => null;

  @override
  String? get camera => null;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) async => _lead;

  @override
  Future<void> release() async {}
}

SplatJob _job({bool video = false, SplatSettings settings = const SplatSettings(), int members = 3}) => SplatJob(
  id: 'splat-1',
  lead: _lead,
  members: [for (var k = 0; k < (video ? 1 : members); k++) _Member('DSCF${4667 + k}.JPG')],
  isVideo: video,
  settings: settings,
  partPath: '/out/.salon_splat.spz.1-1.immuch360.part',
  derivativeId: 'urn:uuid:1',
  creatorTool: 'Immuch360 Desktop 3.3.0',
  created: '2026-11-01T15:00:00+01:00',
);

/// Every component installed, the gate asking nothing of ONNX Runtime
class _Installed implements AiComponentFiles {
  @override
  Future<File?> verifiedFile(AiComponent component) async => File('/components/${component.installPath}');

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.installed;
}

void main() {
  group('the kind of file', () {
    test('a splat scene is GaussianSplat, written as <name>_splat.spz, not a version of one photo', () {
      expect(ImmersiveKind.gaussianSplat.xmp, 'GaussianSplat');
      expect(ImmersiveKind.fromXmp('GaussianSplat'), ImmersiveKind.gaussianSplat);
      expect(derivedNameEnd(ImmersiveKind.gaussianSplat, 'salon'), '_splat.spz');
      expect(derivedFileNameFor(ImmersiveKind.gaussianSplat, 'salon'), 'salon_splat.spz');
      expect('salon$splatNameSuffix$splatPlyExtension', 'salon_splat.ply');
      expect(derivedNameSuffixes, isNot(contains(splatNameSuffix)));
      expect(qualityFlagsOf(ImmersiveKind.gaussianSplat), isEmpty);
    });

    test('the name chosen in the dialog is kept whole: its dots, spaces and accents are no extension', () {
      // The dialog proposes the name of the folder of the photos, and dated folders often hold dots (review of SP0)
      const names = {
        'salon': 'salon_splat',
        'St. Paul': 'St. Paul_splat',
        '2024.08 Lyon': '2024.08 Lyon_splat',
        'Room 2.5': 'Room 2.5_splat',
        'Visite 1.1': 'Visite 1.1_splat',
        "Salon d'été": "Salon d'été_splat",
        'Łódź, rynek': 'Łódź, rynek_splat',
      };
      for (final MapEntry(key: name, value: stem) in names.entries) {
        expect(splatFileNameFor(name), '$stem.spz', reason: name);
        expect(splatFileNameFor(name, ply: true), '$stem.ply', reason: name);
        expect(derivedFileNameFor(ImmersiveKind.gaussianSplat, name), '$stem.spz', reason: name);
        // The name made safe for Windows keeps it whole too
        expect(versionTargetName(ImmersiveKind.gaussianSplat, name), '$stem.spz', reason: name);
      }
      expect(splatFileNameFor('Visite 1.1'), isNot(splatFileNameFor('Visite 1.2')));
      // The other kinds still take the name of a photo without its extension
      expect(derivedFileNameFor(ImmersiveKind.volumetricScene, 'St. Paul.jpg'), 'St. Paul_scene3D.jpg');
    });

    test('splat-v1 holds the choices of the plan', () {
      expect(SplatV1.pipeline, 'splat-v1');
      expect((SplatV1.minImages, SplatV1.fewImages, SplatV1.maxPhotos), (20, 50, 200));
      expect((SplatV1.minVideo, SplatV1.maxVideo), (const Duration(seconds: 10), const Duration(minutes: 5)));
      expect((SplatV1.videoFrames, SplatV1.maxVideoFrames), (150, 250));
      expect((SplatV1.photoLongSide, SplatV1.photoQuality, SplatV1.siftMaxImageSize), (1600, 95, 1024));
      expect((SplatV1.steps, SplatV1.maxGaussians, SplatV1.shDegree), (20000, 150000, 3));
      expect(SplatV1.trainingResolution, 1024, reason: 'set by the measure M1: 0.20 dB from 1 280 px, 34 % faster');
      expect((SplatV1.minPlacedShare, SplatV1.minPlaced, SplatV1.partialShare), (0.5, 20, 0.9));
      expect(
        (SplatV1.colmapSilence, SplatV1.brushSilence),
        (const Duration(seconds: 600), const Duration(seconds: 300)),
      );
      expect((SplatV1.objectSize, SplatV1.placeCameraHeight, SplatV1.placeMinSize), (1.0, 1.5, 3.0));
      expect((SplatV1.spzVersion, SplatV1.spzFractionalBits), (2, 12));
      // A card sold with 4 GB and a computer sold with 8 GB, as they are read (3.9 and 7.8 GiB or so)
      expect(
        (SplatV1.minGraphicsMemory, SplatV1.minPhysicalMemory, SplatV1.jobMemory),
        (3584 * 1024 * 1024, 7 * _gib, 4 * _gib),
      );
      expect(SplatV1.freeGraphicsMemory, 2560 * 1024 * 1024);
      expect(SplatV1.workKept, const Duration(hours: 24));
    });
  });

  group('the steps', () {
    test('the photos or the frames, COLMAP, Brush, the copy for the headset, each with its phase', () {
      expect(ImmersiveStage.of(ImmersiveKind.gaussianSplat), ImmersiveStage.splat);
      expect(ImmersiveStage.splat, [
        ImmersiveStage.reading,
        ImmersiveStage.photos,
        ImmersiveStage.frames,
        ImmersiveStage.features,
        ImmersiveStage.matching,
        ImmersiveStage.mapping,
        ImmersiveStage.training,
        ImmersiveStage.splatCopy,
        ImmersiveStage.writing,
      ]);
      expect(
        [for (final stage in ImmersiveStage.splat) stage.phase],
        [
          ImmersivePhase.preparing,
          ImmersivePhase.preparing,
          ImmersivePhase.preparing,
          ImmersivePhase.computing,
          ImmersivePhase.computing,
          ImmersivePhase.computing,
          ImmersivePhase.computing,
          ImmersivePhase.finishing,
          ImmersivePhase.finishing,
        ],
      );
    });

    test('a job of photos skips the frames, a job of a video skips the photos', () {
      expect(_job().stages, isNot(contains(ImmersiveStage.frames)));
      expect(_job().stages, contains(ImmersiveStage.photos));
      expect(_job(video: true).stages, isNot(contains(ImmersiveStage.photos)));
      expect(_job(video: true).stages, contains(ImmersiveStage.frames));
      expect(_job().stages.length, ImmersiveStage.splat.length - 1);
    });

    test('each has its state in the queue, before encoding, so that the other kinds keep their order', () {
      for (final stage in ImmersiveStage.splat) {
        expect(ConversionState.of(stage).name, stage.name);
      }
      expect(ConversionState.splatCopy.index, lessThan(ConversionState.encoding.index));
      expect(ConversionState.photos.index, greaterThan(ConversionState.rightEye.index));
      expect(ConversionState.training.phase, ConversionPhase.computing);
      expect(ConversionState.splatCopy.phase, ConversionPhase.finishing);
    });
  });

  group('the failures', () {
    test('the codes of placing the photos and of the training', () {
      expect(
        ImmersiveErrorCode.values.map((code) => code.name),
        containsAll([
          'tooFewImages',
          'posesFailed',
          'posesStalled',
          'notEnoughOverlap',
          'trainingFailed',
          'trainingStalled',
        ]),
      );
    });

    test('the counts a failure carries as its message', () {
      expect(splatCountsMessage(12, 150), '12/150');
      expect(splatCountsOf('12/150'), (12, 150));
      expect(splatCountsOf(splatCountsMessage(0, 24)), (0, 24));
      for (final message in [null, '', 'COLMAP crashed', '12 / 150', '-1/3', '12/150/1']) {
        expect(splatCountsOf(message), isNull, reason: '$message');
      }
    });
  });

  group('the spec of a job', () {
    test('the lead is its original, the members are read one by one, the settings are those of splat-v1', () {
      final job = _job();

      expect(job.kind, ImmersiveKind.gaussianSplat);
      expect(job.sources, [_lead]);
      expect(job.original, _lead);
      expect(job.members.map((member) => member.name), ['DSCF4667.JPG', 'DSCF4668.JPG', 'DSCF4669.JPG']);
      expect(job.plyPartPath, isNull);
      expect(job.quarterTurns, 0);
      const settings = SplatSettings();
      expect(settings.subject, SplatSubject.place);
      expect(
        (settings.steps, settings.maxGaussians, settings.shDegree, settings.trainingResolution),
        (SplatV1.steps, SplatV1.maxGaussians, SplatV1.shDegree, SplatV1.trainingResolution),
      );
      expect(settings.siftMaxImageSize, SplatV1.siftMaxImageSize);
      expect(settings.keepPly, isFalse);
    });

    test('the key of its settings tells two scenes apart, the copy for other apps aside', () {
      const object = SplatSettings(subject: SplatSubject.object);

      expect(const SplatSettings().key, 'splat-v1;place;20000;150000;3;1024;1024');
      expect(object.key, isNot(const SplatSettings().key));
      expect(const SplatSettings(keepPly: true).key, const SplatSettings().key);
      expect(const SplatSettings(keepPly: true), isNot(const SplatSettings()));
      expect(object, const SplatSettings(subject: SplatSubject.object));
      expect(object.hashCode, const SplatSettings(subject: SplatSubject.object).hashCode);
    });

    test('its result: the gaussians, the images placed, the images left out, the .ply', () {
      const details = SplatResultDetails(
        gaussians: 150000,
        images: 150,
        placed: 126,
        subject: SplatSubject.place,
        scale: 0.42,
        plyBytes: 35401551,
      );
      const result = ImmersiveResult.made(details: details, bytesWritten: 3612448);

      expect(result.isDone, isTrue);
      expect(result.details, same(details));
      expect(details.leftOut, 24);
      expect(details.isPartial, isTrue, reason: '126 of 150 is under 90 %');
      expect(
        const SplatResultDetails(
          gaussians: 1,
          images: 150,
          placed: 135,
          subject: SplatSubject.object,
          scale: 1,
        ).isPartial,
        isFalse,
      );
      expect(details.fromVideo, isFalse);
      expect(details.blurred, 0);
      expect(details.shDegree, 3);
    });
  });

  group('the kind of the queue', () {
    test('a splat scene runs on the lane of the graphics card and its engine tells the whole time left', () {
      expect(ConversionKind.splatScene.output, ImmersiveKind.gaussianSplat);
      expect(ConversionKind.splatScene.lane, ConversionLane.gpu);
      expect(ConversionKind.splatScene.stages, ImmersiveStage.splat);
      expect(
        [
          for (final kind in ConversionKind.values)
            if (kind.tellsWholeTimeLeft) kind,
        ],
        [ConversionKind.splatScene],
      );
      expect(
        conversionTimeLeft(
          ConversionKind.splatScene,
          ImmersiveStage.training,
          timings: const AiTimings(),
          inStage: const Duration(minutes: 1),
          stageLeft: const Duration(minutes: 3),
        ),
        const Duration(minutes: 3),
      );
      expect(conversionTimeLeft(ConversionKind.splatScene, ImmersiveStage.mapping, timings: const AiTimings()), isNull);
      // Another kind adds the timings of the steps after it
      expect(
        conversionTimeLeft(
          ConversionKind.panoramaFromPhoto,
          ImmersiveStage.generating,
          timings: const AiTimings(),
          stageLeft: const Duration(minutes: 3),
        ),
        greaterThan(const Duration(minutes: 3)),
      );
    });

    test('the time of the dialog before the first scene: some 13 minutes for 150 photos, as the plan estimates', () {
      final expected = ConversionKind.splatScene.expectedDuration(const AiTimings());

      expect(expected, greaterThan(const Duration(minutes: 12)));
      expect(expected, lessThan(const Duration(minutes: 14)));
      // The training of M1 at 1 024 pixels: 366 s on photos of 3:2, some 7.5 min on photos of 4:3 (1 024 x 768, the
      // photos of a phone), 306 s on the video of 1 024 x 576
      expect(aiDefaultTimings['splatScene']!['training'], 450000);
      expect(aiDefaultTimings['splatSceneVideo']!['training'], 306000);
    });

    test('a job of photos is timed by the steps of photos, a job of a video by its own (review of SP0)', () {
      expect(ConversionKind.splatScene.stagesOf(), _job().stages);
      expect(ConversionKind.splatScene.stagesOf(fromVideo: true), _job(video: true).stages);
      expect(ConversionKind.sceneFromPhoto.stagesOf(fromVideo: true), ConversionKind.sceneFromPhoto.stages);
      expect(ConversionKind.splatScene.timingsKey(), 'splatScene');
      expect(ConversionKind.splatScene.timingsKey(fromVideo: true), 'splatSceneVideo');
      expect(ConversionKind.panoramaFromPhoto.timingsKey(fromVideo: true), 'panoramaFromPhoto');

      // Some 8.5 minutes for a video of two minutes: the frames, the sequential matching (81 s) and the mapping (30 s)
      // of the measure, the training of M1 (306 s)
      final video = ConversionKind.splatScene.expectedDuration(const AiTimings(), fromVideo: true);
      expect(video, greaterThan(const Duration(minutes: 8)));
      expect(video, lessThan(const Duration(minutes: 9)));
      // What a video took never weighs on the time of photos, nor the other way around
      const slowVideo = AiTimings({
        'splatSceneVideo': {'frames': 3600000, 'matching': 3600000},
      });
      expect(
        ConversionKind.splatScene.expectedDuration(slowVideo),
        ConversionKind.splatScene.expectedDuration(const AiTimings()),
      );
      const slowPhotos = AiTimings({
        'splatScene': {'photos': 3600000, 'matching': 3600000},
      });
      expect(ConversionKind.splatScene.expectedDuration(slowPhotos, fromVideo: true), video);
    });

    test('it holds 4 GiB of memory until the points of the images are found', () {
      expect(jobMemoryNeedOf(ImmersiveKind.gaussianSplat), 4 * _gib);
      expect(memoryPeakOf(ImmersiveKind.gaussianSplat), ImmersiveStage.features);
      expect(jobMemoryStillNeeded(ImmersiveKind.gaussianSplat, ImmersiveStage.photos), 4 * _gib);
      expect(jobMemoryStillNeeded(ImmersiveKind.gaussianSplat, ImmersiveStage.training), 0);
    });

    test('it is not a type of "Make 3D (AI)": a button of its own, never offered on one photo yet', () {
      expect(conversionDialogKinds, isNot(contains(ConversionKind.splatScene)));
      expect(aiFeatureOf(ConversionKind.splatScene), AiFeature.splatScene);
    });
  });

  group('the feature and its components', () {
    test('Windows only, a group of its own, lifted on the branch of the test build only', () {
      expect(AiFeature.splatScene.platforms, [AiPlatform.windowsX64]);
      expect(AiFeatureGroup.splats.features, {AiFeature.splatScene});
      // feat-splat-maker (lot SP8) lifts the hold that every other branch keeps until ai-components-4 is published
      expect(aiHeldFeatureGroups, isEmpty);
      expect(aiComponentsSplatsReleaseTag, 'ai-components-4');
      expect(aiComponentGroupsFor(AiPlatform.windowsX64).map((group) => group.group), contains(AiFeatureGroup.splats));
      expect(
        aiComponentGroupsFor(AiPlatform.linuxX64).map((group) => group.group),
        isNot(contains(AiFeatureGroup.splats)),
      );
      expect(
        aiComponentGroupsFor(AiPlatform.windowsX64, held: const {AiFeatureGroup.splats}).map((group) => group.group),
        isNot(contains(AiFeatureGroup.splats)),
      );
    });

    test('COLMAP and Brush, archives of our CI: the Windows ones as the runs 41338110566 and 41338726969 made them, '
        'the Linux ones not made yet', () {
      expect(aiComponentsFor(AiPlatform.windowsX64, feature: AiFeature.splatScene), [
        colmapWindowsComponent,
        brushWindowsComponent,
      ]);
      expect(aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.splatScene), isEmpty);
      expect(aiComponentsFor(AiPlatform.macosArm64, feature: AiFeature.splatScene), isEmpty);
      final splats = [colmapWindowsComponent, colmapLinuxComponent, brushWindowsComponent, brushLinuxComponent];
      expect(splats.map((component) => component.id), [
        'colmap-cpu-win-x64',
        'colmap-cpu-linux-x64',
        'brush-vulkan-win-x64',
        'brush-vulkan-linux-x64',
      ]);
      for (final component in splats) {
        expect(aiComponents, contains(component));
        expect(component.kind, AiComponentKind.archive, reason: component.id);
        expect(component.releaseTag, 'ai-components-4', reason: component.id);
        expect(component.features, {AiFeature.splatScene}, reason: component.id);
        expect(component.officialUrls, isEmpty, reason: 'our builds only: ${component.id}');
        expect(component.installPath, 'engines/${component.id}');
        expect(component.assetName, '${component.id}.zip');
      }
      // Served by the local mirror of the test build, the archives of the CI as they are
      expect(
        (colmapWindowsComponent.size, colmapWindowsComponent.sha256),
        (10090414, '775fae804f4f4ae4cf3b26045e770a07527f0ff0dc046f5a093fa25ce7fb4e2e'),
      );
      expect(
        (brushWindowsComponent.size, brushWindowsComponent.sha256),
        (16354351, '875e9308a3ea827cccb412dadf1bb1606ee15abb2d3b41029f522ccff7367202'),
      );
      expect(colmapWindowsComponent.archiveFiles, hasLength(123));
      expect(brushWindowsComponent.archiveFiles, hasLength(8));
      expect(colmapWindowsComponent.installedSize, 27697172);
      expect(brushWindowsComponent.installedSize, 64393915);
      // The program each engine runs, and the licences that travel with it
      expect(colmapWindowsComponent.mainPath, 'engines/colmap-cpu-win-x64/colmap.exe');
      expect(brushWindowsComponent.mainPath, 'engines/brush-vulkan-win-x64/brush_app.exe');
      List<String> paths(AiComponent component) => [for (final file in component.archiveFiles) file.path];
      expect(
        paths(colmapWindowsComponent),
        containsAll(['licenses/COPYING.txt', 'licenses/THIRD-PARTY.md', 'licenses/README.md', 'BUILD-INFO.txt']),
      );
      expect(paths(colmapWindowsComponent).where((path) => path.startsWith('licenses/')), hasLength(115));
      expect(
        paths(brushWindowsComponent),
        containsAll([
          'licenses/brush-LICENSE.txt',
          'licenses/THIRD-PARTY.md',
          'licenses/EXTRA-NOTICES.md',
          'licenses/patches/0001-immuch360-headless-trainer.patch',
          'BUILD-INFO.txt',
        ]),
      );
      for (final component in [colmapWindowsComponent, brushWindowsComponent]) {
        expect(component.isComplete, isTrue, reason: component.id);
        expect(
          [
            for (final file in component.archiveFiles)
              if (file.executable) file.path,
          ],
          [component == colmapWindowsComponent ? 'colmap.exe' : 'brush_app.exe'],
        );
        expect(component.archiveFiles.every((file) => RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256)), isTrue);
      }
      for (final component in [colmapLinuxComponent, brushLinuxComponent]) {
        expect((component.size, component.sha256), (null, null), reason: component.id);
        expect(component.archiveFiles, isEmpty, reason: component.id);
        expect(component.isComplete, isFalse, reason: component.id);
      }
      expect({for (final component in splats) component.licence}, {'BSD-3-Clause', 'Apache-2.0'});
      expect(colmapWindowsComponent.version, '4.2.1-imm1');
      expect(brushWindowsComponent.version, '0.3.0-imm1');
      expect(colmapWindowsComponent.licenceUrl, 'https://github.com/colmap/colmap/blob/4.2.1/COPYING.txt');
      expect(brushWindowsComponent.licenceUrl, 'https://github.com/ArthurBrussee/brush/blob/v0.3.0/LICENSE');
      expect(brushWindowsComponent.minGraphicsMemory, SplatV1.minGraphicsMemory);
      expect(colmapWindowsComponent.minGraphicsMemory, isNull, reason: 'COLMAP runs on the processor');
    });

    test('their licences: the BSD 3 text of COLMAP with its copyright line, the Apache License 2.0 of Brush', () {
      // The plan (2.4, the components) asks for the text of COLMAP in the app, as Real-ESRGAN has its own; COPYING.txt
      // of 4.2.1, 1 909 bytes, SHA-256 ab30dabb... in DOWNLOADS.txt of the measure
      for (final colmap in [colmapWindowsComponent, colmapLinuxComponent]) {
        expect(aiLicenceText(colmap), colmapLicence, reason: colmap.id);
      }
      expect(colmapLicence, startsWith('The COLMAP library is licensed under the new BSD license.'));
      expect(colmapLicence, contains('    Copyright (c), ETH Zurich and UNC Chapel Hill.\n    All rights reserved.\n'));
      expect(colmapLicence, contains('Neither the name of ETH Zurich and UNC Chapel Hill nor the names of'));
      expect(colmapLicence.length, 1909);
      for (final brush in [brushWindowsComponent, brushLinuxComponent]) {
        expect(aiLicenceText(brush), apacheLicence2, reason: brush.id);
      }
      // The engine of the panoramas (MIT) still names its licence and where to read it
      expect(aiLicenceText(sdCppWindowsComponent), 'See ${sdCppWindowsComponent.licenceUrl}\n');
      expect(
        aiComponentLicenceNotice(colmapWindowsComponent, source: 'mirror', installedAt: DateTime.utc(2026, 11, 1)),
        contains('Licence: BSD-3-Clause, https://github.com/colmap/colmap/blob/4.2.1/COPYING.txt'),
      );
    });

    test('the gate offers the feature on Windows on this branch, refuses it while a version holds it back, and on '
        'the other systems', () async {
      HardwareGate gate(Abi abi, {Set<AiFeatureGroup> held = aiHeldFeatureGroups}) => HardwareGate(
        components: _Installed(),
        facts: () => AiHardwareFacts(abi: abi, processors: 32, physicalMemory: 16 * _gib),
        loadRuntime: (path) async => (version: '1.31.0', error: null),
        heldGroups: held,
        gpu: FakeGpuProbe.of(FakeGpuReports.rtx4060),
      );
      final windows = await gate(Abi.windowsX64).evaluate(feature: AiFeature.splatScene);
      expect(windows.isAvailable, isTrue, reason: '$windows');
      expect(windows.fileOf(colmapWindowsComponent.id), isNotNull);
      expect(windows.fileOf(brushWindowsComponent.id), isNotNull);
      expect(
        (await gate(
          Abi.windowsX64,
          held: const {AiFeatureGroup.splats},
        ).evaluate(feature: AiFeature.splatScene)).reason,
        AiGateReason.notInThisVersion,
      );
      for (final abi in [Abi.linuxX64, Abi.macosArm64, Abi.macosX64]) {
        expect((await gate(abi).evaluate(feature: AiFeature.splatScene)).reason, AiGateReason.notHere, reason: '$abi');
      }
      // The 3D photo is not touched by the hold
      expect((await gate(Abi.windowsX64, held: const {AiFeatureGroup.splats}).evaluate()).isAvailable, isTrue);
    });
  });

  group('the settings', () {
    test('"Splat scenes (experimental)" on by default, a place, no .ply', () {
      const settings = DesktopAiSettings();

      expect(settings.splatScenes, isTrue);
      expect(settings.splatSubject, SplatSubject.place);
      expect(settings.splatKeepPly, isFalse);
      expect(DesktopAiSettings.fromJson(const {}), settings);
    });

    test('kept in desktop_ai.json, an unknown value read as its default', () {
      final changed = const DesktopAiSettings().copyWith(
        splatScenes: false,
        splatSubject: SplatSubject.object,
        splatKeepPly: true,
      );
      final json = changed.toJson();

      expect((json['splatScenes'], json['splatSubject'], json['splatKeepPly']), (false, 'object', true));
      expect(DesktopAiSettings.fromJson(json), changed);
      expect(changed, isNot(const DesktopAiSettings()));
      expect(
        DesktopAiSettings.fromJson(const {'splatScenes': 'no', 'splatSubject': 'animal', 'splatKeepPly': 1}),
        const DesktopAiSettings(),
      );
    });
  });

  group('the words', () {
    setUpAll(loadEnglishTexts);
    final t = StaticTranslations.instance;

    test('of the kind, its honesty, its group', () {
      expect(conversionKindText(t, ConversionKind.splatScene), 'Photos to splat scene');
      expect(conversionKindText(t, ConversionKind.splatScene, fromVideo: true), 'Video to splat scene');
      expect(conversionKindText(t, ConversionKind.sbsFromPhoto, fromVideo: true), '2D to 3D SBS');
      expect(conversionKindName(t, ConversionKind.splatScene), 'Splat scene');
      expect(
        conversionKindLabel(t, ConversionKind.splatScene),
        'Rebuilt from your photos: places no photo saw stay empty or blurred',
      );
      expect(conversionKindHonesty(t, ConversionKind.splatScene), conversionKindLabel(t, ConversionKind.splatScene));
      expect(aiFeatureGroupName(t, AiFeatureGroup.splats), 'Splat scenes');
      expect(t.ai_immersive_components_splats(size: '183 MB'), 'Splat scenes: 183 MB');
      expect(t.ai_immersive_splat_make, 'Make a splat scene (AI)');
      expect(t.ai_immersive_splat_setting, 'Splat scenes (experimental)');
    });

    test('of each failure, with the counts it carries', () {
      String text(ImmersiveErrorCode code, [String? message]) => conversionFailureText(t, code, message);

      expect(
        text(ImmersiveErrorCode.tooFewImages, '12/150'),
        'Only 12 of 150 images can be used: a splat scene needs at least 20',
      );
      expect(
        text(ImmersiveErrorCode.tooFewImages),
        'A splat scene needs at least 20 photos of the same place, taken from different spots; 50 to 200 is best.',
      );
      expect(
        text(ImmersiveErrorCode.notEnoughOverlap, '12/150'),
        startsWith('Only 12 of 150 images could be placed in 3D.'),
      );
      for (final message in ['0/150', null, 'garbage']) {
        expect(
          text(ImmersiveErrorCode.notEnoughOverlap, message),
          'No two photos could be matched: they do not show the same place clearly enough.',
          reason: '$message',
        );
      }
      expect(text(ImmersiveErrorCode.posesFailed, 'Check failed'), 'Placing the photos in 3D stopped: Check failed');
      expect(text(ImmersiveErrorCode.posesStalled), 'Placing the photos stopped responding');
      expect(text(ImmersiveErrorCode.trainingFailed, 'panicked'), 'The splat training stopped: panicked');
      expect(text(ImmersiveErrorCode.trainingStalled), 'The splat training stopped responding');
      // COLMAP out of memory: the words of a splat scene, not those of a photo (review of SP0)
      expect(
        conversionFailureText(t, ImmersiveErrorCode.outOfMemory, null, kind: ConversionKind.splatScene),
        'Not enough memory to place the photos: close other apps and retry, or use fewer photos.',
      );
      expect(
        conversionFailureText(t, ImmersiveErrorCode.outOfMemory, null, kind: ConversionKind.sceneFromPhoto),
        conversionFailureText(t, ImmersiveErrorCode.outOfMemory, null),
      );
      expect(text(ImmersiveErrorCode.outOfMemory), isNot(t.ai_immersive_failed_splat_memory));
    });

    test('of each step, its counts in its words, the steps of the training in the progress', () {
      ConversionJob job(ConversionState state, {int? step, int? steps, bool video = false}) => ConversionJob(
        id: 'j',
        source: LocalFileSource('/photos/salon/DSCF4667.JPG'),
        batchIndex: 1,
        batchSize: 1,
        kind: ConversionKind.splatScene,
        fromVideo: video,
        state: state,
        step: step,
        steps: steps,
      );

      expect(
        conversionStageText(t, job(ConversionState.photos, step: 42, steps: 150)),
        'Preparing the photos: 42 of 150',
      );
      expect(conversionStageText(t, job(ConversionState.photos)), isNull);
      expect(conversionStageText(t, job(ConversionState.frames, step: 61, steps: 150)), 'Taking the frames: 61 of 150');
      expect(
        conversionStageText(t, job(ConversionState.features, step: 87, steps: 150)),
        'Placing the photos in 3D: finding features, 87 of 150',
      );
      // The photos are matched in blocks (exhaustive_matcher), the frames of a video one after the other
      expect(
        conversionStageText(t, job(ConversionState.matching, step: 4, steps: 9)),
        'Placing the photos in 3D: matching, block 4 of 9',
      );
      expect(
        conversionStageText(t, job(ConversionState.matching, step: 61, steps: 150, video: true)),
        'Placing the photos in 3D: matching, 61 of 150',
      );
      // A job knows it is made from a video, whatever happens to it
      final video = job(ConversionState.waiting, video: true);
      expect(video.copyWith(state: ConversionState.matching, step: () => 1).fromVideo, isTrue);
      expect(job(ConversionState.waiting).fromVideo, isFalse);
      expect(
        conversionStageText(t, job(ConversionState.mapping, step: 120, steps: 150)),
        'Placing the photos in 3D: rebuilding, 120 of 150 placed',
      );
      for (final state in [ConversionState.features, ConversionState.matching, ConversionState.mapping]) {
        expect(conversionStageText(t, job(state)), 'Placing the photos in 3D', reason: '$state');
      }
      expect(conversionStageText(t, job(ConversionState.training, step: 12400, steps: 20000)), 'Training the splat');
      expect(conversionStageText(t, job(ConversionState.splatCopy)), 'Writing the headset copy');
      // The steps of the training in the progress, the images of COLMAP not counted twice
      const left = Duration(minutes: 3);
      expect(
        conversionProgressText(t, job(ConversionState.training, step: 12400, steps: 20000), left),
        'step 12,400 of 20,000, about 3 min left',
      );
      expect(conversionProgressText(t, job(ConversionState.features, step: 87, steps: 150), left), 'About 3 min left');
    });
  });
}
