// "Make a splat scene (AI)" on a computer (plan 2026-11-01, sections 2.1 and 4.1, lot SP7): the entry in the bottom
// sheet of a selection, beside "Make 3D (AI)", and in the menu of the viewer of a video, and the dialog that hands a
// whole selection to the queue as one scene. A button and a dialog of their own: "Make 3D (AI)" makes one file per
// photo and hides on a selection without a photo, a splat scene makes one file of the whole selection and often comes
// from a video.
//
// The entry is there while the AI features and "Splat scenes (experimental)" (on by default, under the AI features)
// are on, once this version makes splat scenes: their engine registered (lot SP6) and their group not held back
// (aiHeldFeatureGroups held it until ai-components-4 was made, lot SP14; it holds nothing in this version). It
// shows for a selection with a photo or a video, and in the viewer of a video, greyed with the reason of the gate when
// the gate refuses for something the dialog cannot mend; missing components do not grey it, the dialog installs them.
//
// The dialog, from top to bottom: what it is, in one sentence of honesty, and that a finished conversion does not
// guarantee a good result; what is taken ("150 photos, from 1 folder", "1 video, 1 min 51 s: about 150 frames will be
// taken") and what is left out with why, 200 photos at most spread evenly in time, the lenses when there are several;
// the refusals before anything runs (fewer than 20 photos, photos and a video together, several videos, a video under
// 10 s or over 5 min, a 360° video, too little room for the work files) and the warning under 50 photos; "What did you
// film?", a place or an object, with how to film it, kept in desktop_ai.json; "Quality", three lines that name their
// targets with the time and the size each would take (lot Q1: Headset, the default, Detailed, and Maximum, greyed "Same
// as Detailed on this computer" when the memory model of splat_quality.dart leaves it at 1 920 pixels), never kept: a
// scene of half an hour is chosen each time; what the headset receives and "Also save a .ply for other 3D apps", kept
// too; the components to install (COLMAP, Brush) with the free space of their drive;
// the refusal of the gate, or the card it found; the time on this computer and what a long job of the graphics card
// does to it; the name of the scene and its file; where it goes (next to the photos or the video, or a folder of my
// choice, the question of a network folder, the reason when it cannot go next to them); and how the headset opens it:
// from Network shares when the folder is on the network, else a sentence that says the headset cannot see it. On
// battery, "Make the scene" asks first. The photos and the folder are read and planned by splat_plan.dart.
//
// "Make the scene" hands a SplatLaunch to splatLauncherProvider: the photos in the order of their time, or the video,
// with the name, the file, what was filmed and the .ply. The launcher gives it to the queue of the splat scenes (lot
// SP6, wired by lot SP8): one job whose source names the scene and reads its first photo, and whose members the engine
// reads one after the other, an original of the server with the checksum Immich gives for it.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/creator/splat_members.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/power_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_quality.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_parts.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/splat_plan.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatDialog');

/// Whether this version makes splat scenes: their engine registered in conversionEnginesProvider (lot SP6) and their
/// group not held back by the gate (aiHeldFeatureGroups)
final aiSplatScenesOfferedProvider = Provider.autoDispose<bool>((ref) {
  final engines = ref.watch(conversionEnginesProvider);
  final held = ref.watch(desktopAiGateProvider).heldGroups;
  return engines.containsKey(ConversionKind.splatScene) &&
      !held.any((group) => group.features.contains(AiFeature.splatScene));
});

/// "Splat scenes (experimental)" as desktop_ai.json keeps it, read again when the settings change it
final aiSplatScenesSwitchProvider = FutureProvider.autoDispose<bool>(
  (ref) async => (await ref.watch(desktopAiSettingsStoreProvider).read()).splatScenes,
);

/// Whether "Make a splat scene (AI)" is offered: the AI features on, the splat scenes made by this version and switched
/// on; off while the switch is being read
final aiSplatScenesOnProvider = Provider.autoDispose<bool>(
  (ref) =>
      ref.watch(aiFeaturesEnabledProvider) &&
      ref.watch(aiSplatScenesOfferedProvider) &&
      (ref.watch(aiSplatScenesSwitchProvider).valueOrNull ?? false),
);

/// Whether a video is a 360° one: of a 360° camera (its raw file, .insv, .360, .osv), flagged equirectangular by its
/// exif, or viewed as 360° by the user
typedef SplatVideo360Reader = Future<bool> Function(BaseAsset video);

/// How long the exif of a video of the server may be waited for
const _exifWait = Duration(seconds: 10);

/// The rules of the viewers, read once the exif of a video of the server answered (false while it loads)
final splatVideo360ReaderProvider = Provider<SplatVideo360Reader>((ref) {
  return (video) async {
    final equirect = ref.listen(isEquirectangularProvider(video), (_, _) {});
    final raw = ref.listen(rawMediaKindProvider(video), (_, _) {});
    try {
      if (video.hasRemote) {
        final exif = ref.listen(assetExifProvider(video).future, (_, _) {});
        try {
          await exif.read().timeout(_exifWait);
        } catch (error) {
          _log.fine('The exif of ${video.name} is not known: $error');
        } finally {
          exif.close();
        }
      }
      return raw.read() != null || equirect.read();
    } finally {
      equirect.close();
      raw.close();
    }
  };
});

