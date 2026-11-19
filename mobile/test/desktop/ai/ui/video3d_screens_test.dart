// The screens of "2D videos to 3D on the computer" (release 49, video3d-plan.md sections 4.2, 4.3 and 4.5), with a fake
// engine of the videos and a fake FFmpeg probe: "Make 3D (AI)" on a flat video in a selection and in the viewer; the
// dialog with its type "3D video (experimental)", what it does, the experimental line, Quality, Strength and Full or
// Half with their defaults, the components with their sizes and licences before the videos can be read, then each
// refusal and each note of the plan with its words, the encoder of the one second test, the first guess, the memory,
// the free space needed (Convert waits for room), the name of the MP4, and Convert handing the job to the queue with
// those settings, kept for the next dialog. The panel: frames, pace, segment and time left while it runs, the photos let
// go first, Pause, Stop (asked first), Resume and Discard once paused, the error and its log, the MP4 made with Open and
// Show in folder, what a paused video waits for (its original or its folder), Cancel all pausing it. A FFmpeg program
// that does not start said in red with Retry. The close guard of a video being made, and the offer at the start to
// resume a video a quit stopped, with the original not found said.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/versions_section.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/video_resume_offer.dart';
import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_jobs.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/window/close_guard.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_strength_choice.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:path/path.dart' as p;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_video_job_engine.dart';
import '../fakes/recording_creator_files.dart';
import 'settle_still.dart';

const _gib = 1 << 30;

LocalAsset _asset(String name, {AssetType type = AssetType.video, int width = 1920, int height = 1080}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: type,
  createdAt: DateTime(2026, 11, 18, 9),
  updatedAt: DateTime(2026, 11, 18, 9),
  width: width,
  height: height,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

/// The ffprobe of the synthetic phone clip of the study (portrait, HEVC 10 bit HLG, variable rate), its video stream
/// changed by [change], with [audio] tracks and [duration] seconds
Map<String, Object?> _phone({
  void Function(Map<String, Object?> video)? change,
  List<String> audio = const ['aac'],
  int subtitles = 0,
  double? duration,
}) {
  final json =
      jsonDecode(File('test/fixtures/video3d/ffprobe_phone_src.json').readAsStringSync()) as Map<String, Object?>;
  final streams = (json['streams']! as List).cast<Map<String, Object?>>();
  change?.call(streams.first);
  for (final (index, codec) in audio.indexed) {
    streams.add({'index': index + 1, 'codec_type': 'audio', 'codec_name': codec, 'channels': 2});
  }
  for (var index = 0; index < subtitles; index++) {
    streams.add({'index': audio.length + index + 1, 'codec_type': 'subtitle', 'codec_name': 'mov_text'});
  }
  if (duration != null) {
    (json['format']! as Map)['duration'] = '$duration';
    streams.first['duration'] = '$duration';
    streams.first['nb_frames'] = '${(duration * 30).round()}';
  }
  return json;
}

VideoDialogFacts _facts(Map<String, Object?> json, String name) {
  final source = VideoSource.fromFfprobe(json);
  final check = checkVideoSource(source, fileName: name);
  return VideoDialogFacts(
    check: check,
    durationSeconds: source?.duration,
    frames: source == null || check.grid == null ? null : source.frameCount,
  );
}

/// The FFmpeg program as the dialog reads it: the facts of each video by its name, the encoder of the test
class _Probe implements VideoDialogProbe {
  final byName = <String, VideoDialogFacts>{};
  VideoEncoder? encoderFound = VideoEncoder.h264VaapiFull;
  final read_ = <String>[];
  final tested = <(int, int)>[];

  @override
  Future<VideoDialogFacts> read(String path) async {
    read_.add(p.basename(path));
    return byName[p.basename(path)] ?? _facts(_phone(), p.basename(path));
  }

  @override
  Future<VideoEncoder?> encoder(int width, int height, VideoRate rate) async {
    tested.add((width, height));
    return encoderFound;
  }
}

class _GateFiles implements AiComponentFiles {
  _GateFiles(this.service, this.folder);

  final FakeAiComponentsService service;
  final String folder;

  @override
  Future<File?> verifiedFile(AiComponent component) async =>
      stateOf(component) == AiComponentState.installed ? File(p.join(folder, component.id)) : null;

  @override
  AiComponentState stateOf(AiComponent component) => service.statusOf(component).state;
}

class _Originals implements ConversionAssetFiles {
  final byName = <String, LibraryOriginal>{};

  @override
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset) async {
    final original = byName[asset.name];
    return original == null ? null : (location: original, source: LocalFileSource(original.path));
  }
}

class _LocalVolumes implements FolderVolumes {
  @override
  FolderVolume? of(String folder) =>
      FolderVolume(volumeKey: 'local', folderKey: 'local:$folder', mountPoint: '/', isNetwork: false);

  @override
  bool isNetworkMount(String folder) => false;
}

class _Memory implements MemoryProbe {
  const _Memory();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 64 << 30, available: 48 << 30);
}