/// The room the work files of a scene need on their drive (the images prepared, the database of COLMAP, the export of
/// Brush): under 2 GB for 150 photos as the design expects it, not measured yet (T1), and the originals of the server
/// copied there not counted (their size is not known before they are fetched)
const splatWorkSpaceNeeded = 2 * 1024 * 1024 * 1024;

/// The drive of the temporary files when it lacks [splatWorkSpaceNeeded]; null when it has the room, or when its free
/// space cannot be read. The work folder of a scene goes under the temporary files first (splatWorkRoots of the
/// engine), then under ProgramData, both on the system drive as a rule, never on the drive of the AI components: the
/// room there does not help
final splatWorkSpaceShortProvider = FutureProvider.autoDispose<AiFreeSpace?>((ref) async {
  final reader = ref.watch(aiFreeSpaceProvider);
  if (reader == null) {
    return null;
  }
  final temporary = await reader(Directory.systemTemp);
  return temporary == null || temporary.free >= splatWorkSpaceNeeded ? null : temporary;
});

/// The size the headset's .spz of a scene of [quality] takes ([splatHeadsetGaussiansOf]): some 24 bytes a gaussian of
/// degree 3, SPZ version 2 (3 612 448 bytes measured for 150 000)
int splatHeadsetSpzBytesOf(SplatQuality quality) => splatHeadsetGaussiansOf(quality) * SplatV1.spzBytesPerGaussian;

/// The size of the same gaussians as a .ply: 59 floats each, in the order of 3D Gaussian Splatting
const splatPlyBytesAbout = SplatV1.maxGaussians * SplatV1.plyBytesPerGaussian;

/// The memory of this computer when the dialog opens, for the definition of Maximum; replaced in tests
final splatMemoryFactsProvider = Provider<MemoryFacts Function()>((ref) => const SystemMemoryProbe().read);

/// A photo, or the video, of a scene as the dialog hands it to the queue: the photo of the app it is (for its time, its
/// thumbnail) and the source its job reads
class SplatLaunchMember {
  const SplatLaunchMember({required this.asset, required this.source});

  final BaseAsset asset;
  final ConversionSource source;

  /// When it was taken, which orders the photos
  DateTime get taken => asset.createdAt;
}

/// What "Make the scene" hands to the queue
class SplatLaunch {
  const SplatLaunch({
    required this.members,
    required this.fromVideo,
    required this.name,
    required this.label,
    required this.target,
    required this.subject,
    required this.keepPly,
    required this.isNetwork,
    this.images,
    this.quality = SplatQuality.headset,
    this.maximumResolution,
  });

  /// The photos in the order of their time, SplatV1.maxPhotos at most spread evenly, or the video alone; never empty
  final List<SplatLaunchMember> members;
  final bool fromVideo;

  /// The name chosen in the dialog, "salon"
  final String name;

  /// What the panel names the job: "salon (150 photos)", or the name of the video
  final String label;

  /// The folder and the file of the scene, `<name>_splat.spz` made safe for the computers: the copy for the headset for
  /// Headset, the whole scene for Detailed and Maximum (their copy for the headset beside it, `<name>_splat.headset.spz`)
  final ConversionTarget target;

  /// "What did you film?"
  final SplatSubject subject;

  /// "Also save a .ply for other 3D apps"
  final bool keepPly;

  /// Whether the folder is on the network: the headset can open the file there
  final bool isNetwork;

  /// The images the dialog counted and told the time of (SplatSelectionPlan.images): the photos, or the frames of the
  /// video by its length
  final int? images;

  /// "Quality", and the definition of Maximum the memory model gave (null: the same as Detailed)
  final SplatQuality quality;
  final int? maximumResolution;

  /// The settings of the scene
  SplatSettings get settings =>
      SplatSettings.of(quality, subject: subject, keepPly: keepPly, maximumResolution: maximumResolution);
}

/// Hands a scene to the queue, and gives the ids of its jobs
typedef SplatLauncher = List<String> Function(SplatLaunch launch);

/// One job of the queue for the whole scene, its file never put over another one (ConversionQueue.addSplat): named and
/// read first by [SplatSelectionSource], its members given to the engine with what was filmed and the .ply
final splatLauncherProvider = Provider<SplatLauncher>(
  (ref) =>
      (launch) => [
        ref
            .read(conversionQueueProvider.notifier)
            .addSplat(
              lead: SplatSelectionSource(launch),
              selection: SplatSelection(
                members: [for (final member in launch.members) splatMemberOf(member)],
                settings: launch.settings,
                images: launch.images,
              ),
              target: launch.target,
              video: launch.fromVideo,
            ),
      ],
);

/// [member] as the engine reads it: its source, when it was taken, and for an original of the server the checksum
/// Immich gives for it, which a Retry from the poses compares instead of downloading the photo again. A file of this
/// computer is read for its sum: the library may know an older one.
SourceSplatMember splatMemberOf(SplatLaunchMember member) => SourceSplatMember(
  member.source,
  taken: member.taken,
  sha1: member.source is ServerOriginalSource ? member.asset.checksum : null,
);

/// The photos, or the video, of a scene as one source of the queue: named as the panel shows it, its folder and its
/// fields those of the first photo in time (or of the video), the original the scene names; [prepare] reads that one,
/// [release] lets every member go (the copies of the photos of the server)
class SplatSelectionSource implements ConversionSource {
  SplatSelectionSource(this.launch) : assert(launch.members.isNotEmpty, 'A scene is made of something');

  final SplatLaunch launch;

  ConversionSource get _lead => launch.members.first.source;

  @override
  String get name => launch.label;

  @override
  String? get folder => _lead.folder;

  @override
  ImmersiveExif get exif => _lead.exif;

  @override
  Future<ImmersiveSource> prepare(NativeCancelFlag cancel) => _lead.prepare(cancel);

  /// Lets every member go, even after one failed to (a copy still open): the first failure is thrown once all were
  /// tried, the others are logged
  @override
  Future<void> release() async {
    (Object, StackTrace)? first;
    for (final member in launch.members) {
      try {
        await member.source.release();
      } catch (error, stack) {
        if (first == null) {
          first = (error, stack);
        } else {
          _log.warning('${member.source.name} of ${launch.label} could not be let go', error, stack);
        }
      }
    }
    if (first case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}

/// The words of a refusal of the gate for a splat scene: the gate of the splat scenes gives its own reasons for the
/// card and the memory (splatGpuIntegrated, splatGpuTooSmall, splatMemory), which aiGateReasonText says in the words
/// of the splat scenes, the rest as the other features say it
String splatGateReasonText(Translations t, AiGateResult gate) => aiGateReasonText(t, gate);

/// "NVIDIA GeForce RTX 4060 Laptop GPU, 8.0 GiB, Vulkan 1.4: splat scenes available", null when the gate names no card
String? splatCardText(Translations t, AiGateResult gate) {
  final card = gate.gpu;
  if (card == null || !gate.isAvailable) {
    return null;
  }
  final (major, minor) = card.vulkanVersion;
  return t.ai_immersive_splat_gpu_line(
    name: card.name,
    memory: formatBytes(card.localMemory),
    version: '$major.$minor',
  );
}

/// "6 s", "1 min 51 s", "2 min": the length of a video, to the second
String splatVideoLengthText(Translations t, Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) {
    return t.ai_immersive_duration_seconds(seconds: seconds);
  }
  final minutes = t.ai_immersive_duration_minutes(minutes: seconds ~/ 60);
  return seconds % 60 == 0 ? minutes : '$minutes ${t.ai_immersive_duration_seconds(seconds: seconds % 60)}';
}

/// The words of a refusal of the selection
String splatRefusalText(Translations t, SplatSelectionPlan plan) => switch (plan.refusal) {
  null => '',
  SplatRefusal.tooFewPhotos || SplatRefusal.nothing => t.ai_immersive_splat_too_few(
    min: SplatV1.minImages,
    good: SplatV1.fewImages,
    max: SplatV1.maxPhotos,
  ),
  SplatRefusal.mixed => t.ai_immersive_splat_mixed,
  SplatRefusal.severalVideos => t.ai_immersive_splat_one_video,
  SplatRefusal.videoShort => t.ai_immersive_splat_video_short(
    duration: splatVideoLengthText(t, plan.videoDuration ?? Duration.zero),
  ),
  SplatRefusal.videoLong => t.ai_immersive_splat_video_long(
    duration: splatVideoLengthText(t, plan.videoDuration ?? Duration.zero),
    longest: splatVideoLengthText(t, SplatV1.maxVideo),
  ),
  SplatRefusal.video360 => t.ai_immersive_splat_video_360,
  SplatRefusal.videoUnreachable => t.ai_immersive_failed_source,
};

/// Why photos are left out, after "3 photos left out:"
String splatLeftOutReasonText(Translations t, SplatLeftOutReason reason) => switch (reason) {
  SplatLeftOutReason.sphere360 => t.ai_immersive_splat_left_out_360,
  SplatLeftOutReason.unreadable => t.ai_immersive_splat_left_out_unreadable,
  SplatLeftOutReason.threeD => t.ai_immersive_skipped_3d,
  SplatLeftOutReason.aiVersion => t.ai_immersive_skipped_ai_version,
  SplatLeftOutReason.unreachable => t.ai_immersive_failed_source,
};

/// How the headset opens the scene written as [fileName]: from Network shares when its folder is on the network
/// ([network]), else the sentence that says the headset cannot see the folder. "Share this computer" serves the media
/// of the library only, never a .spz. No word of Large splats: the scene of Headset holds SplatV1.maxGaussians at
/// most and the copy of Detailed and Maximum SplatV1.headsetGaussians, both within the 300 000 the headset shows by
/// default since 8 November 2026 (splatSafeGaussians)
String splatHeadsetText(Translations t, {required bool network, required String fileName}) => network
    ? t.ai_immersive_splat_headset_network(shares: t.network_shares, name: fileName, explore: t.splat_explore)
    : t.ai_immersive_splat_headset_local;

/// "Headset (Meta Quest, phone, tablet, PC)", the line of [quality] with its targets
String splatQualityText(Translations t, SplatQuality quality) => switch (quality) {
  SplatQuality.headset => t.ai_immersive_splat_quality_headset,
  SplatQuality.detailed => t.ai_immersive_splat_quality_detailed,
  SplatQuality.maximum => t.ai_immersive_splat_quality_maximum,
};

/// "About 33 min on this computer, a file of about 19.5 MiB": what a scene of [quality] would take, its time on this
/// computer and the size of its .spz (the whole scene for Detailed and Maximum)
String splatQualityEstimateText(Translations t, SplatTime time, SplatQuality quality, SplatSubject subject) =>
    t.ai_immersive_splat_quality_estimate(
      time: aiDurationText(t, time.total),
      size: formatBytes(splatSpzBytesOf(quality, subject)),
    );

/// "About 13 min on this computer: 5 min on the processor to place the photos, 8 min on the graphics card to train the
/// splat"
String splatTimeText(Translations t, SplatTime time) => t.ai_immersive_splat_time(
  time: aiDurationText(t, time.total),
  poses: aiDurationText(t, time.poses),
  training: aiDurationText(t, time.training),
);

/// "Make a splat scene (AI)" for the photos or the video of [source]: a menu item of the viewer of a video, or a button
/// of the bottom sheet of a selection
class DesktopMakeSplatButton extends ConsumerWidget {
  const DesktopMakeSplatButton({super.key, required this.source, this.menuItem = false});