void main() {
  late Directory root;
  late String videos;
  late Directory support;
  late RecordingCreatorFiles files;
  late SafeWriter writer;
  late DesktopAiSettingsStore store;
  late VideoJobsStore jobs;
  late FakeAiComponentsService service;
  late _Originals originals;
  late _Probe probe;
  late FakeVideoJobEngine engine;
  late int memory;
  late int? free;
  late List<String> openedFolders;
  late List<String> viewed;
  late bool flatVideo;
  late FakeImmersiveEngine photos;

  /// The FFmpeg program does not start although its components are there: 'null' for no probe, 'throw' for a failure
  late String? probeBroken;

  final videoComponents = aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.stereoVideo);
  // The 3D photos and the 3D videos
  final linux = {...aiComponentsFor(AiPlatform.linuxX64), ...videoComponents};
  final rules = LibraryPathRules(context: p.context, caseFold: false);

  setUp(() {
    root = Directory.systemTemp.createTempSync('video3d_screens');
    videos = p.join(root.path, 'Videos');
    Directory(videos).createSync();
    support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    writer = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
    jobs = VideoJobsStore(settingsDirectory: () async => support);
    service = FakeAiComponentsService(states: {for (final component in linux) component: AiComponentState.installed});
    originals = _Originals();
    probe = _Probe();
    engine = FakeVideoJobEngine(logFolder: p.join(root.path, 'logs'));
    memory = 32 * _gib;
    free = 500 * _gib;
    openedFolders = [];
    viewed = [];
    flatVideo = true;
    photos = FakeImmersiveEngine();
    probeBroken = null;
  });

  tearDown(() {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  void original(String name) {
    final path = p.join(videos, name);
    File(path).writeAsBytesSync(List.generate(200, (i) => i & 0xff));
    originals.byName[name] = LibraryOriginal(
      name: name,
      path: path,
      rootId: 'local:$videos',
      rootPath: videos,
      rootIsNetwork: false,
    );
  }

  List<Override> overrides({List<BaseAsset> selected = const []}) {
    final output = SafeWriterOutput(writer: writer);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => true),
      aiComponentsServiceProvider.overrideWithValue(service),
      desktopAiGateProvider.overrideWithValue(
        HardwareGate(
          components: _GateFiles(service, root.path),
          facts: () => AiHardwareFacts(abi: Abi.linuxX64, processors: 16, physicalMemory: memory),
          loadRuntime: (path) async => (version: '1.31.0', error: null),
          gpu: FakeGpuProbe.of(FakeGpuReports.rtx4060),
        ),
      ),
      conversionEnginesProvider.overrideWithValue(const {}),
      videoJobEngineProvider.overrideWithValue(engine),
      videoDialogProbeProvider.overrideWithValue(() async {
        if (probeBroken == 'throw') {
          throw StateError('The runner of the programs did not start');
        }
        if (probeBroken == 'null') {
          return null;
        }
        final found = videoComponents.every(
          (component) => service.statusOf(component).state == AiComponentState.installed,
        );
        return found ? probe : null;
      }),
      aiFreeSpaceProvider.overrideWithValue(
        (folder) async => free == null ? null : AiFreeSpace(free: free!, volume: '/'),
      ),
      conversionFactsReaderProvider.overrideWith(
        (ref) =>
            (asset) async => const ConversionPhotoFacts(),
      ),
      conversionAssetFilesProvider.overrideWithValue(originals),
      destinationSessionFactoryProvider.overrideWithValue(
        (jobs, settings) => DestinationSession(
          jobs,
          store: settings,
          writer: writer,
          volumes: _LocalVolumes(),
          downloadFolder: () async => p.join(root.path, 'Downloads'),
          rules: rules,
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      aiWriteGuardProvider.overrideWithValue((folder) async => true),
      safeWriterOutputProvider.overrideWithValue(output),
      aiAppVersionProvider.overrideWith((ref) async => '3.4.4'),
      conversionToolsProvider.overrideWithValue(
        ConversionTools(
          engine: photos,
          output: FakeConversionOutput(),
          finder: ExistingVersionFinder(),
          creatorTool: 'Immuch360 Desktop 3.4.4 (linux)',
          settings: store,
          video: engine,
          videoJobs: jobs,
          memory: const _Memory(),
        ),
      ),
      conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
      conversionFolderOpenerProvider.overrideWithValue((folder) async => openedFolders.add(folder)),
      versionOpenerProvider.overrideWithValue(viewed.add),
      aiFlatPhotoProvider.overrideWith((ref, asset) => asset.isImage),
      aiFlatVideoProvider.overrideWith((ref, asset) => asset.isVideo && flatVideo),
      assetsActionProvider.overrideWith((ref, source) => AssetFilter(selected)),
    ];
  }

  /// Until the screen is still and [until] holds, then still again: the change [until] waited for is drawn
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    Object? watched() => '${files.calls.length} ${probe.read_.length}';
    await settleStill(tester, watched: watched, until: until);
    if (until != null) {
      await settleStill(tester, watched: watched);
    }
  }

  Future<DesktopAiSettings> keptSettings(WidgetTester tester) async {
    DesktopAiSettings? read;
    unawaited(store.read().then((settings) => read = settings));
    for (var step = 0; step < 500 && read == null; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    return read ?? fail('desktop_ai.json was not read in time');
  }

  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  Future<ProviderContainer> openDialog(WidgetTester tester, List<BaseAsset> assets) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(openConversionDialog(context, ref, assets)),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_conversion_dialog'))));
  }

  Finder convert() => find.byKey(const Key('ai_conversion_convert'));
  bool convertEnabled(WidgetTester tester) => tester.widget<FilledButton>(convert()).onPressed != null;
  String note(WidgetTester tester, String key) =>
      tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text))).data!;

  group('the entry', () {
    Future<void> pumpEntry(
      WidgetTester tester,
      List<BaseAsset> selected, {
      ActionSource source = ActionSource.timeline,
    }) => tester.pumpConsumerWidget(
      Scaffold(
        body: DesktopMakeImmersiveButton(source: source, menuItem: source == ActionSource.viewer),
      ),
      overrides: overrides(selected: selected),
    );

    testWidgets('a selection of videos has "Make 3D (AI)" once the 3D video type is offered', (tester) async {
      await pumpEntry(tester, [_asset('clip.mp4')]);
      expect(find.byKey(const Key('ai_make_3d')), findsOneWidget);
      expect(find.text('Make 3D (AI)'), findsOneWidget);
    });

    testWidgets('in the viewer, a flat video has it, a video already 3D or 360° has not', (tester) async {
      await pumpEntry(tester, [_asset('clip.mp4')], source: ActionSource.viewer);
      expect(find.byKey(const Key('ai_make_3d')), findsOneWidget);

      flatVideo = false;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, [_asset('clip_SBS.mp4')], source: ActionSource.viewer);
      expect(find.byKey(const Key('ai_make_3d')), findsNothing);
    });

    test('a video is flat unless its name words or its frame tell two eyes; a photo is never a 3D video', () {
      expect(videoSkipOf(_asset('clip.mp4'), const ConversionPhotoFacts()), isNull);
      for (final name in ['clip_SBS.mp4', 'clip_3D_LRF_Full_SBS.mp4', 'clip_OU.mp4', 'clip_HSBS.mkv']) {
        expect(
          videoSkipOf(_asset(name), const ConversionPhotoFacts()),
          ConversionSkipReason.alreadyStereo,
          reason: name,
        );
      }
      expect(
        videoSkipOf(_asset('wide.mp4', width: 3840, height: 1080), const ConversionPhotoFacts()),
        ConversionSkipReason.alreadyStereo,
      );
      expect(
        videoSkipOf(_asset('trip.mp4'), const ConversionPhotoFacts(isPanorama: true)),
        ConversionSkipReason.sphere360,
      );
      expect(
        videoSkipOf(_asset('photo.jpg', type: AssetType.image), const ConversionPhotoFacts()),
        ConversionSkipReason.photo,
      );
    });
  });

  group('the dialog', () {
    testWidgets('before its components: what it does, experimental, its choices with their defaults, the downloads '
        'with their sizes and licences, nothing read yet, Convert off', (tester) async {
      service = FakeAiComponentsService(
        states: {
          for (final component in linux)
            if (!videoComponents.contains(component) || component.kind == AiComponentKind.runtime)
              component: AiComponentState.installed,
        },
      );
      original('clip.mp4');
      await openDialog(tester, [_asset('clip.mp4')]);

      // The type that takes a video, chosen at once
      expect(
        tester.widget<RadioGroup<ConversionKind>>(find.byKey(const Key('ai_conversion_types'))).groupValue,
        ConversionKind.stereoVideo,
      );
      expect(find.text('3D video (experimental)'), findsOneWidget);
      expect(find.text('Relief estimated by AI from a single camera, 32 frames at a time'), findsOneWidget);
      expect(
        find.text('Experimental. Not checked yet on a 3D screen or in a headset: tell us how it looks.'),
        findsOneWidget,
      );
      expect(
        tester.widget<RadioGroup<VideoDepthQuality>>(find.byType(RadioGroup<VideoDepthQuality>)).groupValue,
        VideoDepthQuality.standard,
      );
      expect(find.text('Standard (392)'), findsOneWidget);
      expect(find.text('Fast (280)'), findsOneWidget);
      expect(find.text('Fine (518)'), findsOneWidget);
      expect(
        tester.widget<ReliefStrengthChoice>(find.byKey(const Key('ai_conversion_video_strength'))).value,
        ReliefStrength.subtle,
      );
      expect(tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>)).groupValue, isFalse);
      expect(find.text('Full side by side'), findsOneWidget);
      // The components to download, on Download only: the FFmpeg program and the model, with their licences
      expect(find.byKey(const Key('ai_conversion_install')), findsOneWidget);
      expect(find.byKey(const Key('ai_licence_ffmpeg-lgpl-linux-x64')), findsOneWidget);
      expect(find.byKey(const Key('ai_licence_video-depth-anything-small-onnx')), findsOneWidget);
      expect(find.text('Licence: LGPL-2.1-or-later'), findsOneWidget);
      expect(find.text('Licence: Apache-2.0'), findsOneWidget);
      expect(find.text('Each video is checked once the FFmpeg program is installed'), findsOneWidget);
      expect(probe.read_, isEmpty);
      expect(convertEnabled(tester), isFalse);
    });

    testWidgets('a phone clip read: its notes, the encoder, the first guess, the memory, the disk, its name; Convert '
        'hands the job to the queue with the choices, kept for the next dialog', (tester) async {
      original('IMG_1234.MOV');
      probe.byName['IMG_1234.MOV'] = _facts(_phone(audio: ['aac']), 'IMG_1234.MOV');
      final container = await openDialog(tester, [_asset('IMG_1234.MOV', width: 1080, height: 1920)]);

      expect(probe.read_, ['IMG_1234.MOV']);
      expect(probe.tested, [(2160, 1920)], reason: 'the encoder tested at the Full side by side size');
      expect(find.text('HDR is tone mapped to SDR'), findsOneWidget);
      expect(find.text('10 or 12 bit colour is made 8 bit'), findsOneWidget);
      expect(find.text('Variable frame rate: each frame stays at its time on a steady rate'), findsOneWidget);
      expect(find.text('The sound is kept'), findsOneWidget);
      expect(find.text('H.264, by the encoder of this computer'), findsOneWidget);
      expect(note(tester, 'ai_conversion_video_time'), matches(RegExp(r'^About .+ to .+ of work, a first guess$')));
      expect(find.text('Uses about 3.9 GiB of memory while it runs'), findsOneWidget);
      expect(note(tester, 'ai_conversion_video_disk'), startsWith('Needs '));
      expect(find.text('Saved as IMG_1234_3D_LRF_Full_SBS.mp4'), findsOneWidget);
      expect(find.text(videos), findsOneWidget, reason: 'next to the original');
      expect(convertEnabled(tester), isTrue);

      // Strong, Fast and Half chosen: the name follows
      await tapIn(tester, find.byKey(reliefStrengthSegmentKey(ReliefStrength.strong)));
      await tapIn(tester, find.byKey(const Key('ai_conversion_video_quality_fast')));
      await tapIn(tester, find.byKey(const Key('ai_conversion_video_packing_half')));
      await settle(tester);
      expect(find.text('Saved as IMG_1234_3D_LRF_Half_SBS.mp4'), findsOneWidget);
      expect(find.text('Uses about 2.4 GiB of memory while it runs'), findsOneWidget);

      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.isNotEmpty);
      final job = container.read(conversionQueueProvider).jobs.single;
      expect(job.kind, ConversionKind.stereoVideo);
      expect(job.target?.folder, videos);
      expect(job.target?.fileName, 'IMG_1234_3D_LRF_Half_SBS.mp4');
      expect(job.video?.quality, VideoDepthQuality.fast);
      expect(job.video?.strength, ReliefStrength.strong);
      expect(job.video?.packing, VideoSbsPacking.half);
      expect(p.dirname(job.video!.workFolder), videos);
      expect(p.basename(job.video!.workFolder), startsWith('.immuch360-work-'));
      final kept = await keptSettings(tester);
      expect(kept.lastType, 'stereoVideo');
      expect(kept.videoQuality, 'fast');
      expect(kept.videoReliefStrength, ReliefStrength.strong);
      expect(kept.videoHalfSbs, isTrue);
      // The partial file of the check of the folder is not left behind
      await settle(tester);
      expect(Directory(videos).listSync().where((entity) => isPartFileName(p.basename(entity.path))), isEmpty);
    });

    testWidgets('each refusal of a video has its words, and nothing runs', (tester) async {
      final refused = {
        'sphere.mp4': (
          _phone(
            change: (v) => (v['side_data_list']! as List).add({
              'side_data_type': 'Spherical Mapping',
              'projection': 'equirectangular',
            }),
          ),
          '360° video',
        ),
        'half.mp4': (
          _phone(
            change: (v) => (v['side_data_list']! as List).add({
              'side_data_type': 'Spherical Mapping',
              'projection': 'equirectangular',
              'bound_left': 1073741823,
              'bound_right': 1073741823,
            }),
          ),
          'VR180 video',
        ),
        'stereo.mp4': (
          _phone(
            change: (v) => (v['side_data_list']! as List).add({'side_data_type': 'Stereo 3D', 'type': 'side by side'}),
          ),
          'Already a 3D video',
        ),
        'fields.mp4': (_phone(change: (v) => v['field_order'] = 'tt'), 'Interlaced video'),
        'dolby.mp4': (
          _phone(
            change: (v) => (v['side_data_list']! as List).add({
              'side_data_type': 'DOVI configuration record',
              'dv_profile': 5,
              'dv_bl_signal_compatibility_id': 0,
              'bl_present_flag': 1,
            }),
          ),
          'Dolby Vision video without a standard picture (profile 5)',
        ),
        'tilted.mp4': (
          _phone(change: (v) => (v['side_data_list']! as List).first['rotation'] = 45),
          'Video turned by an angle that is not a quarter turn',
        ),
      };
      for (final MapEntry(key: name, value: (json, _)) in refused.entries) {
        original(name);
        probe.byName[name] = _facts(json, name);
      }
      original('broken.mp4');
      probe.byName['broken.mp4'] = VideoDialogFacts(check: checkVideoSource(null, fileName: 'broken.mp4'));
      original('photo.jpg');
      await openDialog(tester, [
        for (final name in refused.keys) _asset(name),
        _asset('broken.mp4'),
        _asset('photo.jpg', type: AssetType.image),
        _asset('clip_SBS.mp4'),
      ]);
      // The photo type of the selection first: the 3D video chosen
      await tapIn(tester, find.byKey(const Key('ai_conversion_type_stereoVideo')));
      await settle(tester);

      for (final MapEntry(key: name, value: (_, words)) in refused.entries) {
        expect(find.text('$name: $words'), findsOneWidget, reason: name);
      }
      expect(find.text('broken.mp4: A video the FFmpeg program cannot read'), findsOneWidget);
      expect(find.text('photo.jpg: A photo: the 3D video type takes videos'), findsOneWidget);
      expect(find.text('clip_SBS.mp4: Already a 3D video'), findsOneWidget, reason: 'by its name, never read');
      expect(probe.read_, isNot(contains('clip_SBS.mp4')));
      expect(convertEnabled(tester), isFalse);
    });

    testWidgets('the notes of a plan: Dolby Vision base layer, slow motion, sound kept or left out, subtitles, data, a '
        'night or more', (tester) async {
      original('dv.mp4');
      probe.byName['dv.mp4'] = _facts(
        _phone(
          change: (v) {
            v['color_transfer'] = 'smpte2084';
            (v['side_data_list']! as List).add({
              'side_data_type': 'DOVI configuration record',
              'dv_profile': 8,
              'dv_bl_signal_compatibility_id': 1,
              'bl_present_flag': 1,
            });
          },
          audio: ['aac', 'ac3', 'wmav2'],
          subtitles: 1,
          duration: 1500,
        ),
        'dv.mp4',
      );
      original('fast.mp4');
      probe.byName['fast.mp4'] = _facts(
        _phone(
          change: (v) {
            v['r_frame_rate'] = '240/1';
            v['avg_frame_rate'] = '240/1';
            v['nb_frames'] = '960';
            v['duration'] = '4.0';
          },
          audio: [],
        ),
        'fast.mp4',
      );
      await openDialog(tester, [_asset('dv.mp4'), _asset('fast.mp4')]);

      expect(find.text('Dolby Vision is read through its standard picture'), findsOneWidget);
      expect(find.text('Slow motion is made 30 frames a second'), findsOneWidget);
      expect(
        find.text(
          'Audio tracks the program cannot read (WMA, AMR, ADPCM) are left out; without any other, the 3D video is silent',
        ),
        findsOneWidget,
      );
      expect(find.text('Subtitles are not kept'), findsOneWidget);
      expect(
        find.text('May take a night or more; the computer stays awake and the job resumes where it stopped'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ai_conversion_video_file')), findsNothing, reason: 'two videos, two names');
      expect(convertEnabled(tester), isTrue);
    });

    testWidgets('a FFmpeg program that does not start with its components there: said in red, Retry reads the videos', (
      tester,
    ) async {
      for (final broken in ['null', 'throw']) {
        probeBroken = broken;
        original('clip.mp4');
        await openDialog(tester, [_asset('clip.mp4')]);

        expect(find.byKey(const Key('ai_conversion_install')), findsNothing, reason: 'the components are there');
        expect(find.byKey(const Key('ai_conversion_video_reading')), findsNothing, reason: broken);
        expect(
          note(tester, 'ai_conversion_video_probe_failed'),
          'The FFmpeg program could not be started: remove it and download it again in Settings, AI components',
        );
        expect(convertEnabled(tester), isFalse);

        probeBroken = null;
        await tapIn(tester, find.byKey(const Key('ai_conversion_video_probe_retry')));
        await settle(tester, until: () => probe.read_.contains('clip.mp4'));
        expect(find.byKey(const Key('ai_conversion_video_probe_failed')), findsNothing);
        expect(find.text('H.264, by the encoder of this computer'), findsOneWidget);
        expect(convertEnabled(tester), isTrue, reason: broken);

        await tester.pumpWidget(const SizedBox.shrink());
        probe.read_.clear();
      }
    });

    testWidgets('AV1 says what plays it; no encoder, or a drive too full, keeps Convert off', (tester) async {
      original('clip.mp4');
      probe.encoderFound = VideoEncoder.svtAv1;
      await openDialog(tester, [_asset('clip.mp4')]);
      expect(find.text('AV1: plays on computers and on the Quest 3, not on a Quest 2'), findsOneWidget);
      expect(convertEnabled(tester), isTrue);

      await tester.tap(find.byKey(const Key('ai_conversion_cancel')));
      await settle(tester);
      probe.encoderFound = null;
      await openDialog(tester, [_asset('clip.mp4')]);
      expect(find.text('No video encoder of this computer passed its test'), findsOneWidget);
      expect(convertEnabled(tester), isFalse);

      await tester.tap(find.byKey(const Key('ai_conversion_cancel')));
      await settle(tester);
      probe.encoderFound = VideoEncoder.h264VaapiFull;
      free = 1000;
      await openDialog(tester, [_asset('clip.mp4')]);
      expect(note(tester, 'ai_conversion_video_disk_short'), startsWith('Only 1000 B free on that drive'));
      expect(convertEnabled(tester), isFalse);
    });

    testWidgets('Fine needs 16 GB of memory; under 8 GB only Fast; the quality kept comes back', (tester) async {
      memory = 12 * _gib;
      original('clip.mp4');
      await openDialog(tester, [_asset('clip.mp4')]);
      expect(
        tester
            .widget<RadioListTile<VideoDepthQuality>>(find.byKey(const Key('ai_conversion_video_quality_fine')))
            .enabled,
        isFalse,
      );
      expect(find.text('Fine needs 16 GB of memory or more'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ai_conversion_cancel')));
      await settle(tester);
      memory = 6 * _gib;
      await openDialog(tester, [_asset('clip.mp4')]);
      expect(
        tester.widget<RadioGroup<VideoDepthQuality>>(find.byType(RadioGroup<VideoDepthQuality>)).groupValue,
        VideoDepthQuality.fast,
      );
      expect(
        tester
            .widget<RadioListTile<VideoDepthQuality>>(find.byKey(const Key('ai_conversion_video_quality_standard')))
            .enabled,
        isFalse,
      );

      await tester.tap(find.byKey(const Key('ai_conversion_cancel')));
      await settle(tester);
      memory = 32 * _gib;
      await tester.runAsync(
        () => store.update(
          (settings) => settings.copyWith(videoQuality: 'fine', videoReliefStrength: ReliefStrength.normal),
        ),
      );
      await openDialog(tester, [_asset('clip.mp4')]);
      expect(
        tester.widget<RadioGroup<VideoDepthQuality>>(find.byType(RadioGroup<VideoDepthQuality>)).groupValue,
        VideoDepthQuality.fine,
      );
      expect(
        tester.widget<ReliefStrengthChoice>(find.byKey(const Key('ai_conversion_video_strength'))).value,
        ReliefStrength.normal,
      );
    });
  });

  group('the panel', () {
    Future<ProviderContainer> pumpPanel(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpConsumerWidget(const Scaffold(body: ConversionsPanel()), overrides: overrides());
      return ProviderScope.containerOf(tester.element(find.byType(ConversionsPanel)));
    }

    Finder inRow(String id, Finder finder) => find.descendant(of: find.byKey(ValueKey('ai_job_$id')), matching: finder);

    String add(ProviderContainer container, String name) {
      final path = p.join(videos, name);
      File(path).writeAsBytesSync([1, 2, 3]);
      return container.read(conversionQueueProvider.notifier).addVideos(
        [
          ConversionRequest(
            source: LocalFileSource(path),
            target: ConversionTarget(folder: videos, fileName: videoOutputName(name, VideoSbsPacking.full)),
          ),
        ],
        settingsOf: (_) => VideoJobSettings(
          recordId: p.basenameWithoutExtension(name),
          workFolder: videoWorkFolderIn(videos, p.basenameWithoutExtension(name)),
        ),
      ).single;
    }

    testWidgets('while it runs: frames, pace, segment, time left; Pause, then Resume and Discard', (tester) async {
      engine.holdAfter = 1;
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(tester);

      expect(find.text('Relief estimated by AI from a single camera, 32 frames at a time'), findsOneWidget);
      expect(inRow(id, find.text('2D video to 3D side by side (experimental)')), findsOneWidget);
      expect(inRow(id, find.textContaining('Computing')), findsOneWidget);
      expect(inRow(id, find.text('22 of 110 frames  •  segment 1')), findsOneWidget);
      expect(inRow(id, find.text('The time left is known after the first two windows of 32 frames')), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_video_pause'))), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_video_stop'))), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_cancel'))), findsNothing);

      engine.holdAfter = 3;
      engine.release();
      await settle(
        tester,
        until: () => container.read(conversionQueueProvider).jobs.single.videoProgress?.windows == 3,
      );
      expect(inRow(id, find.text('66 of 110 frames, 1.3 a second  •  segment 2')), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_time_left'))), findsOneWidget);
      expect(tester.widget<Text>(inRow(id, find.byKey(const Key('ai_job_time_left')))).data, startsWith('About '));

      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_pause'))));
      await settle(tester);
      expect(inRow(id, find.text('Paused')), findsOneWidget);
      expect(inRow(id, find.text('The work done is kept: Resume goes on where it stopped')), findsOneWidget);
      expect(inRow(id, find.text('66 of 110 frames, 1.3 a second')), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_video_resume'))), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_video_discard'))), findsOneWidget);
      expect(find.byKey(const Key('ai_conversions_clear_finished')), findsNothing, reason: 'a paused video is kept');

      engine.holdAfter = null;
      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_resume'))));
      await settle(
        tester,
        until: () => container.read(conversionQueueProvider).jobs.single.state == ConversionState.done,
      );
      expect(inRow(id, find.text('Done')), findsOneWidget);
      expect(engine.runs, hasLength(2));
    });

    testWidgets('Stop asks first, Cancel keeps it running, Stop deletes its work', (tester) async {
      engine.holdAfter = 1;
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(tester);

      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_stop'))));
      await settle(tester);
      expect(find.text('Stop this 3D video and delete the work done? Pause keeps it.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_video_stop_keep')));
      await settle(tester);
      expect(container.read(conversionQueueProvider).jobs.single.state.isActive, isTrue);

      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_stop'))));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ai_video_stop_yes')));
      await settle(tester);
      expect(inRow(id, find.text('Cancelled')), findsOneWidget);
      expect(engine.stops, ['cancel']);
      expect(engine.discarded, hasLength(1));
    });

    testWidgets('made: what the engine tells of it, Open the 3D video and Show in folder, no Delete', (tester) async {
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(
        tester,
        until: () => container.read(conversionQueueProvider).jobs.single.state == ConversionState.done,
      );

      final written = p.join(videos, 'clip_3D_LRF_Full_SBS.mp4');
      expect(inRow(id, find.text('Done')), findsOneWidget);
      expect(inRow(id, find.text('110 frames made 3D, 1 scene cuts found, encoded with AV1')), findsOneWidget);
      expect(inRow(id, find.text(written)), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_delete'))), findsNothing);
      expect(inRow(id, find.byKey(const Key('ai_job_view'))), findsNothing);
      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_folder'))));
      await settle(tester);
      expect(openedFolders, [videos]);
      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_open'))));
      await settle(tester);
      expect(viewed, [written]);
    });

    testWidgets('failed: the words of the engine, its log to send, Retry and Discard', (tester) async {
      engine.failure = 'The encoder stopped with 1: Invalid argument';
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.single.state.isEnded);

      expect(inRow(id, find.text('Failed')), findsOneWidget);
      expect(
        inRow(id, find.text('The 3D video stopped with an error: The encoder stopped with 1: Invalid argument')),
        findsOneWidget,
      );
      expect(
        inRow(id, find.text('Its log, to send with a report: ${p.join(root.path, 'logs', 'video3d-clip.log')}')),
        findsOneWidget,
      );
      expect(inRow(id, find.byKey(const Key('ai_job_retry'))), findsOneWidget);
      await tester.tap(inRow(id, find.byKey(const Key('ai_job_video_discard'))));
      await settle(tester);
      expect(inRow(id, find.text('Cancelled')), findsOneWidget);
      expect(engine.discarded.single.recordId, 'clip');
    });

    testWidgets('skipped by the engine, in the words of a video', (tester) async {
      engine.refusal = VideoRefusal.interlaced;
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.single.state.isEnded);
      expect(inRow(id, find.text('Skipped')), findsOneWidget);
      expect(inRow(id, find.text('Interlaced video')), findsOneWidget);
    });

    testWidgets('paused for its original or its folder: what it waits for, in red, with Resume and Discard', (
      tester,
    ) async {
      final container = await pumpPanel(tester);
      final unplugged = p.join(root.path, 'Unplugged');
      await tester.runAsync(() async {
        await jobs.put(
          VideoJobRecord(
            sourcePath: p.join(videos, 'trip.mp4'),
            folder: unplugged,
            fileName: 'trip_3D_LRF_Full_SBS.mp4',
            settings: VideoJobSettings(recordId: 'far', workFolder: videoWorkFolderIn(unplugged, 'far')),
            perMille: 500,
          ),
        );
        await container.read(conversionQueueProvider.notifier).restoreVideoJobs();
      });
      await settle(tester);
      final id = container.read(conversionQueueProvider).jobs.single.id;
      expect(
        inRow(id, find.text('The folder $unplugged is not reachable: connect its drive, then Resume')),
        findsOneWidget,
      );
      expect(inRow(id, find.byKey(const Key('ai_job_video_resume'))), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_video_discard'))), findsOneWidget);
    });

    testWidgets('Cancel all pauses a video with work done: no question, its work kept', (tester) async {
      engine.holdAfter = 1;
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(tester);
      await tester.tap(find.byKey(const Key('ai_conversions_cancel_all')));
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.single.state.isEnded);
      expect(find.byKey(const Key('ai_video_stop_confirm')), findsNothing);
      expect(inRow(id, find.text('Paused')), findsOneWidget);
      expect(inRow(id, find.byKey(const Key('ai_job_video_resume'))), findsOneWidget);
      expect(engine.stops, ['pause']);
      expect(engine.discarded, isEmpty);
    });

    testWidgets('the 3D photos asked meanwhile go first, said on the row of the video', (tester) async {
      engine.holdAfter = 1;
      final photo = photos = FakeImmersiveEngine(holdStage: .depth);
      final container = await pumpPanel(tester);
      final id = add(container, 'clip.mp4');
      await settle(tester);
      final photoPath = p.join(videos, 'salon.jpg');
      File(photoPath).writeAsBytesSync(List.generate(100, (i) => i));
      container.read(conversionQueueProvider.notifier).add([
        ConversionRequest(source: LocalFileSource(photoPath), target: ConversionTarget.nextTo(photoPath)),
      ]);
      engine.release();
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.first.yielding);
      expect(inRow(id, find.text('Lets the 3D photos asked meanwhile go first')), findsOneWidget);
      photo.release();
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      expect(inRow(id, find.text('Lets the 3D photos asked meanwhile go first')), findsNothing);
    });
  });

  testWidgets('the close guard of a video being made: how far it is, and that it resumes', (tester) async {
    engine.holdAfter = 1;
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Consumer(
        builder: (context, ref, _) => TextButton(
          key: const Key('start'),
          onPressed: () {
            final path = p.join(videos, 'clip.mp4');
            File(path).writeAsBytesSync([1, 2, 3]);
            ref.read(conversionQueueProvider.notifier).addVideos([
              ConversionRequest(
                source: LocalFileSource(path),
                target: ConversionTarget(folder: videos, fileName: 'clip_3D_LRF_Full_SBS.mp4'),
              ),
            ], settingsOf: (_) => VideoJobSettings(recordId: 'c', workFolder: videoWorkFolderIn(videos, 'c')));
          },
          child: const Text('start'),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('start')));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('start'))));
    final reasons = container.read(desktopCloseReasonsProvider)();
    expect(reasons, containsAll({DesktopCloseReason.conversions, DesktopCloseReason.video}));

    unawaited(confirmDesktopClose(tester.element(find.byKey(const Key('start'))), reasons));
    await settle(tester);
    final percent = (container.read(conversionQueueProvider).jobs.single.progress * 100).floor();
    expect(
      find.text(
        'A 3D video is being made ($percent %). Closing stops it. The 3D video resumes where it stopped next time.',
      ),
      findsOneWidget,
    );
    expect(find.text('3D conversions are running: quitting stops them.'), findsNothing, reason: 'the video is all');
    engine.release();
  });

  group('the offer at the start', () {
    Future<ProviderContainer> start(WidgetTester tester, {required String record, bool withOriginal = true}) async {
      final work = videoWorkFolderIn(videos, record);
      Directory(work).createSync();
      if (withOriginal) {
        File(p.join(videos, '$record.mp4')).writeAsBytesSync([1, 2, 3]);
      }
      await tester.runAsync(
        () => jobs.put(
          VideoJobRecord(
            sourcePath: p.join(videos, '$record.mp4'),
            folder: videos,
            fileName: '${record}_3D_LRF_Full_SBS.mp4',
            settings: VideoJobSettings(recordId: record, workFolder: work),
            perMille: 420,
          ),
        ),
      );
      await tester.pumpConsumerWidget(
        Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('start'),
            onPressed: () => unawaited(offerStoppedVideoJobs(context, ref)),
            child: const Text('start'),
          ),
        ),
        overrides: overrides(),
      );
      await tester.tap(find.byKey(const Key('start')));
      await settle(tester);
      return ProviderScope.containerOf(tester.element(find.byKey(const Key('start'))));
    }

    testWidgets('"A 3D video stopped at 42 %": Resume goes on from its work', (tester) async {
      final container = await start(tester, record: 'trip');
      expect(find.text('A 3D video was not finished'), findsOneWidget);
      expect(find.text('A 3D video stopped at 42 %'), findsOneWidget);
      expect(find.text('trip.mp4'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_video_offer_resume')));
      await settle(
        tester,
        until: () => container.read(conversionQueueProvider).jobs.single.state == ConversionState.done,
      );
      expect(engine.runs.single.settings.recordId, 'trip');
      expect(
        container.read(conversionQueueProvider).jobs.single.writtenPath,
        p.join(videos, 'trip_3D_LRF_Full_SBS.mp4'),
      );
    });

    testWidgets('Discard deletes its work', (tester) async {
      final container = await start(tester, record: 'trip');
      await tester.tap(find.byKey(const Key('ai_video_offer_discard')));
      await settle(tester);
      expect(container.read(conversionQueueProvider).jobs.single.state, ConversionState.cancelled);
      expect(engine.discarded.single.recordId, 'trip');
      expect(await tester.runAsync(jobs.read), isEmpty);
    });

    testWidgets('an original not found is said, its work kept: put it back, then Resume', (tester) async {
      final container = await start(tester, record: 'lost', withOriginal: false);
      final path = p.join(videos, 'lost.mp4');
      expect(
        tester.widget<Text>(find.byKey(const Key('ai_video_offer_missing'))).data,
        'The original video is not found at $path: put it back, then Resume',
      );
      await tester.tap(find.byKey(const Key('ai_video_offer_later')));
      await settle(tester);
      final job = container.read(conversionQueueProvider).jobs.single;
      expect(job.state, ConversionState.paused);
      expect(job.videoMissing, VideoMissing.original);
      expect((await tester.runAsync(jobs.read))!.single.id, 'lost', reason: 'its record stays');
    });

    testWidgets('Later leaves it paused in the panel', (tester) async {
      final container = await start(tester, record: 'walk');
      await tester.tap(find.byKey(const Key('ai_video_offer_later')));
      await settle(tester);
      expect(container.read(conversionQueueProvider).jobs.single.state, ConversionState.paused);
      expect(engine.runs, isEmpty);
    });
  });
}