  final ActionSource source;
  final bool menuItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiSplatScenesOnProvider)) {
      return const SizedBox.shrink();
    }
    final assets = ref.watch(assetsActionProvider(source)).toList();
    if (!assets.any((asset) => asset.isImage || asset.isVideo)) {
      return const SizedBox.shrink();
    }
    // The viewer of a photo has "Make 3D (AI)": a scene needs many photos, selected together
    if (source == ActionSource.viewer && !assets.first.isVideo) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final gate = ref.watch(aiGateResultForProvider(AiFeature.splatScene)).valueOrNull;
    final refusal = aiGateRefuses(gate) ? splatGateReasonText(t, gate!) : null;
    // Not waited for: the menu of the viewer closes at once, the dialog opens over the page
    void open() => unawaited(openSplatDialog(context, ref, assets, source: source));
    final Widget button = menuItem
        ? ImmichMenuItem(
            key: const Key('ai_make_splat'),
            icon: Icons.scatter_plot_outlined,
            label: t.ai_immersive_splat_make,
            onPressed: open,
            disabled: refusal != null,
          )
        : ImmichColumnButton(
            key: const Key('ai_make_splat'),
            icon: Icons.scatter_plot_outlined,
            label: t.ai_immersive_splat_make,
            onPressed: open,
            disabled: refusal != null,
          );
    return refusal == null ? button : Tooltip(key: const Key('ai_make_splat_refused'), message: refusal, child: button);
  }
}

/// Opens the dialog of a splat scene for [assets]; once the scene was handed to the queue, the panel of the conversions
/// shows and the selection ends
Future<void> openSplatDialog(
  BuildContext context,
  WidgetRef ref,
  List<BaseAsset> assets, {
  ActionSource source = ActionSource.viewer,
}) async {
  final clearSelection = ref.read(clearSelectionProvider(source));
  // The menu that opened the dialog may be gone when it closes: the panel opens from the navigator
  final navigator = Navigator.of(context, rootNavigator: true);
  final launched = await showDialog<bool>(
    context: context,
    builder: (context) => SplatDialog(assets: assets),
  );
  if (launched != true) {
    return;
  }
  clearSelection();
  final overlay = navigator.mounted ? navigator.overlay : null;
  if (overlay != null && overlay.mounted) {
    await showConversionsPanel(overlay.context);
  }
}

/// See the top of this file
class SplatDialog extends ConsumerStatefulWidget {
  const SplatDialog({super.key, required this.assets});

  final List<BaseAsset> assets;

  @override
  ConsumerState<SplatDialog> createState() => _SplatDialogState();
}

class _SplatDialogState extends ConsumerState<SplatDialog> {
  /// The id of the one job of the destination session
  static const _jobId = 'splat';

  late final DesktopAiSettingsStore _store = ref.read(desktopAiSettingsStoreProvider);
  final _name = TextEditingController();
  DesktopAiSettings _settings = const DesktopAiSettings();
  SplatSelectionPlan? _plan;
  DestinationSession? _session;
  var _subject = SplatSubject.place;
  var _keepPly = false;
  var _quality = SplatQuality.headset;

  /// The memory of this computer when the selection was read, for the definition of Maximum
  MemoryFacts _memory = const MemoryFacts();
  AiDestination _saveTo = AiDestination.nextToOriginal;
  var _gestures = 0;
  var _asking = false;
  var _launched = false;
  var _closed = false;

  /// What went wrong while the selection was read, or when the scene was handed to the queue, in its own words
  String? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _close();
    _name.dispose();
    super.dispose();
  }

  void _close() {
    if (_closed) {
      return;
    }
    _closed = true;
    final session = _session;
    if (session != null) {
      unawaited(session.close());
    }
  }

  /// Reads and plans the selection, then opens the destination of the scene; what fails is said in the dialog instead
  /// of a wheel turning for ever
  Future<void> _prepare() async {
    try {
      await _prepareSelection();
    } catch (error, stack) {
      _log.warning('The selection of a splat scene could not be read', error, stack);
      if (mounted && !_closed) {
        setState(() => _failure = '$error');
      }
    }
  }

  Future<void> _prepareSelection() async {
    _settings = await _store.read();
    final candidates = await _read();
    if (!mounted || _closed || candidates == null) {
      return;
    }
    final plan = await _readLenses(planSplatSelection(candidates));
    if (!mounted || _closed) {
      return;
    }
    final memory = ref.read(splatMemoryFactsProvider)();
    setState(() {
      _memory = memory;
      _plan = plan;
      _subject = _settings.splatSubject;
      _keepPly = _settings.splatKeepPly;
      _name.text = plan.defaultName;
    });
    final destination = plan.destination?.found?.location;
    if (plan.refusal != null || destination == null) {
      return;
    }
    final session = ref.read(destinationSessionFactoryProvider)([
      DestinationJob(
        id: _jobId,
        original: splatNamedLocation(destination, plan.defaultName),
        kind: ImmersiveKind.gaussianSplat,
      ),
    ], _store);
    if (!mounted || _closed) {
      unawaited(session.close());
      return;
    }
    setState(() {
      _session = session;
      _saveTo = _settings.destination;
    });
    await _gesture(session.open);
  }

  /// The photos or the video of the selection, read once: what the viewers know of each photo and where its original
  /// is; for a video, where it is and whether it is a 360° one. A selection the plan refuses whatever its files (photos
  /// and a video, several videos) is not read. Null once the dialog closed meanwhile. The focal lengths are read after,
  /// for the photos used only (_readLenses).
  Future<List<SplatCandidate>?> _read() async {
    final assets = widget.assets;
    final videos = assets.where((asset) => asset.isVideo).length;
    if (videos > 1 || (videos == 1 && assets.any((asset) => !asset.isVideo))) {
      return [for (final asset in assets) SplatCandidate(asset: asset)];
    }
    final facts = ref.read(conversionFactsReaderProvider);
    final files = ref.read(conversionAssetFilesProvider);
    final video360 = ref.read(splatVideo360ReaderProvider);
    final candidates = <SplatCandidate>[];
    for (final asset in assets) {
      if (_closed) {
        return null;
      }
      if (asset.isVideo) {
        candidates.add(
          SplatCandidate(asset: asset, found: await files.locate(asset), isVideo360: await video360(asset)),
        );
        continue;
      }
      if (!asset.isImage) {
        candidates.add(SplatCandidate(asset: asset));
        continue;
      }
      final known = await facts(asset);
      // Left out by what it is: its original is not looked for
      final reason = splatLeftOutOf(SplatCandidate(asset: asset, facts: known));
      if (reason != null && reason != SplatLeftOutReason.unreachable) {
        candidates.add(SplatCandidate(asset: asset, facts: known));
        continue;
      }
      candidates.add(SplatCandidate(asset: asset, facts: known, found: await files.locate(asset)));
    }
    return candidates;
  }

  /// [plan] with the lenses of the photos it uses, read from the heads of their files: only the photos used (200 at
  /// most, not all those selected), and never a file kept online only, which OneDrive would download to read its head
  /// before the user said yes to anything. [plan] as it is for a video, a refusal, or once the dialog closed meanwhile.
  Future<SplatSelectionPlan> _readLenses(SplatSelectionPlan plan) async {
    if (plan.isVideo || plan.refusal != null) {
      return plan;
    }
    final focal = ref.read(conversionFocalReaderProvider);
    final focals = <int?>[];
    for (final photo in plan.used) {
      if (_closed) {
        return plan;
      }
      final found = photo.found;
      final location = found?.location;
      if (found == null || location is LibraryOriginal && location.cloudOnly) {
        focals.add(null);
        continue;
      }
      try {
        focals.add(await focal(found.source));
      } catch (error) {
        _log.fine('The focal length of ${photo.asset.name} is not known: $error');
        focals.add(null);
      }
    }
    return plan.withFocals(focals);
  }

  /// Runs a gesture of the destination session; "Make the scene" waits for it
  Future<void> _gesture(Future<void> Function() gesture) async {
    setState(() => _gestures++);
    try {
      await gesture();
    } catch (error, stack) {
      _log.warning('A gesture of the dialog of a splat scene failed', error, stack);
    } finally {
      if (mounted) {
        setState(() => _gestures--);
      }
    }
  }

  Future<void> _setSaveTo(AiDestination destination) async {
    final session = _session;
    if (session == null || destination == _saveTo) {
      return;
    }
    setState(() => _saveTo = destination);
    await _gesture(() => session.saveTo(destination));
  }

  Future<void> _changeFolder() async {
    final session = _session;
    if (session == null) {
      return;
    }
    final String? picked;
    try {
      picked = await filePickers.folder(confirmButtonText: context.t.ai_immersive_save_to);
    } on Exception catch (error) {
      _log.warning('The folder dialog failed: $error');
      return;
    }
    if (picked != null && mounted) {
      await _gesture(() => session.chooseFolder(picked!));
    }
  }

  /// The plan of the destination of the scene, null until it is known
  PlannedDestination? get _destination => _session?.destinations[_jobId];

  /// Whether the folder may receive the scene: no question left, its check passed
  bool _ready(DestinationSession session) {
    if (session.pendingConsents.isNotEmpty) {
      return false;
    }
    final check = session.checkOf(_jobId);
    return check != null && check.accepted;
  }

  /// The file of the scene under the name typed
  String get _fileName => versionTargetName(ImmersiveKind.gaussianSplat, _name.text.trim());

  /// The file the headset opens: the scene for Headset, its copy for the headset beside it otherwise
  String get _headsetFileName => _quality.hasHeadsetCopy ? splatHeadsetCopyNameOf(_fileName) : _fileName;

  /// The definition of Maximum on this computer for [plan], null when it is the same as Detailed: the memory read when
  /// the selection was, the physical memory of the gate when the probe gave none, the card of the gate
  int? _maximumResolution(SplatSelectionPlan plan) {
    final gate = ref.read(aiGateResultForProvider(AiFeature.splatScene)).valueOrNull;
    return splatMaximumResolution(
      images: splatImageSizesOf(plan),
      physical: _memory.physical ?? gate?.physicalMemory,
      available: _memory.available,
      cardMemory: gate?.graphicsMemory,
    );
  }

  /// The settings of a scene of [quality] of [plan]
  SplatSettings _settingsOf(SplatSelectionPlan plan, SplatQuality quality) => SplatSettings.of(
    quality,
    subject: _subject,
    keepPly: _keepPly,
    maximumResolution: quality == SplatQuality.maximum ? _maximumResolution(plan) : null,
  );

  /// The time of [plan] on this computer for [quality] (the one chosen by default): the times it measured, else the
  /// defaults by its processors as the gate read them (as measured until the gate answers)
  SplatTime _time(SplatSelectionPlan plan, [SplatQuality? quality]) => splatTimeOf(
    AiTimings(_settings.timings, ref.read(aiGateResultForProvider(AiFeature.splatScene)).valueOrNull?.processors),
    images: plan.images,
    video: plan.isVideo,
    settings: _settingsOf(plan, quality ?? _quality),
  );

  Future<void> _start(DestinationSession session) async {
    final plan = _plan;
    final destination = _destination;
    if (_launched || _asking || plan == null || destination == null) {
      return;
    }
    final t = context.t;
    // The training keeps the graphics card busy for minutes: on battery, asked first
    if (ref.read(aiPowerProbeProvider).onBattery() == true) {
      setState(() => _asking = true);
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('ai_splat_battery'),
          content: Text(context.t.ai_immersive_splat_battery(time: aiDurationText(context.t, _time(plan).training))),
          actions: [
            TextButton(
              key: const Key('ai_splat_battery_cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.t.cancel),
            ),
            FilledButton(
              key: const Key('ai_splat_battery_go'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t.continue$),
            ),
          ],
        ),
      );
      if (!mounted || _closed) {
        return;
      }
      setState(() => _asking = false);
      if (go != true || _launched) {
        return;
      }
    }
    _launched = true;
    final name = _name.text.trim();
    final members = [
      for (final candidate in plan.used) SplatLaunchMember(asset: candidate.asset, source: candidate.found!.source),
    ];
    final List<String> ids;
    try {
      ids = ref.read(splatLauncherProvider)(
        SplatLaunch(
          members: members,
          fromVideo: plan.isVideo,
          name: name,
          label: plan.isVideo
              ? members.single.asset.name
              : t.ai_immersive_splat_job_photos(name: name, count: members.length),
          target: ConversionTarget.inFolder(destination.folder, name, kind: ConversionKind.splatScene),
          subject: _subject,
          keepPly: _keepPly,
          isNetwork: destination.isNetwork,
          images: plan.images,
          quality: _quality,
          maximumResolution: _quality == SplatQuality.maximum ? _maximumResolution(plan) : null,
        ),
      );
    } catch (error, stack) {
      // The dialog stays with why, and Make the scene can be pressed again
      _log.warning('A splat scene could not be handed to the queue', error, stack);
      _launched = false;
      if (mounted && !_closed) {
        setState(() => _failure = '$error');
      }
      return;
    }
    ref.read(conversionJobInfoProvider.notifier).addAll({
      for (final id in ids) id: ConversionJobInfo(asset: members.first.asset, isNetwork: destination.isNetwork),
    });
    final kept = await _store.read();
    if (kept.splatSubject != _subject || kept.splatKeepPly != _keepPly) {
      unawaited(_store.update((kept) => kept.copyWith(splatSubject: _subject, splatKeepPly: _keepPly)));
    }
    _close();
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final plan = _plan;
    final session = _session;
    final gateAnswer = ref.watch(aiGateResultForProvider(AiFeature.splatScene));
    final gate = gateAnswer.valueOrNull;
    final refusedByGate = aiGateRefuses(gate);
    final available = gate?.isAvailable ?? false;
    final missing = gate != null && !available && !refusedByGate;
    // The components being moved read as missing until the copy ends: nothing to download, the scene waits
    final moving = ref.read(aiComponentsServiceProvider).isMoving;
    final workShort = ref.watch(splatWorkSpaceShortProvider).valueOrNull;
    final refused = plan?.refusal != null;
    final named = _name.text.trim().isNotEmpty;
    final busy = _gestures > 0 || plan == null || _asking;
    final canStart =
        !busy &&
        !moving &&
        !_launched &&
        available &&
        !refused &&
        workShort == null &&
        named &&
        session != null &&
        _ready(session);

    return AlertDialog(
      key: const Key('ai_splat_dialog'),
      title: Text(t.ai_immersive_splat_make),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.ai_immersive_splat_intro, key: const Key('ai_splat_intro'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(t.ai_immersive_no_guarantee, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              if (plan == null && _failure == null || gateAnswer.isLoading && gate == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (plan != null) ..._selection(t, plan),
              if (workShort != null)
                ConversionNote(
                  key: const Key('ai_splat_work_space'),
                  text: t.ai_immersive_splat_work_space(
                    needed: formatBytes(splatWorkSpaceNeeded),
                    drive: workShort.volume,
                  ),
                  error: true,
                ),
              if (plan != null && !refused) ...[
                ..._subjectChoice(t),
                ..._qualityChoice(t, plan),
                const SizedBox(height: 8),
                Text(
                  t.ai_immersive_splat_headset_copy(
                    gaussians: splatHeadsetGaussiansOf(_quality),
                    size: formatBytes(splatHeadsetSpzBytesOf(_quality)),
                  ),
                  key: const Key('ai_splat_headset_copy'),
                ),
                CheckboxListTile(
                  key: const Key('ai_splat_keep_ply'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _keepPly,
                  title: Text(t.ai_immersive_splat_keep_ply),
                  subtitle: Text(
                    t.ai_immersive_splat_keep_ply_hint(size: formatBytes(splatPlyBytesOf(_quality, _subject))),
                  ),
                  onChanged: _launched ? null : (on) => setState(() => _keepPly = on ?? false),
                ),
                ..._gate(t, gate, refusedByGate: refusedByGate, missing: missing, moving: moving),
                ConversionNote(key: const Key('ai_splat_time'), text: splatTimeText(t, _time(plan))),
                ConversionNote(key: const Key('ai_splat_gpu_busy'), text: t.ai_immersive_gpu_busy_warning),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('ai_splat_name'),
                  controller: _name,
                  enabled: !_launched,
                  decoration: InputDecoration(
                    labelText: t.ai_immersive_splat_name,
                    helperText: named ? _fileName : null,
                    errorText: named ? null : t.ai_immersive_splat_name_empty,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (session != null) ..._where(t, session, plan),
              ],
              // "Error: ...", the words of what failed (error_saving_image is the generic "Error: {error}")
              if (_failure case final failure?)
                ConversionNote(
                  key: const Key('ai_splat_failed'),
                  text: t.error_saving_image(error: failure),
                  error: true,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ai_splat_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.cancel),
        ),
        FilledButton(
          key: const Key('ai_splat_start'),
          onPressed: canStart ? () => unawaited(_start(session)) : null,
          child: Text(t.ai_immersive_splat_start),
        ),
      ],
    );
  }

  /// What is taken, what is left out and why, the cap, the lenses, then the refusal or the warning
  List<Widget> _selection(Translations t, SplatSelectionPlan plan) => [
    if (plan.refusal == null)
      Text(
        plan.isVideo
            ? t.ai_immersive_splat_video_taken(
                duration: plan.videoDuration == null ? '…' : splatVideoLengthText(t, plan.videoDuration!),
                frames: plan.images,
              )
            : t.ai_immersive_splat_photos_taken(count: plan.used.length, folders: plan.folders),
        key: const Key('ai_splat_taken'),
      ),
    for (final MapEntry(key: reason, value: count) in plan.leftOut.entries)
      ConversionNote(
        key: Key('ai_splat_left_out_${reason.name}'),
        text: t.ai_immersive_splat_left_out(count: count, reason: splatLeftOutReasonText(t, reason)),
      ),
    if (plan.capped && plan.refusal == null)
      ConversionNote(
        key: const Key('ai_splat_capped'),
        text: t.ai_immersive_splat_capped(max: SplatV1.maxPhotos, count: plan.usable),
      ),
    if (plan.lenses.isNotEmpty && plan.refusal == null)
      ConversionNote(
        key: const Key('ai_splat_lenses'),
        text: t.ai_immersive_splat_lenses(
          count: plan.lenses.length,
          lenses: [for (final focal in plan.lenses) '$focal mm'].join(', '),
        ),
      ),
    if (plan.refusal != null)
      ConversionNote(key: const Key('ai_splat_refusal'), text: splatRefusalText(t, plan), error: true),
    if (plan.fewPhotos)
      ConversionNote(
        key: const Key('ai_splat_few'),
        text: t.ai_immersive_splat_few_photos(good: SplatV1.fewImages, max: SplatV1.maxPhotos),
      ),
  ];

  /// "What did you film?", a place or an object, with how to film it
  List<Widget> _subjectChoice(Translations t) => [
    const SizedBox(height: 8),
    Text(t.ai_immersive_splat_subject, style: Theme.of(context).textTheme.titleSmall),
    RadioGroup<SplatSubject>(
      groupValue: _subject,
      onChanged: (subject) {
        if (subject != null && !_launched) {
          setState(() => _subject = subject);
        }
      },
      child: Column(
        children: [
          for (final (subject, label) in [
            (SplatSubject.place, t.ai_immersive_splat_subject_place),
            (SplatSubject.object, t.ai_immersive_splat_subject_object),
          ])
            RadioListTile<SplatSubject>(
              key: Key('ai_splat_subject_${subject.name}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: subject,
              title: Text(label),
            ),
        ],
      ),
    ),
    ConversionNote(
      key: const Key('ai_splat_tip'),
      text: switch (_subject) {
        SplatSubject.place => t.ai_immersive_splat_tip_place,
        SplatSubject.object => t.ai_immersive_splat_tip_object,
      },
    ),
    ConversionNote(key: const Key('ai_splat_tip_always'), text: t.ai_immersive_splat_tip_always),
  ];

  /// "Quality": Headset, Detailed and Maximum, each with its targets, its time on this computer and the size of its
  /// file; Maximum greyed "Same as Detailed on this computer" when the memory model leaves it at 1 920 pixels
  List<Widget> _qualityChoice(Translations t, SplatSelectionPlan plan) {
    final maximum = _maximumResolution(plan);
    return [
      const SizedBox(height: 8),
      Text(t.ai_immersive_splat_quality, style: Theme.of(context).textTheme.titleSmall),
      RadioGroup<SplatQuality>(
        groupValue: _quality,
        onChanged: (quality) {
          if (quality != null && !_launched) {
            setState(() => _quality = quality);
          }
        },
        child: Column(
          children: [
            for (final quality in SplatQuality.values)
              RadioListTile<SplatQuality>(
                key: Key('ai_splat_quality_${quality.name}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: quality,
                enabled: !_launched && (quality != SplatQuality.maximum || maximum != null),
                title: Text(splatQualityText(t, quality)),
                subtitle: Text(
                  quality == SplatQuality.maximum && maximum == null
                      ? t.ai_immersive_splat_quality_same
                      : splatQualityEstimateText(t, _time(plan, quality), quality, _subject),
                  key: Key('ai_splat_quality_${quality.name}_estimate'),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  /// The refusal of the gate, the components to install with the free space of their drive, or the card it found
  List<Widget> _gate(
    Translations t,
    AiGateResult? gate, {
    required bool refusedByGate,
    required bool missing,
    required bool moving,
  }) {
    if (gate == null) {
      return const [];
    }
    if (refusedByGate) {
      return [ConversionNote(key: const Key('ai_splat_gate_refused'), text: splatGateReasonText(t, gate), error: true)];
    }
    if (moving) {
      return [ConversionNote(key: const Key('ai_splat_moving'), text: t.ai_immersive_components_moving)];
    }
    final platform = gate.platform;
    if (missing && platform != null) {
      return [
        Card(
          key: const Key('ai_splat_install'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AiInstallPanel(
                  components: aiComponentsFor(
                    platform,
                    feature: AiFeature.splatScene,
                    graphicsMemory: gate.graphicsMemory,
                    catalogue: ref.read(desktopAiGateProvider).catalogue,
                  ),
                  onInstalled: () => ref.invalidate(aiGateResultForProvider(AiFeature.splatScene)),
                ),
                const ConversionInstallSpace(choice: (feature: AiFeature.splatScene, chained: null)),
              ],
            ),
          ),
        ),
      ];
    }
    return [if (splatCardText(t, gate) case final card?) ConversionNote(key: const Key('ai_splat_card'), text: card)];
  }

  /// Where the scene goes, the question of a network folder, and how the headset opens it
  List<Widget> _where(Translations t, DestinationSession session, SplatSelectionPlan plan) {
    final destination = _destination;
    final location = plan.destination?.found?.location;
    final mayGoNext = location is LibraryOriginal || location is OpenedOriginal;
    return [
      Text(t.ai_immersive_save_to, style: Theme.of(context).textTheme.titleSmall),
      if (mayGoNext)
        RadioGroup<AiDestination>(
          groupValue: _saveTo,
          onChanged: (value) {
            if (value != null && _gestures == 0) {
              unawaited(_setSaveTo(value));
            }
          },
          child: Column(
            children: [
              RadioListTile<AiDestination>(
                key: const Key('ai_splat_next_to'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: AiDestination.nextToOriginal,
                title: Text(plan.isVideo ? t.ai_immersive_splat_next_to_video : t.ai_immersive_splat_next_to_photos),
              ),
              RadioListTile<AiDestination>(
                key: const Key('ai_splat_chosen_folder'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: AiDestination.folder,
                title: Text(t.ai_immersive_chosen_folder),
              ),
            ],
          ),
        ),
      if (destination != null && !destination.waitsForConsent)
        ConversionFolderLine(
          key: ValueKey('ai_splat_folder_${destination.folder}'),
          folder: destination.folder,
          count: null,
          reason: destinationReasonText(t, destination.reason, message: destination.message),
          check: session.checkOf(_jobId),
          onChange: _gestures == 0 && destination.kind == DestinationKind.chosenFolder
              ? () => unawaited(_changeFolder())
              : null,
          shareHint: destination.shareHint,
          cloud: destination.cloudDownload,
        ),
      for (final MapEntry(key: key, value: folder) in session.pendingConsents.entries)
        ConversionNetworkQuestion(
          key: ValueKey('ai_splat_network_$key'),
          folder: folder,
          onYes: _gestures == 0 ? () => unawaited(_gesture(() => session.allowNetwork(key))) : null,
          onNo: _gestures == 0 ? () => unawaited(_gesture(() => session.declineNetwork(key))) : null,
        ),
      if (destination != null && !destination.waitsForConsent && _ready(session))
        ConversionNote(
          key: const Key('ai_splat_headset'),
          text: splatHeadsetText(t, network: destination.isNetwork, fileName: _headsetFileName),
        ),
    ];
  }
}
