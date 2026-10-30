// "Make 3D (AI)" on a computer (design-final 2026-10-26, section 5, points 1 to 3): the entry in the menu of the viewer
// and in the bottom sheet of a selection, and the dialog that launches the conversions.
//
// The entry is absent while the AI features are off (Settings, This computer, AI and 3D). It is greyed with its reason
// when this computer cannot run them (the hardware gate: system, processor, memory, ONNX Runtime that does not load);
// missing components do not grey it, the dialog offers to install them. In the viewer it is offered for a flat photo
// and, since the 3D version of a 360° photo has its type in the dialog (lot P1), for a 360° photo too. What each type
// of version takes is told by type, by aiSourceProvider and conversionSkipOf (design-final 2026-10-27, section 9.1,
// point 1): a flat photo for a 3D photo, a 3D scene or a 360° panorama; a 360° photo of a full sphere that holds one
// eye, of the user or a panorama the app generated, for its 3D version. Whether a 2:1 frame is a full sphere is told
// by its GPano crop too, which the dialog reads from a file of this computer (a phone panorama of 180° x 90° is
// skipped, "Not a 360° photo", before its job would refuse it). A photo the 360° rules leave flat (no GPano tag, no
// 360° camera in its exif, not viewed as 360° by the user) is taken by the 3D version of a 360° photo when its frame
// is 2:1 within 1 %: many 360° photos carry no tag, and the user chose that type for it (30 October 2026, the
// rooftop_night.jpg of FreeKC). The frame alone cannot tell such a photo from an 18:9 phone photo or two square eyes
// side by side, so the plan names each one taken so, "No 360° tag, 2:1 frame only: check that each is a 360° photo";
// two eyes still refuse it when our XMP in its head or its name tells them (as the viewer reads them), a half sphere
// when the user picked one for it in a 360° viewer, a raw photo when the trailer of its file, or else the make of an
// Insta360 camera the server gives, tells one.
//
// The dialog says what the conversion is ("Relief estimated by AI from a single photo") and that a finished one does
// not guarantee a good result; installs the missing components (their name, size and licence, Download, a bar,
// Cancel); lists the photos that will be skipped and why (a video, a 360° or VR180 photo, a spatial photo, a 3D photo
// already, a format this system cannot read); says where the 3D photos go (next to the original, or a folder of my
// choice with its path and Change, with the reason when the original cannot receive a file), asks the question of a
// network folder when one is involved, and what to do when a 3D version exists; tells that the rotation the user chose
// is applied. Convert hands the photos to the queue and shows the panel of the conversions.
//
// The folders are checked as the dialog opens, by the partial file of the first job of each folder (lot A5b): its job
// takes it over at the launch, and those no job takes are deleted when the dialog closes. A folder of the library is
// neither checked nor written into before the album of the generated photos is out of the backup (lot A6a): until then
// the 3D photos go to the folder of my choice, with the reason.
//
// Phases 2 and 3 (design-final 2026-10-27, section 9.1, point 2): the dialog starts with the type of version, among the
// types registered in conversionDialogKinds that this build makes (the 3D photo, the 3D scene, the 360° panorama and
// the 3D version of a 360° photo), the one chosen last kept in desktop_ai.json (lastType). A type the gate refuses
// stays listed, greyed with its reason; a type whose group this version holds back (aiHeldFeatureGroups, empty since
// the release of the components of the 360° panoramas) is not listed, being no feature of this version. Under the
// choice, what the type is (its honesty sentence), the components of its feature that are missing with the free space
// of their drive, its gate, and the time a photo takes on this computer; then the destination, the question of a
// network folder, "If a version exists", and for a mixed selection the plan of each photo: those the type makes, and
// those skipped and why. Changing the type plans the selection again for it (the photos it takes, the names of their
// files), with what the user chose in this dialog. While the AI components are moved to another folder ("Move the AI
// components"), they read as missing: the dialog says Convert waits for the end of the copy instead of offering to
// download them.
//
// The 360° panorama (lot U3; design-final 2026-10-27, sections 4.7 and 9.1, point 2): the part of it the AI invents
// ("About 92% of this panorama will be invented by AI", from the field of view the EXIF of the photo tells, or that of
// the main camera of a phone), "Also make the 3D version", checked by default and kept (alsoStereoPanorama), which
// chains the 3D version after each panorama and asks for its components too, what a generation does to the computer
// ("The graphics card stays busy for several minutes; games and videos may stutter"), and, on battery, a question
// before Convert. "360° 3D panorama" is the 360° panorama with that box checked: two types and a box would say the
// same thing twice.
// The entry of the viewer is offered when one of the types takes the photo (aiSourceProvider): a flat photo, and a
// 360° photo of a whole sphere that holds one eye for its 3D version, by the rule of the plan (conversionSkipOf), a
// photo of 2:1 nothing flags 360° among them. With "Also save a .glb copy", each scene made gets its .glb next to it
// (scene_glb_export.dart).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/scene_glb_export.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/power_probe.dart';
import 'package:immich_mobile/desktop/ai/scene/focal_shift.dart' show halfDiagonal35mm;
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart' show isSideBySideFrame;
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart' show readGPanoFile;
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ConversionDialog');

/// The AI features, on or off (Settings, This computer, AI and 3D): off, no AI button anywhere
final aiFeaturesEnabledProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(appConfigProvider.select((config) => config.aiImmersive.enabled)),
);

/// What the hardware gate says now of [AiFeature]; asked again when a component is installed or removed, and when the
/// components start or end a move to another folder (C5-review point 1: they read as missing meanwhile)
final aiGateResultForProvider = FutureProvider.autoDispose.family<AiGateResult, AiFeature>((ref, feature) async {
  final service = ref.watch(aiComponentsServiceProvider);
  final gate = ref.watch(desktopAiGateProvider);
  String states() =>
      [service.isMoving, for (final component in aiComponents) service.statusOf(component).state.name].join(',');
  var known = states();
  void changed() {
    final now = states();
    if (now != known) {
      known = now;
      ref.invalidateSelf();
    }
  }

  service.addListener(changed);
  ref.onDispose(() => service.removeListener(changed));
  try {
    await service.load();
  } catch (error) {
    _log.warning('The folder of the AI components could not be read: $error');
  }
  known = states();
  return gate.evaluate(feature: feature);
});

/// What the hardware gate says now of the 3D photo, the feature of phase 1
final aiGateResultProvider = aiGateResultForProvider(AiFeature.stereoPhoto);

/// The types of version the dialog offers, in their order (design-final 2026-10-27, section 9.1, point 2): the 3D photo
/// of phase 1, the 3D scene of phase 2, the 360° panorama of phase 3 (lot U3) and the 3D version of a 360° photo (lot
/// P1)
const conversionDialogKinds = [
  ConversionKind.sbsFromPhoto,
  ConversionKind.sceneFromPhoto,
  ConversionKind.panoramaFromPhoto,
  ConversionKind.stereoPanoramaFromPanorama,
];

/// The types of [conversionDialogKinds] this build makes: the 3D photo always, another one once its lot registered its
/// engine in conversionEnginesProvider, the registry the tools of the queue are given (ConversionTools.supports), and
/// its group is not held back by this version (HardwareGate.heldGroups)
final offeredConversionKindsProvider = Provider.autoDispose<List<ConversionKind>>((ref) {
  final engines = ref.watch(conversionEnginesProvider);
  final held = ref.watch(desktopAiGateProvider).heldGroups;
  bool isHeld(ConversionKind kind) => held.any((group) => group.features.contains(aiFeatureOf(kind)));
  return [
    for (final kind in conversionDialogKinds)
      if (kind == ConversionKind.sbsFromPhoto || (engines.containsKey(kind) && !isHeld(kind))) kind,
  ];
});

/// The feature of the AI a type of version needs: its components and its gate
AiFeature aiFeatureOf(ConversionKind kind) => switch (kind) {
  ConversionKind.sbsFromPhoto => AiFeature.stereoPhoto,
  ConversionKind.sceneFromPhoto => AiFeature.scene,
  ConversionKind.panoramaFromPhoto => AiFeature.panorama,
  ConversionKind.stereoPanoramaFromPanorama => AiFeature.stereoPanorama,
};

/// The name of a type of version in the dialog: "3D photo", "3D scene"
String conversionKindName(Translations t, ConversionKind kind) => switch (kind) {
  ConversionKind.sbsFromPhoto => t.ai_immersive_3d_photo,
  ConversionKind.sceneFromPhoto => t.ai_immersive_type_scene,
  ConversionKind.panoramaFromPhoto => t.ai_immersive_type_panorama,
  ConversionKind.stereoPanoramaFromPanorama => t.ai_immersive_type_stereo_360,
};

/// What a type of version is, in the words of its honesty label; the 3D version of a panorama the app [generated] is
/// said as generated, as its file, the panel and "Versions" say it
String conversionKindHonesty(Translations t, ConversionKind kind, {bool generated = false}) => switch (kind) {
  ConversionKind.sbsFromPhoto => t.ai_immersive_dialog_title,
  ConversionKind.sceneFromPhoto => t.ai_immersive_scene_honesty,
  ConversionKind.panoramaFromPhoto => t.ai_immersive_panorama_honesty,
  ConversionKind.stereoPanoramaFromPanorama when generated => t.ai_immersive_panorama_honesty,
  ConversionKind.stereoPanoramaFromPanorama => t.ai_immersive_relief_estimated,
};

/// "6 s", "4 min": a time of the conversions, the seconds rounded up under a minute, the minutes rounded above
String aiDurationText(Translations t, Duration duration) {
  var seconds = (duration.inMilliseconds / 1000).ceil();
  if (seconds < 1) {
    seconds = 1;
  }
  return seconds < 60
      ? t.ai_immersive_duration_seconds(seconds: seconds)
      : t.ai_immersive_duration_minutes(minutes: (seconds / 60).round());
}

/// "About 6 s per photo", from the times of the steps on this computer (AiTimings); "on this graphics card" for a type
/// of the graphics card; null when nothing tells it
String? conversionTimeText(Translations t, ConversionKind kind, AiTimings timings) {
  final expected = kind.expectedDuration(timings);
  if (expected <= Duration.zero) {
    return null;
  }
  final time = aiDurationText(t, expected);
  return kind.lane == ConversionLane.gpu
      ? t.ai_immersive_time_per_photo_gpu(time: time)
      : t.ai_immersive_time_per_photo(time: time);
}

/// The focal length equivalent to 35 mm the dialog takes for a photo whose EXIF does not tell it: the main camera of a
/// phone. The engine finds the field of view of such a photo by its model of the geometry; the dialog only estimates.
const panoramaDefaultFocal35 = 26;

/// The part of a 360° panorama the AI invents around a photo of [width] x [height] taken at [focal35] millimetres
/// equivalent to 35 mm ([panoramaDefaultFocal35] when not known), from 0 to 1. The field of view comes from the focal
/// length on the diagonal of 43.27 mm, then across the width and the height of the frame (design-final 2026-10-27,
/// section 4.3, point 2); the photo projected at the centre covers the solid angle of its rectangle, 4 asin(sin(h / 2)
/// sin(v / 2)) of the 4 pi of the sphere, what the engine writes as SourceCoverage. A frame not known is taken as 4:3.
double panoramaInventedShare({int? width, int? height, int? focal35}) {
  final known = width != null && height != null && width > 0 && height > 0;
  final w = known ? width.toDouble() : 4.0;
  final h = known ? height.toDouble() : 3.0;
  final focal = focal35 != null && focal35 > 0 ? focal35 : panoramaDefaultFocal35;
  // tan of half the diagonal field of view, spread over the width and the height
  final tanHalf = halfDiagonal35mm / focal / math.sqrt(w * w + h * h);
  final halfWidth = math.atan(tanHalf * w);
  final halfHeight = math.atan(tanHalf * h);
  return 1 - math.asin(math.sin(halfWidth) * math.sin(halfHeight)) / math.pi;
}

/// The focal length equivalent to 35 mm the EXIF of a photo tells (FocalLengthIn35mmFilm), for the part of a panorama
/// invented; null when it does not tell it
typedef ConversionFocalReader = Future<int?> Function(ConversionSource source);

/// Reads it from the head of a JPEG of this computer, or of the copy the dialog made of a photo of a share; null for a
/// photo of the server, which would have to be copied first, and for another format
final conversionFocalReaderProvider = Provider<ConversionFocalReader>(
  (ref) => (source) async {
    final path = switch (source) {
      LocalFileSource(:final path) => path,
      ShareFileSource(:final copyPath) => copyPath,
      _ => null,
    };
    if (path == null) {
      return null;
    }
    final head = await readFileHead(path);
    if (head == null) {
      return null;
    }
    try {
      return exifFocalLength35mm(JpegHeader.read(head).exif);
    } on Object {
      // Not a JPEG, or one whose head is cut before its image: the main camera of a phone is taken
      return null;
    }
  },
);

/// Whether the GPano crop of a 360° photo leaves part of the sphere out, read from the head or the tail of a file of
/// this computer as the viewers read it (P1-review m3: the engine refuses such a photo, the dialog skips it before);
/// false for a photo of the server or of a share, which the engine checks once copied
typedef ConversionPartialSphereReader = Future<bool> Function(ConversionSource source);

final conversionPartialSphereReaderProvider = Provider<ConversionPartialSphereReader>(
  (ref) => (source) async {
    if (source is! LocalFileSource) {
      return false;
    }
    try {
      final crop = (await readGPanoFile(File(source.path)))?.crop;
      return crop != null && isPartialSphere(crop);
    } on Object {
      // Unreadable now: the engine reads it again
      return false;
    }
  },
);

/// What reading the file of a photo of this computer tells of it as a 360° photo, the way the scan of the device reads
/// it (see probeLocalPanoramaFile): its GPano projection, the trailer of an Insta360 camera that tells a raw photo
/// renamed .jpg from one the camera stitched, the exif of a 360° camera. Null for a photo of the server or of a share,
/// and for a file that cannot be read now. The dialog reads it for a photo taken by its 2:1 frame alone, whose file the
/// scan may not have reached yet (fix-stereo-360-pc review, m3).
typedef ConversionFileProbe = Future<LocalPanoramaProbe?> Function(ConversionSource source, BaseAsset asset);

final conversionFileProbeProvider = Provider<ConversionFileProbe>(
  (ref) => (source, asset) async {
    if (source is! LocalFileSource) {
      return null;
    }
    try {
      return await probeLocalPanoramaFile(source.path, isVideo: false, width: asset.width, height: asset.height);
    } on Object catch (error) {
      _log.fine('${asset.name} could not be read for a 360° projection: $error');
      return null;
    }
  },
);

/// The features a choice of the dialog needs: that of [kind], and that of the 3D version of a panorama chained after it
typedef AiChoiceFeatures = ({AiFeature feature, AiFeature? chained});

/// The free space of the drive of the AI components, and what installing the components a choice lacks takes there
typedef AiInstallSpace = ({AiFreeSpace? space, AiSpaceShortage? shortage});

/// See [AiInstallSpace]; null while nothing is missing, or where the free space is not read
final aiInstallSpaceProvider = FutureProvider.autoDispose.family<AiInstallSpace?, AiChoiceFeatures>((
  ref,
  choice,
) async {
  final reader = ref.watch(aiFreeSpaceProvider);
  final chained = choice.chained;
  final lacking = [
    ...(await ref.watch(aiGateResultForProvider(choice.feature).future)).missing,
    if (chained != null) ...(await ref.watch(aiGateResultForProvider(chained).future)).missing,
  ];
  // A component two features share counts once
  final missing = [
    for (final (index, component) in lacking.indexed)
      if (lacking.indexWhere((other) => other.id == component.id) == index) component,
  ];
  if (reader == null || missing.isEmpty) {
    return null;
  }
  final shortage = await ref.watch(aiComponentsServiceProvider).spaceShortage(missing);
  final space = await reader(await ref.watch(aiComponentsFolderProvider)());
  return (space: space, shortage: shortage);
});

/// The folder the AI components were moved to when its drive cannot be reached now (unplugged): the components then
/// read as not installed and a download would fail to write, so the screens say why; null otherwise
final aiComponentsFolderMissingProvider = FutureProvider.autoDispose<String?>((ref) async {
  final moved = (await ref.watch(desktopAiSettingsStoreProvider).read()).componentsFolder;
  if (moved == null) {
    return null;
  }
  // Only the folder gone with its parent: a folder deleted by hand on a drive still there is made again by a download
  return Directory(moved).existsSync() || Directory(p.dirname(moved)).existsSync() ? null : moved;
});

/// Whether the gate refuses for a reason the dialog cannot mend: anything but components to install
bool aiGateRefuses(AiGateResult? gate) =>
    gate != null &&
    !gate.isAvailable &&
    gate.reason != AiGateReason.componentsMissing &&
    gate.reason != AiGateReason.componentsDamaged;

/// The words of a refusal of the gate
String aiGateReasonText(Translations t, AiGateResult gate) => switch (gate.reason) {
  null => '',
  AiGateReason.system => t.ai_immersive_unavailable_system,
  AiGateReason.processor => t.ai_immersive_unavailable_arm,
  AiGateReason.memory => t.ai_immersive_unavailable_memory,
  AiGateReason.componentsMissing => t.ai_immersive_unavailable_missing,
  AiGateReason.componentsDamaged => t.ai_immersive_unavailable_damaged,
  AiGateReason.runtimeFailed => t.ai_immersive_failed_model(message: gate.message ?? ''),
  AiGateReason.notHere => t.ai_immersive_unavailable_system,
  AiGateReason.notInThisVersion => t.ai_immersive_unavailable_build,
  AiGateReason.notYetOnMac => t.ai_immersive_gpu_not_on_mac,
  AiGateReason.panoramaMemory => t.ai_immersive_gpu_memory(
    needed: formatBytes(gate.memoryNeeded ?? 0),
    memory: formatBytes(gate.physicalMemory ?? 0),
  ),
  AiGateReason.gpuNone => t.ai_immersive_gpu_none,
  AiGateReason.gpuNoAnswer => t.ai_immersive_gpu_no_answer,
  AiGateReason.gpuIntegrated => t.ai_immersive_gpu_integrated,
  AiGateReason.gpuTooSmall => t.ai_immersive_gpu_too_small(
    memory: formatBytes(gate.graphicsMemory ?? 0),
    needed: formatBytes(gate.graphicsMemoryNeeded ?? 0),
  ),
};

/// The words of a reason to skip a photo
String conversionSkipText(Translations t, ConversionSkipReason reason, {String? name}) => switch (reason) {
  ConversionSkipReason.video => t.ai_immersive_skipped_video,
  ConversionSkipReason.sphere360 => t.ai_immersive_skipped_360,
  ConversionSkipReason.vr180 => t.ai_immersive_skipped_vr180,
  ConversionSkipReason.spatial => t.ai_immersive_skipped_spatial,
  ConversionSkipReason.alreadyStereo => t.ai_immersive_skipped_3d,
  ConversionSkipReason.alreadyVersion => t.ai_immersive_skipped_ai_version,
  ConversionSkipReason.notSphere => t.ai_immersive_skipped_not_360,
  ConversionSkipReason.raw360 => t.ai_immersive_skipped_raw_360,
  ConversionSkipReason.unreadableFormat => t.ai_immersive_unavailable_format,
  ConversionSkipReason.sameSettingsExists => t.ai_immersive_skipped_same_settings,
  ConversionSkipReason.nameTaken => t.ai_immersive_exists(name: name ?? ''),
  ConversionSkipReason.unreachable => t.ai_immersive_failed_source,
  ConversionSkipReason.diskFull => t.ai_immersive_failed_disk_full,
  ConversionSkipReason.parentNotMade => t.ai_immersive_skipped_parent,
};

/// What the dialog needs to know of a photo before anything runs: whether it is shown as a sphere (a raw one of a 360°
/// camera, its lenses not stitched, among them), holds two eyes already, is one of the versions the app made and of
/// which kind, is an Apple spatial photo, how many quarter turns the user sees it with, whether Immich holds edits of
/// it that its original lacks, and the coverage of the sphere the user picked for it in a 360° viewer
class ConversionPhotoFacts {
  const ConversionPhotoFacts({
    this.isPanorama = false,
    this.isRaw360 = false,
    this.isStereo = false,
    this.version,
    this.isSpatial = false,
    this.quarterTurns = 0,
    this.serverEdits = false,
    this.partialSphere = false,
    this.coverage,
  });

  final bool isPanorama;

  /// A raw photo of a 360° camera (an Insta360 .insp), its two lenses not stitched: a sphere for the viewers, no
  /// equirectangular picture for a conversion
  final bool isRaw360;

  /// Two eyes: side by side by its name and frame, by our XMP in its head (see flatStereoProvider), or a version of
  /// ours that holds two (see versionHoldsTwoEyes)
  final bool isStereo;

  /// What the library knows of it when the app made it, null for any other photo
  final IndexedVersion? version;
  final bool isSpatial;

  /// The turns the viewer draws, plus those of the rotation saved in the edits of Immich: the original is unedited
  final int quarterTurns;

  /// Edited in Immich: what the viewer shows is the edited picture, the 3D photo is made from the unedited original
  /// (a file of the library or the original of the server), the rotation alone applied
  final bool serverEdits;

  /// A 360° photo whose GPano crop leaves part of the sphere out (a phone panorama of 180° x 90° in a 2:1 frame): it
  /// has no sphere to go around for its 3D version. Read by the dialog from the file, once it knows where it is.
  final bool partialSphere;

  /// The coverage of the sphere the user picked for it in a 360° viewer (sphereCoverageOverrideProvider), which wins
  /// over the guess from its name as it does in the viewers; null when the user never picked one
  final SphereCoverage? coverage;

  /// The same facts, of a photo whose GPano crop leaves part of the sphere out or not
  ConversionPhotoFacts withPartialSphere(bool partial) => _copy(partialSphere: partial);

  /// The same facts, with what reading its file told the way the scan of the device reads it (see
  /// conversionFileProbeProvider): a 360° projection, or the trailer of a raw Insta360 photo
  ConversionPhotoFacts withFileRead({required bool isPanorama, required bool isRaw360}) =>
      _copy(isPanorama: isPanorama, isRaw360: isRaw360);

  ConversionPhotoFacts _copy({bool? isPanorama, bool? isRaw360, bool? partialSphere}) => ConversionPhotoFacts(
    isPanorama: isPanorama ?? this.isPanorama,
    isRaw360: isRaw360 ?? this.isRaw360,
    isStereo: isStereo,
    version: version,
    isSpatial: isSpatial,
    quarterTurns: quarterTurns,
    serverEdits: serverEdits,
    partialSphere: partialSphere ?? this.partialSphere,
    coverage: coverage,
  );
}

/// Reads the facts of a photo
typedef ConversionFactsReader = Future<ConversionPhotoFacts> Function(BaseAsset asset);

/// How long the facts of a photo may wait for its exif or its stereo check
const _factsWait = Duration(seconds: 10);

/// The facts as the viewers know them: the 360° rules, the index of the library and the rule of the name and frame
/// for two eyes side by side, our XMP in the head of a photo those rules leave flat (as the viewer of a computer reads
/// it to show it in 3D), the Apple spatial probe for a HEIF photo, the turns the viewer draws and the rotation of the
/// edits of Immich, and the coverage of the sphere the user picked. The providers that read a file are listened to
/// while they do, so that they live until they answer. Outside the viewer nothing else keeps the turns and the 360° rules: read at once they would say "no turn"
/// and "flat" while the exif of a photo of the server, or the stereo check of a HEIF one, still loads; so they are
/// listened to from the start and read once those answered.
final conversionFactsReaderProvider = Provider<ConversionFactsReader>((ref) {
  Future<T> answer<T>(ProviderListenable<Future<T>> provider) async {
    final subscription = ref.listen(provider, (_, _) {});
    try {
      return await subscription.read();
    } finally {
      subscription.close();
    }
  }

  return (asset) async {
    final turns = ref.listen(displayQuarterTurnsProvider(asset), (_, _) {});
    final panorama = ref.listen(isPanoramaProvider(asset), (_, _) {});
    final raw = ref.listen(rawMediaKindProvider(asset), (_, _) {});
    try {
      final localId = asset.localId;
      var versions = const <String, IndexedVersion>{};
      try {
        versions = await answer(generatedVersionsProvider.future);
      } catch (error) {
        _log.fine('The versions of the library are not known: $error');
      }
      final version = localId == null ? null : versions[localId];
      var isStereo =
          (version != null && versionHoldsTwoEyes(version)) ||
          decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) != null;
      String? make;
      if (asset.hasRemote) {
        try {
          make = (await answer(assetExifProvider(asset).future).timeout(_factsWait))?.make;
        } catch (error) {
          _log.fine('The exif of ${asset.name} is not known: $error');
        }
      }
      var isSpatial = false;
      if (asset.isImage && isHeifName(asset.name) && !Platform.isLinux) {
        try {
          isSpatial = (await answer(appleSpatialInfoProvider(asset).future).timeout(_factsWait))?.photo != null;
        } catch (error) {
          _log.fine('${asset.name} could not be read for a spatial photo: $error');
        }
      }
      final isPanorama = panorama.read();
      // One of our 3D photos renamed, which only our XMP tells: its head is read as the viewer reads it
      if (!isStereo && !isPanorama && FlatStereoService.isCandidate(asset)) {
        try {
          isStereo = await answer(flatStereoProvider(asset).future).timeout(_factsWait) != null;
        } catch (error) {
          _log.fine('${asset.name} could not be read for two eyes side by side: $error');
        }
      }
      final remoteId = asset.remoteId;
      final serverEdits = asset.isEdited && remoteId != null;
      var editTurns = 0;
      if (serverEdits) {
        try {
          editTurns = quarterTurnsOfEdits(await ref.read(viewRotationServerProvider).edits(remoteId));
        } catch (error) {
          _log.warning('The edits of ${asset.name} could not be read: $error');
        }
      }
      final scanned = fileReadByScan(
        asset,
        library: ref.read(localPanoramaAssetsProvider),
        opened: ref.read(openedFilePanoramasProvider),
      );
      return ConversionPhotoFacts(
        isPanorama: isPanorama,
        isRaw360: raw.read() != null || (!isPanorama && !scanned && mayBeRawInsta360(make)),
        isStereo: isStereo,
        version: version,
        isSpatial: isSpatial,
        quarterTurns: normalizeQuarterTurns(turns.read() + editTurns),
        serverEdits: serverEdits,
        coverage: ref.read(sphereCoverageOverridesProvider.notifier).get(asset),
      );
    } finally {
      turns.close();
      panorama.close();
      raw.close();
    }
  };
});

/// Where the original of a photo of the app is for a conversion; the tests give their own
abstract interface class ConversionAssetFiles {
  /// The original of [asset] and the source its job reads, null when this computer cannot reach it
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset);
}

/// A file opened with the program, a file of the folder library, or the original of a photo of the server.
/// [library], [endpoint] and [opened] are the folder library of the window, the address of the server signed in, and
/// the files opened with the program; the tests give theirs.
class DesktopConversionAssetFiles implements ConversionAssetFiles {
  const DesktopConversionAssetFiles({
    this.library = FolderLibrary.shared,
    this.endpoint = _serverEndpoint,
    this.opened = OpenedFiles.file,
  });

  final Future<FolderLibrary> Function() library;
  final String? Function() endpoint;
  final LibraryFile? Function(String assetId) opened;

  static String? _serverEndpoint() => Store.tryGet(StoreKey.serverEndpoint);

  @override
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset) async {
    final localId = asset.localId;
    if (localId != null) {
      final opened = this.opened(localId);
      if (opened != null) {
        return (
          location: OpenedOriginal(name: opened.name, path: opened.path),
          source: LocalFileSource(opened.path, exif: _exifOf(asset)),
        );
      }
      try {
        final library = await this.library();
        final original = LibraryOriginal.of(library, localId);
        if (original != null && (library.file(localId)?.available ?? false)) {
          return (location: original, source: LocalFileSource(original.path, exif: _exifOf(asset)));
        }
      } catch (error, stack) {
        _log.warning('The file of ${asset.name} is not found in the library', error, stack);
      }
    }
    final remoteId = asset.remoteId;
    final endpoint = this.endpoint();
    if (remoteId == null || endpoint == null) {
      return null;
    }
    return (
      location: ServerOriginal(name: asset.name),
      source: ServerOriginalSource(
        name: asset.name,
        remoteId: remoteId,
        endpoint: endpoint,
        exif: _exifOf(asset),
        fetch: (url) => NetworkRepository.client.send(http.Request('GET', url)..headers.addAll(_headers())),
      ),
    );
  }

  static Map<String, String> _headers() => ApiService.getRequestHeaders();
}

/// The date of a photo that is not a JPEG for its 3D photo: the engine reads the EXIF of a JPEG itself, nothing reads
/// that of a HEIC or a PNG in phase 1
ImmersiveExif _exifOf(BaseAsset asset) => conversionExifOf(asset.name, asset.createdAt);

/// The fields a version keeps from the photo named [name], taken at [date]: none for a JPEG, whose EXIF the engine
/// reads itself; its date, in the time of this computer, for another format
ImmersiveExif conversionExifOf(String name, DateTime date) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return const ImmersiveExif();
  }
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return ImmersiveExif(
    dateTimeOriginal:
        '${local.year}:${two(local.month)}:${two(local.day)} ${two(local.hour)}:${two(local.minute)}:'
        '${two(local.second)}',
  );
}

final conversionAssetFilesProvider = Provider<ConversionAssetFiles>((ref) => const DesktopConversionAssetFiles());

/// The DestinationSession of a dialog (lot A5b); the tests give theirs
typedef DestinationSessionFactory =
    DestinationSession Function(List<DestinationJob> jobs, DesktopAiSettingsStore store);

final destinationSessionFactoryProvider = Provider<DestinationSessionFactory>((ref) {
  // The folders of a share opened in the app are checked through its writer (share_writer.dart)
  final shares = ref.watch(shareFolderProbeProvider);
  return (jobs, store) => DestinationSession(jobs, store: store, shareProbe: shares);
});

/// A photo of the selection as the dialog sees it
class ConversionCandidate {
  const ConversionCandidate({
    required this.asset,
    required this.source,
    this.location,
    this.skip,
    this.quarterTurns = 0,
    this.serverEdits = false,
    this.id,
    this.generated = false,
    this.byFrame = false,
  });

  final BaseAsset asset;
  final ConversionSource source;
  final OriginalLocation? location;
  final ConversionSkipReason? skip;
  final int quarterTurns;

  /// A panorama the app generated: its 3D version is said as generated too
  final bool generated;

  /// Taken for the 3D version of a 360° photo by its 2:1 frame alone, nothing in it flagging 360° (see
  /// isEquirectFrame): the plan names it, to be checked
  final bool byFrame;

  /// Edited in Immich: its edits, the rotation aside, are not in its 3D photo
  final bool serverEdits;

  /// Its id in the destination session of the dialog, null for a photo skipped
  final String? id;

  bool get runs => skip == null;
}

/// Whether a version of ours holds two eyes: a 3D photo, a 360° 3D panorama, and a version whose kind this build does
/// not know (or not read again since the index learnt the kinds), which is never made into another version either
bool versionHoldsTwoEyes(IndexedVersion version) => switch (version.kind) {
  ImmersiveKind.volumetricScene || ImmersiveKind.panorama360 => false,
  ImmersiveKind.stereoPhoto || ImmersiveKind.stereoPanorama360 || null => true,
};

/// The reason to skip [asset] for a version of [kind] known before anything runs, from its [facts], null when it is
/// converted. A 3D photo, a 3D scene and a 360° panorama are made from a flat photo; the 3D version of a 360° photo from
/// a 360° photo of a full sphere that holds one eye, a photo of the user or a panorama the app generated. A photo the
/// 360° rules leave flat is one for that type when its frame is that of a whole sphere (see [isEquirectFrame]): many
/// 360° photos carry no GPano tag (a stitcher, an editor, a download), and the user chose the type for it; the plan
/// says so under the type (see [ConversionCandidate.byFrame]). The coverage of the sphere is the one the user picked in a
/// 360° viewer, else the guess from the name and frame, as the viewers take it. [linux]: no decoder for HEIF and AVIF
/// there.
ConversionSkipReason? conversionSkipOf(
  BaseAsset asset,
  ConversionPhotoFacts facts, {
  ConversionKind kind = ConversionKind.sbsFromPhoto,
  bool? linux,
}) {
  if (asset.isVideo || !asset.isImage) {
    return ConversionSkipReason.video;
  }
  final halfSphere =
      (facts.coverage ?? guessSphereCoverage(fileName: asset.name, width: asset.width, height: asset.height)) ==
      SphereCoverage.half;
  if (kind == ConversionKind.stereoPanoramaFromPanorama) {
    if (!facts.isPanorama && !isEquirectFrame(asset.width, asset.height)) {
      return ConversionSkipReason.notSphere;
    }
    if (halfSphere) {
      return ConversionSkipReason.vr180;
    }
    if (facts.isRaw360) {
      // Two fisheye circles, no equirectangular picture to make a relief of
      return ConversionSkipReason.raw360;
    }
    if (facts.isStereo || guessStereoLayout(width: asset.width, height: asset.height) != StereoLayout.mono) {
      return ConversionSkipReason.alreadyStereo;
    }
    if (facts.version case final version? when version.kind != ImmersiveKind.panorama360) {
      return ConversionSkipReason.alreadyVersion;
    }
    if (!_fullSphereFrame(asset.width, asset.height) || facts.partialSphere) {
      // A partial panorama: its frame or its crop leaves no sphere to go around
      return ConversionSkipReason.notSphere;
    }
  } else {
    if (facts.isPanorama) {
      return halfSphere ? ConversionSkipReason.vr180 : ConversionSkipReason.sphere360;
    }
    if (facts.isStereo) {
      return ConversionSkipReason.alreadyStereo;
    }
    if (facts.version != null) {
      return ConversionSkipReason.alreadyVersion;
    }
  }
  if (facts.isSpatial) {
    return ConversionSkipReason.spatial;
  }
  if (isUnreadableHere(asset.name, linux: linux)) {
    return ConversionSkipReason.unreadableFormat;
  }
  return null;
}

/// Whether a photo the 360° rules leave flat, of the camera [make] its exif names, may be the raw photo of an Insta360
/// camera renamed .jpg: its stitched photos have the same make and the same 2:1 frame, and only the trailer of the
/// file, which the exif of the server does not hold, tells them apart (see hasEquirectCameraExifProvider). Its 3D
/// version is refused as a raw photo, two fisheye circles giving no relief, until the user views it as 360°. Asked
/// only while the scan of this computer has not read its file (see [fileReadByScan]): once it has, its trailer told.
bool mayBeRawInsta360(String? make) => make?.trim().toLowerCase() == 'arashi vision';

/// Whether the scan of this computer read the file of [asset]: a file of the library ([library], the records of
/// localPanoramaAssetsProvider) or one opened with the program ([opened]). What it found, a raw photo by the trailer
/// of an Insta360 camera included, is then in the 360° rules.
bool fileReadByScan(
  BaseAsset asset, {
  required Map<String, LocalPanoramaRecord> library,
  required Map<String, LocalPanoramaRecord> opened,
}) {
  final localId = asset.localId;
  return localId != null && (library.containsKey(localId) || opened.containsKey(localId));
}

/// Whether a photo of [width] x [height] that nothing flags 360° has the frame of a whole sphere: 2:1 within 1 %, as
/// a stitcher writes it, the rule the viewers take for the equirect photo of a 360° camera (isEquirectCameraPhoto);
/// false when the size is not known. A landscape screenshot of 19.5:9 or a 16:9 photo is none; an 18:9 phone photo or
/// screenshot, or two square eyes side by side under a plain name, has that frame too: the plan names each photo taken
/// so, to be checked (see [ConversionCandidate.byFrame]).
bool isEquirectFrame(int? width, int? height) => isSideBySideFrame(width, height) ?? false;

/// A frame of 2:1 within 10 %, an equirectangular picture of the whole sphere; true when the size is not known (the
/// engine checks the picture it decodes)
bool _fullSphereFrame(int? width, int? height) =>
    width == null || height == null || height <= 0 || (width / height - 2).abs() <= 0.2;

/// Whether a photo named [name] cannot be decoded on this system: HEIF and AVIF on Linux ([linux]), which has no
/// decoder for them
bool isUnreadableHere(String name, {bool? linux}) {
  final lower = name.toLowerCase();
  return (linux ?? Platform.isLinux) && (isHeifName(lower) || lower.endsWith('.avif'));
}

/// A source with a name only, for a photo skipped before it runs
class _SkippedSource implements ConversionSource {
  const _SkippedSource(this.name);

  @override
  final String name;

  @override
  String? get folder => null;

  @override
  ImmersiveExif get exif => const ImmersiveExif();

  @override
  Future<ImmersiveSource> prepare(_) => throw const ConversionException(ImmersiveErrorCode.sourceLost);

  @override
  Future<void> release() async {}
}

/// What the library knows of [asset] when the app made it, null for any other photo
IndexedVersion? _versionOf(Ref ref, BaseAsset asset) {
  final localId = asset.localId;
  return localId == null
      ? null
      : ref.watch(generatedVersionsProvider.select((versions) => versions.valueOrNull?[localId]));
}

/// Whether the viewer may offer "Make 3D (AI)" for [asset] to make a version of [kind]: a flat photo for a 3D photo, a
/// 3D scene and a 360° panorama ([aiFlatPhotoProvider]), a 360° photo that holds one eye for its 3D version
/// ([aiMonoPanoramaProvider])
final aiSourceProvider = Provider.autoDispose.family<bool, ({BaseAsset asset, ConversionKind kind})>(
  (ref, source) => switch (source.kind) {
    ConversionKind.sbsFromPhoto ||
    ConversionKind.sceneFromPhoto ||
    ConversionKind.panoramaFromPhoto => ref.watch(aiFlatPhotoProvider(source.asset)),
    ConversionKind.stereoPanoramaFromPanorama => ref.watch(aiMonoPanoramaProvider(source.asset)),
  },
);

/// Whether the viewer offers "Make 3D (AI)" for [asset]: a flat photo this system can read, neither 360°, nor two eyes
/// side by side, nor a version the app made, nor an Apple spatial photo (hidden until the check of a HEIF photo
/// answered)
final aiFlatPhotoProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  if (!asset.isImage || ref.watch(isPanoramaProvider(asset)) || isUnreadableHere(asset.name)) {
    return false;
  }
  if (_versionOf(ref, asset) != null ||
      decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) != null) {
    return false;
  }
  // One of our 3D photos renamed, which the viewer shows in 3D by our XMP: the plan skips it too
  if (FlatStereoService.isCandidate(asset) && ref.watch(flatStereoProvider(asset)).valueOrNull != null) {
    return false;
  }
  if (isHeifName(asset.name)) {
    final spatial = ref.watch(appleSpatialInfoProvider(asset));
    // A check that failed tells nothing: the entry stays
    if ((spatial.isLoading && !spatial.hasValue && !spatial.hasError) || spatial.valueOrNull?.photo != null) {
      return false;
    }
  }
  return true;
});

/// Whether [asset] may get its 3D version (design-final 2026-10-27, sections 4.4 and 9.1): a 360° photo of a full
/// sphere that holds one eye, of the user or a panorama the app generated, which this system can read; never a raw
/// photo of a 360° camera, a VR180 or 3D one, nor another version of ours. The rule of the dialog (conversionSkipOf)
/// with the facts the dialog reads (conversionFactsReaderProvider), so that the entry and the plan agree: a photo the
/// 360° rules leave flat whose frame is that of a whole sphere is one too, unless our XMP or its name tells two eyes,
/// or the user picked a half sphere for it in a 360° viewer.
final aiMonoPanoramaProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  if (!asset.isImage) {
    return false;
  }
  final version = _versionOf(ref, asset);
  final isPanorama = ref.watch(isPanoramaProvider(asset));
  final make = ref.watch(assetExifProvider(asset).select((exif) => exif.valueOrNull?.make));
  final localId = asset.localId;
  final scanned =
      localId != null &&
      (ref.watch(localPanoramaAssetsProvider.select((records) => records.containsKey(localId))) ||
          ref.watch(openedFilePanoramasProvider.select((records) => records.containsKey(localId))));
  final ours =
      !isPanorama && FlatStereoService.isCandidate(asset) && ref.watch(flatStereoProvider(asset)).valueOrNull != null;
  final facts = ConversionPhotoFacts(
    isPanorama: isPanorama,
    isRaw360: ref.watch(rawMediaKindProvider(asset)) != null || (!isPanorama && !scanned && mayBeRawInsta360(make)),
    isStereo:
        (version != null && versionHoldsTwoEyes(version)) ||
        decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) != null ||
        ours,
    version: version,
    coverage: ref.watch(sphereCoverageOverrideProvider(asset)),
  );
  return conversionSkipOf(asset, facts, kind: ConversionKind.stereoPanoramaFromPanorama) == null;
});

/// "Make 3D (AI)" for the photos of [source]: a menu item of the viewer, or a button of the bottom sheet of a
/// selection
class DesktopMakeImmersiveButton extends ConsumerWidget {
  const DesktopMakeImmersiveButton({super.key, required this.source, this.menuItem = false});

  final ActionSource source;
  final bool menuItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiFeaturesEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final assets = ref.watch(assetsActionProvider(source)).toList();
    if (!assets.any((asset) => asset.isImage)) {
      return const SizedBox.shrink();
    }
    // In the viewer, the types that take the photo shown; in a selection, every type, the dialog plans each photo
    final kinds = [
      for (final kind in ref.watch(offeredConversionKindsProvider))
        if (source != ActionSource.viewer || ref.watch(aiSourceProvider((asset: assets.first, kind: kind)))) kind,
    ];
    if (kinds.isEmpty) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    // Greyed only when the gate refuses every type, with the reason of the first
    final gates = [for (final kind in kinds) ref.watch(aiGateResultForProvider(aiFeatureOf(kind))).valueOrNull];
    final refusal = gates.every(aiGateRefuses) ? aiGateReasonText(t, gates.first!) : null;
    // Not waited for: the menu of the viewer closes at once, the dialog opens over the page
    void open() => unawaited(openConversionDialog(context, ref, assets, source: source));
    final Widget button = menuItem
        ? ImmichMenuItem(
            key: const Key('ai_make_3d'),
            icon: Icons.view_in_ar_outlined,
            label: t.ai_immersive_make_3d,
            onPressed: open,
            disabled: refusal != null,
          )
        : ImmichColumnButton(
            key: const Key('ai_make_3d'),
            icon: Icons.view_in_ar_outlined,
            label: t.ai_immersive_make_3d,
            onPressed: open,
            disabled: refusal != null,
          );
    return refusal == null ? button : Tooltip(key: const Key('ai_make_3d_refused'), message: refusal, child: button);
  }
}

/// The [actions] of the bottom sheet of a selection, with "Make 3D (AI)" on a computer
List<Widget> withDesktopSelectionActions(List<Widget> actions) => [
  ...actions,
  if (CurrentPlatform.isDesktop) const DesktopMakeImmersiveButton(source: ActionSource.timeline),
];

/// Opens the conversion dialog for [assets], on the type [kind] when it takes one of them ("Make the 3D version" of a
/// panorama); once photos were handed to the queue, the panel of the conversions shows and the selection ends
Future<void> openConversionDialog(
  BuildContext context,
  WidgetRef ref,
  List<BaseAsset> assets, {
  ActionSource source = ActionSource.viewer,
  ConversionKind? kind,
}) async {
  final clearSelection = ref.read(clearSelectionProvider(source));
  // The menu that opened the dialog may be gone when it closes: the panel opens from the navigator
  final navigator = Navigator.of(context, rootNavigator: true);
  final launched = await showDialog<bool>(
    context: context,
    builder: (context) => ConversionDialog(assets: assets, kind: kind),
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
class ConversionDialog extends ConsumerStatefulWidget {
  const ConversionDialog({super.key, this.assets = const [], this.kind, this.shareFiles = const []});

  final List<BaseAsset> assets;

  /// The files of a share opened in the app it is opened on instead of [assets] (share_conversion.dart): each photo is
  /// copied once through the media bridge as the dialog opens, and its facts read from that copy
  final List<NetworkEntry> shareFiles;

  /// The type to start with when this build makes it and it takes a photo, before the one chosen last
  final ConversionKind? kind;

  @override
  ConsumerState<ConversionDialog> createState() => _ConversionDialogState();
}

/// A photo of the selection as the dialog read it once: what it is, and where its original is (null when this computer
/// cannot reach it, or when no type takes it)
class _Photo {
  const _Photo(this.asset, this.facts, this.found, {this.missing = ConversionSkipReason.unreachable});

  final BaseAsset asset;
  final ConversionPhotoFacts facts;
  final ({OriginalLocation location, ConversionSource source})? found;

  /// Why it is skipped when [found] is null: its original cannot be reached, or there was no room for its copy
  final ConversionSkipReason missing;
}

/// For each job of [ids], the index of the request it came from: a panorama is followed by the 3D version chained
/// after it (its parentId), which comes from the same request
List<int> requestIndexOfJobs(List<String> ids, ConversionQueueState queue) {
  final indexes = <int>[];
  var index = -1;
  for (final id in ids) {
    if (queue.byId(id)?.parentId == null) {
      index++;
    }
    indexes.add(index);
  }
  return indexes;
}

class _ConversionDialogState extends ConsumerState<ConversionDialog> {
  late final DesktopAiSettingsStore _store = ref.read(desktopAiSettingsStoreProvider);
  List<_Photo>? _photos;
  List<ConversionCandidate>? _candidates;
  DestinationSession? _session;
  DesktopAiSettings _settings = const DesktopAiSettings();
  ExistingVersionChoice _existing = ExistingVersionChoice.skip;
  AiDestination _saveTo = AiDestination.nextToOriginal;

  /// The types this build makes, read as the dialog opens, and the one chosen
  List<ConversionKind> _offered = const [ConversionKind.sbsFromPhoto];
  ConversionKind _kind = ConversionKind.sbsFromPhoto;

  /// "Also make the 3D version" of each panorama, as kept in desktop_ai.json
  var _alsoStereo = true;

  /// The part of the panoramas of the selection the AI invents, in percent, the smallest of them; null until read
  int? _invented;

  /// The question asked on battery is open
  var _asking = false;

  /// What the user changed in this dialog, which holds when the type changes: "Save to", the folder chosen with
  /// Change, the network folders answered No
  var _saveToChosen = false;
  String? _folderChosen;
  final _declined = <String>{};

  /// False while the album of the generated photos is not out of the backup: no folder of the library then
  var _libraryReady = true;
  var _gestures = 0;
  var _plannings = 0;
  var _launched = false;
  var _closed = false;

  /// The copy of the photos of a share under way: which photo, of how many, and its bytes copied of their total
  ({int index, int count, String name, int copied, int? total})? _copying;

  /// The copies of the photos of a share this dialog made; those no job takes are deleted as it closes or launches
  final _shareSources = <ShareFileSource>[];

  /// The photos are being read (or copied from their share): their copies are deleted once that ends
  var _reading = false;

  Iterable<ConversionCandidate> get _runs => _candidates?.where((candidate) => candidate.runs) ?? const [];

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _close();
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
    // A copy under way stops at its next bytes, and its photos are deleted once the reading ends
    if (!_launched && !_reading) {
      _releaseShareSources();
    }
  }

  /// Deletes the copies of the photos of a share no job took
  void _releaseShareSources({Set<ConversionSource> kept = const {}}) {
    for (final source in _shareSources) {
      if (!kept.contains(source)) {
        unawaited(source.release());
      }
    }
    _shareSources.clear();
  }

  int get _count => widget.shareFiles.isNotEmpty ? widget.shareFiles.length : widget.assets.length;

  Future<void> _prepare() async {
    _settings = await _store.read();
    _existing = _settings.skipExisting ? ExistingVersionChoice.skip : ExistingVersionChoice.newVersion;
    _alsoStereo = _settings.alsoStereoPanorama;
    _offered = ref.read(offeredConversionKindsProvider);
    _reading = true;
    List<_Photo>? photos;
    try {
      photos = widget.shareFiles.isEmpty ? await _readAssets() : await _readShareFiles();
    } finally {
      _reading = false;
    }
    if (!mounted || _closed || photos == null) {
      if (!_launched) {
        _releaseShareSources();
      }
      return;
    }
    _photos = photos;
    _kind = _initialKind();
    await _plan();
  }

  /// The photos of the app the dialog was opened on, as it reads them once
  Future<List<_Photo>> _readAssets() async {
    final facts = ref.read(conversionFactsReaderProvider);
    final files = ref.read(conversionAssetFilesProvider);
    final partial = ref.read(conversionPartialSphereReaderProvider);
    final probe = ref.read(conversionFileProbeProvider);
    final photos = <_Photo>[];
    for (final asset in widget.assets) {
      var known = await facts(asset);
      final taken = _offered.any((kind) => conversionSkipOf(asset, known, kind: kind) == null);
      final found = taken ? await files.locate(asset) : null;
      final byFrame = !known.isPanorama && isEquirectFrame(asset.width, asset.height);
      // One taken by its frame for its 3D version, which the scan may not have read yet: its file says what the scan
      // would, a GPano projection or the trailer of a raw Insta360 photo, over the make the server gives
      if (found != null && byFrame) {
        if (await probe(found.source, asset) case final read?) {
          known = known.withFileRead(isPanorama: read.isPanorama, isRaw360: read.raw360);
        }
      }
      // A 360° photo, or one taken by its frame: its GPano crop may leave part of the sphere out
      if (found != null && (known.isPanorama || byFrame)) {
        known = known.withPartialSphere(await partial(found.source));
      }
      photos.add(_Photo(asset, known, found));
    }
    return photos;
  }

  /// The files of a share the dialog was opened on: each photo copied once through the media bridge, its name and its
  /// bytes shown meanwhile, then its facts read from that copy; a video is not copied, the plan skips it. A photo whose
  /// copy fails cannot be reached; once a copy finds no room on this computer, that photo and the ones after it are
  /// skipped with "Disk full", without trying their copies. Null once the dialog closed meanwhile (Cancel): the copy
  /// under way stops.
  Future<List<_Photo>?> _readShareFiles() async {
    final make = ref.read(shareConversionSourceProvider);
    final read = ref.read(shareCopyFactsReaderProvider);
    // A share that takes files has its versions next to their originals (destination.dart); a media server has not
    final folderOf = ref.read(shareFolderOfProvider);
    // The turns the page of a share shows each photo with; none when they cannot be read, as in its viewer
    var rotations = const <String, ViewRotationEntry>{};
    try {
      rotations = ref.read(viewRotationsProvider);
    } catch (error) {
      _log.fine('The turns of the photos of the share are not known: $error');
    }
    final files = widget.shareFiles;
    final photos = <_Photo>[];
    var full = false;
    for (final (index, entry) in files.indexed) {
      if (_closed) {
        return null;
      }
      if (!entry.isImage) {
        photos.add(_Photo(shareConversionAsset(entry), const ConversionPhotoFacts(), null));
        continue;
      }
      if (full) {
        photos.add(
          _Photo(
            shareConversionAsset(entry),
            const ConversionPhotoFacts(),
            null,
            missing: ConversionSkipReason.diskFull,
          ),
        );
        continue;
      }
      final source = make(entry);
      _shareSources.add(source);
      void show(int copied, int? total) {
        if (mounted && !_closed) {
          setState(
            () => _copying = (index: index, count: files.length, name: entry.name, copied: copied, total: total),
          );
        }
      }

      show(0, entry.size);
      try {
        final copy = await source.copy(isCancelled: () => _closed, onProgress: show);
        final turns = viewRotationShareTurnsOf(
          rotations,
          entry.sourceId,
          entry.path,
          size: entry.size,
          modifiedMs: entry.modified?.millisecondsSinceEpoch,
        );
        final known = await read(entry, copy, quarterTurns: turns);
        source.exif = known.exif;
        photos.add(
          _Photo(shareConversionAsset(entry, width: known.width, height: known.height), known.facts, (
            location: ShareOriginal(name: entry.name, folder: folderOf(entry)),
            source: source,
          )),
        );
      } on Object catch (error) {
        if (_closed) {
          return null;
        }
        _log.warning('${entry.name} could not be copied from its share: $error');
        _shareSources.remove(source);
        unawaited(source.release());
        full = error is ConversionException && error.code == ImmersiveErrorCode.diskFull;
        photos.add(
          _Photo(
            shareConversionAsset(entry),
            const ConversionPhotoFacts(),
            null,
            missing: full ? ConversionSkipReason.diskFull : ConversionSkipReason.unreachable,
          ),
        );
      }
    }
    if (mounted && !_closed) {
      setState(() => _copying = null);
    }
    return photos;
  }

  /// The type asked for, then the type chosen last, when this build makes it and it takes a photo of the selection;
  /// else the first that takes one
  ConversionKind _initialKind() {
    final asked = _offered.where((kind) => kind == widget.kind).firstOrNull;
    final kept = _offered.where((kind) => kind.name == _settings.lastType).firstOrNull;
    bool takes(ConversionKind kind) => _photos!.any((photo) => _skipOf(photo, kind) == null);
    return [?asked, ?kept, ..._offered].where(takes).firstOrNull ?? kept ?? _offered.first;
  }

  /// The features the choice needs: those of the type, and those of the 3D version chained after a panorama
  AiChoiceFeatures get _choiceFeatures => (
    feature: aiFeatureOf(_kind),
    chained: _kind == ConversionKind.panoramaFromPhoto && _alsoStereo ? AiFeature.stereoPanorama : null,
  );

  /// Reads the part invented of the panoramas of [candidates], the largest of them, so that the sentence never says
  /// less than a panorama of the selection invents, for the planning [planning]
  Future<void> _readInvented(List<ConversionCandidate> candidates, int planning) async {
    final focal = ref.read(conversionFocalReaderProvider);
    double? most;
    for (final candidate in candidates) {
      if (!candidate.runs) {
        continue;
      }
      int? focal35;
      try {
        focal35 = await focal(candidate.source);
      } catch (error) {
        _log.fine('The focal length of ${candidate.asset.name} is not known: $error');
      }
      final share = panoramaInventedShare(
        width: candidate.asset.width,
        height: candidate.asset.height,
        focal35: focal35,
      );
      most = most == null ? share : math.max(most, share);
    }
    if (most != null && mounted && !_closed && planning == _plannings) {
      setState(() => _invented = (most! * 100).round());
    }
  }

  /// Why [photo] is skipped for a version of [kind], null when it runs
  ConversionSkipReason? _skipOf(_Photo photo, ConversionKind kind) =>
      conversionSkipOf(photo.asset, photo.facts, kind: kind) ?? (photo.found == null ? photo.missing : null);

  List<ConversionCandidate> _candidatesFor(ConversionKind kind) => [
    for (final (index, photo) in _photos!.indexed)
      if (_skipOf(photo, kind) case final skip?)
        ConversionCandidate(asset: photo.asset, source: _SkippedSource(photo.asset.name), skip: skip)
      else
        ConversionCandidate(
          asset: photo.asset,
          source: photo.found!.source,
          location: photo.found!.location,
          quarterTurns: photo.facts.quarterTurns,
          serverEdits: photo.facts.serverEdits,
          id: 'photo-$index',
          generated: photo.facts.version?.kind == ImmersiveKind.panorama360,
          byFrame: kind == ConversionKind.stereoPanoramaFromPanorama && !photo.facts.isPanorama,
        ),
  ];

  /// Plans the selection for the type chosen: the photos it takes, a destination session for them (the one of the
  /// type before closed, its partial files deleted), its folders checked, then what the user changed in this dialog
  Future<void> _plan() async {
    final planning = ++_plannings;
    final kind = _kind;
    final candidates = _candidatesFor(kind);
    final earlier = _session;
    _session = null;
    if (earlier != null) {
      unawaited(earlier.close());
    }
    setState(() {
      _candidates = candidates;
      _invented = null;
    });
    if (kind == ConversionKind.panoramaFromPhoto) {
      unawaited(_readInvented(candidates, planning));
    }

    // No folder of the library is checked nor written into before the album of the versions is out of the backup
    final guard = ref.read(aiWriteGuardProvider);
    final libraryFolders = {
      for (final candidate in candidates)
        if (candidate.runs)
          if (candidate.location case LibraryOriginal(:final path)) p.dirname(path),
    };
    var libraryReady = true;
    for (final folder in libraryFolders) {
      if (!await guard(folder)) {
        libraryReady = false;
        break;
      }
    }

    final jobs = [
      for (final candidate in candidates)
        if (candidate.runs) DestinationJob(id: candidate.id!, original: candidate.location!, kind: kind.output),
    ];
    final session = jobs.isEmpty
        ? null
        : ref.read(destinationSessionFactoryProvider)(jobs, libraryReady ? _store : _ChosenFolderStore(_store));
    if (!mounted || _closed || planning != _plannings) {
      if (session != null) {
        unawaited(session.close());
      }
      return;
    }
    setState(() {
      _session = session;
      _libraryReady = libraryReady;
      if (!_saveToChosen || !libraryReady) {
        _saveTo = libraryReady ? _settings.destination : AiDestination.folder;
      }
    });
    if (session == null) {
      return;
    }
    await _gesture(() async {
      await session.open();
      if (_saveToChosen) {
        await session.saveTo(_saveTo);
      }
      if (_folderChosen case final folder?) {
        await session.chooseFolder(folder);
      }
      for (final key in _declined) {
        await session.declineNetwork(key);
      }
    });
  }

  /// Another type chosen: the selection planned again for it
  void _choose(ConversionKind kind) {
    if (kind == _kind || _gestures > 0 || _launched || _photos == null) {
      return;
    }
    setState(() => _kind = kind);
    unawaited(_plan());
  }

  /// Runs a gesture of the destination session; Convert waits for it
  Future<void> _gesture(Future<void> Function() gesture) async {
    setState(() => _gestures++);
    try {
      await gesture();
    } catch (error, stack) {
      _log.warning('A gesture of the conversion dialog failed', error, stack);
    } finally {
      if (mounted) {
        setState(() => _gestures--);
      }
    }
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
      _folderChosen = picked;
      await _gesture(() => session.chooseFolder(picked!));
    }
  }

  Future<void> _setSaveTo(AiDestination destination) async {
    final session = _session;
    if (session == null || destination == _saveTo) {
      return;
    }
    setState(() {
      _saveTo = destination;
      _saveToChosen = true;
    });
    await _gesture(() => session.saveTo(destination));
  }

  /// Whether every photo that runs has a folder that may receive its version
  bool _ready(DestinationSession session) {
    if (session.pendingConsents.isNotEmpty) {
      return false;
    }
    for (final candidate in _runs) {
      final check = session.checkOf(candidate.id!);
      if (check == null || !check.accepted) {
        return false;
      }
    }
    return true;
  }

  Future<void> _convert(DestinationSession session) async {
    if (_launched || _asking) {
      return;
    }
    final kind = _kind;
    // A generation keeps the graphics card busy for minutes: on battery, asked first (design-final 2026-10-27, 4.7.5)
    if (kind.lane == ConversionLane.gpu && ref.read(aiPowerProbeProvider).onBattery() == true) {
      setState(() => _asking = true);
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('ai_conversion_battery'),
          content: Text(context.t.ai_immersive_battery_confirm),
          actions: [
            TextButton(
              key: const Key('ai_conversion_battery_cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.t.cancel),
            ),
            FilledButton(
              key: const Key('ai_conversion_battery_go'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t.ai_immersive_convert),
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
    final alsoStereo = kind == ConversionKind.panoramaFromPhoto && _alsoStereo;
    final candidates = _candidates!;
    final settings = await _store.read();
    final requests = <ConversionRequest>[];
    for (final candidate in candidates) {
      final plan = candidate.runs ? session.destinations[candidate.id] : null;
      // A version next to its original on a share is made here first, in a folder of its own, then put there
      var folder = plan?.folder;
      if (plan?.share != null) {
        try {
          folder = await ref.read(shareStagingFolderProvider)();
        } catch (error) {
          _log.warning('No folder to make the version of ${candidate.asset.name} in: $error');
          folder = null;
        }
      }
      requests.add(
        plan == null || folder == null
            ? ConversionRequest(source: candidate.source, skip: candidate.skip ?? ConversionSkipReason.unreachable)
            : ConversionRequest(
                source: candidate.source,
                target: ConversionTarget(
                  folder: folder,
                  fileName: versionTargetName(kind.output, candidate.location!.name),
                ),
                quarterTurns: candidate.quarterTurns,
              ),
      );
    }
    // The version of the app goes into each file
    await ref.read(aiAppVersionProvider.future);
    final output = ref.read(safeWriterOutputProvider);
    final ids = ref
        .read(conversionQueueProvider.notifier)
        .add(requests, kind: kind, existing: _existing, whenExists: settings.whenExists, alsoStereo: alsoStereo);
    // The copies of the photos of a share go with their jobs; those of the photos skipped go now
    _releaseShareSources(
      kept: {
        for (final request in requests)
          if (request.skip == null) request.source,
      },
    );
    final infos = <String, ConversionJobInfo>{};
    final shared = <String, ShareVersionTarget>{};
    final queue = ref.read(conversionQueueProvider);
    final requestOf = requestIndexOfJobs(ids, queue);
    for (final (index, id) in ids.indexed) {
      final candidate = candidates[requestOf[index]];
      final plan = candidate.id == null ? null : session.destinations[candidate.id];
      if (plan?.share case final folder?) {
        shared[id] = ShareVersionTarget(
          folder: folder,
          fallbackFolder: session.chosenFolder,
          skipWhenTaken: settings.whenExists == AiWhenExists.skip,
          withGlb: kind == ConversionKind.sceneFromPhoto && settings.exportGlb,
        );
      }
      // The partial file of the check goes to the job of the photo, never to a version chained after it
      final chained = queue.byId(id)?.parentId != null;
      final part = candidate.id == null || chained ? null : session.takePart(candidate.id!);
      if (part != null) {
        output.adopt(id, part);
      }
      infos[id] = ConversionJobInfo(
        // A photo of a share is no photo of the app: its row shows no thumbnail of the timeline
        asset: candidate.location is ShareOriginal ? null : candidate.asset,
        isNetwork: plan?.isNetwork ?? false,
        serverEdits: candidate.serverEdits,
        generatedSource: candidate.generated,
      );
    }
    ref.read(conversionJobInfoProvider.notifier).addAll(infos);
    ref.read(sharePublisherProvider.notifier).follow(shared);
    if (kind == ConversionKind.sceneFromPhoto && settings.exportGlb) {
      ref.read(sceneGlbCopiesProvider.notifier).follow(ids);
    }
    _close();
    final skipExisting = _existing == ExistingVersionChoice.skip;
    final stereoKept = kind == ConversionKind.panoramaFromPhoto ? _alsoStereo : settings.alsoStereoPanorama;
    if (settings.skipExisting != skipExisting ||
        settings.lastType != kind.name ||
        settings.alsoStereoPanorama != stereoKept) {
      unawaited(
        _store.update(
          (kept) =>
              kept.copyWith(skipExisting: skipExisting, lastType: () => kind.name, alsoStereoPanorama: stereoKept),
        ),
      );
    }
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final kind = _kind;
    final choice = _choiceFeatures;
    final feature = choice.feature;
    final features = [feature, ?choice.chained];
    final gates = [for (final each in features) ref.watch(aiGateResultForProvider(each))];
    final gate = gates.first;
    final candidates = _candidates;
    final session = _session;
    final found = gate.valueOrNull;
    final results = [for (final each in gates) each.valueOrNull];
    // The refusal of the type, else that of the 3D version chained after it
    final refusal = results.where(aiGateRefuses).firstOrNull;
    final refused = refusal != null;
    final known = results.every((result) => result != null);
    final available = known && results.every((result) => result!.isAvailable);
    final missing = known && !available && !refused;
    // The components being moved read as missing until the copy ends: nothing to download, Convert waits
    final moving = ref.read(aiComponentsServiceProvider).isMoving;
    final busy = _gestures > 0 || candidates == null || _asking;
    final canConvert = !busy && !moving && available && session != null && _ready(session);
    final count = _count;
    // Each type with the refusal of its gate, when it refuses
    final refusals = {
      for (final offered in _offered)
        offered: switch (ref.watch(aiGateResultForProvider(aiFeatureOf(offered))).valueOrNull) {
          final result? when aiGateRefuses(result) => aiGateReasonText(t, result),
          _ => null,
        },
    };
    final time = _runs.isEmpty ? null : conversionTimeText(t, kind, AiTimings(_settings.timings));

    return AlertDialog(
      key: const Key('ai_conversion_dialog'),
      title: Text(count > 1 ? t.ai_immersive_make_3d_count(count: count) : t.ai_immersive_make_3d),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_offered.length > 1) ...[_typeChoice(t, refusals), const SizedBox(height: 8)],
              Text(
                conversionKindHonesty(t, kind, generated: _runs.any((candidate) => candidate.generated)),
                key: const Key('ai_conversion_honesty'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (kind == ConversionKind.panoramaFromPhoto && _invented != null)
                _Note(
                  key: const Key('ai_conversion_invented'),
                  text: t.ai_immersive_invented_share(percent: _invented!),
                ),
              const SizedBox(height: 4),
              Text(t.ai_immersive_no_guarantee, style: Theme.of(context).textTheme.bodySmall),
              if (time != null) _Note(key: const Key('ai_conversion_time'), text: time),
              if (kind.lane == ConversionLane.gpu)
                _Note(key: const Key('ai_conversion_gpu_busy'), text: t.ai_immersive_gpu_busy_warning),
              if (kind == ConversionKind.panoramaFromPhoto)
                CheckboxListTile(
                  key: const Key('ai_conversion_also_stereo'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _alsoStereo,
                  title: Text(t.ai_immersive_also_stereo),
                  onChanged: busy || _launched ? null : (on) => setState(() => _alsoStereo = on ?? false),
                ),
              const SizedBox(height: 12),
              if (_copying case final copying?)
                _ShareCopyLine(key: const Key('ai_conversion_share_copy'), copying: copying)
              else if (gates.any((each) => each.isLoading) || candidates == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (refusal != null)
                _Note(key: const Key('ai_conversion_refused'), text: aiGateReasonText(t, refusal), error: true),
              if (moving)
                _Note(key: const Key('ai_conversion_moving'), text: t.ai_immersive_components_moving)
              else if (missing && found?.platform != null)
                Card(
                  key: const Key('ai_conversion_install'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AiInstallPanel(
                          // Another type, other components: the panel reads what is missing again
                          key: ValueKey('ai_conversion_install_${features.map((each) => each.name).join('_')}'),
                          components: _componentsOf(found!.platform!, features, results),
                          onInstalled: () {
                            for (final each in features) {
                              ref.invalidate(aiGateResultForProvider(each));
                            }
                          },
                        ),
                        _InstallSpace(choice: choice),
                      ],
                    ),
                  ),
                ),
              if (candidates != null && !refused) ...[
                if (session != null) ..._destination(t, session),
                if (session != null) ..._existingChoice(t, kind),
                if (_runs.any((candidate) => candidate.quarterTurns != 0))
                  _Note(key: const Key('ai_conversion_rotation'), text: t.ai_immersive_rotation_applied),
                if (_runs.any((candidate) => candidate.serverEdits))
                  _Note(key: const Key('ai_conversion_server_edits'), text: t.ai_immersive_server_edits_ignored),
                _PlanList(candidates: candidates, kindName: conversionKindName(t, kind)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ai_conversion_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.cancel),
        ),
        FilledButton(
          key: const Key('ai_conversion_convert'),
          onPressed: canConvert ? () => unawaited(_convert(session)) : null,
          child: Text(t.ai_immersive_convert),
        ),
      ],
    );
  }

  /// The components of [features] on [platform], each once, those of a panorama in the variant its card takes (the
  /// gate of each feature in [results])
  static List<AiComponent> _componentsOf(AiPlatform platform, List<AiFeature> features, List<AiGateResult?> results) {
    final components = <AiComponent>[];
    for (final (index, feature) in features.indexed) {
      for (final component in aiComponentsFor(
        platform,
        feature: feature,
        graphicsMemory: results[index]?.graphicsMemory,
      )) {
        if (!components.any((other) => other.id == component.id)) {
          components.add(component);
        }
      }
    }
    return components;
  }

  /// The types this build makes, each greyed with its reason when the gate refuses it
  Widget _typeChoice(Translations t, Map<ConversionKind, String?> refusals) => RadioGroup<ConversionKind>(
    key: const Key('ai_conversion_types'),
    groupValue: _kind,
    onChanged: (kind) {
      if (kind != null) {
        _choose(kind);
      }
    },
    child: Column(
      children: [
        for (final offered in _offered)
          RadioListTile<ConversionKind>(
            key: Key('ai_conversion_type_${offered.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: offered,
            enabled: refusals[offered] == null && _gestures == 0 && _photos != null,
            title: Text(conversionKindName(t, offered)),
            subtitle: refusals[offered] == null ? null : Text(refusals[offered]!),
          ),
      ],
    ),
  );

  List<Widget> _destination(Translations t, DestinationSession session) {
    final plans = session.destinations;
    // The folders the 3D photos go to, each with the reason it is not next to the original and its check
    final groups = <String, ({int count, String? reason, ProbeResult? check, bool shareHint, bool cloud})>{};
    for (final candidate in _runs) {
      final plan = plans[candidate.id];
      if (plan == null || plan.waitsForConsent) {
        continue;
      }
      final reason = destinationReasonText(t, plan.reason, message: plan.message);
      final earlier = groups[plan.folder];
      groups[plan.folder] = (
        count: (earlier?.count ?? 0) + 1,
        reason: earlier?.reason ?? reason,
        check: session.checkOf(candidate.id!),
        shareHint: (earlier?.shareHint ?? false) || plan.shareHint,
        cloud: (earlier?.cloud ?? false) || plan.cloudDownload,
      );
    }
    final hasLibraryOrOpened = _runs.any(
      (candidate) => switch (candidate.location) {
        LibraryOriginal() || OpenedOriginal() => true,
        // A share that takes files
        ShareOriginal(:final folder) => folder != null,
        _ => false,
      },
    );
    return [
      Text(t.ai_immersive_save_to, style: Theme.of(context).textTheme.titleSmall),
      if (hasLibraryOrOpened)
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
                key: const Key('ai_conversion_next_to_original'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: AiDestination.nextToOriginal,
                enabled: _libraryReady,
                title: Text(t.ai_immersive_next_to_original),
              ),
              RadioListTile<AiDestination>(
                key: const Key('ai_conversion_chosen_folder'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: AiDestination.folder,
                title: Text(t.ai_immersive_chosen_folder),
              ),
            ],
          ),
        ),
      if (!_libraryReady)
        _Note(key: const Key('ai_conversion_library_not_ready'), text: t.ai_immersive_library_not_ready),
      for (final MapEntry(key: folder, value: group) in groups.entries)
        _FolderLine(
          key: ValueKey('ai_conversion_folder_$folder'),
          folder: folder,
          count: _runs.length > 1 ? group.count : null,
          reason: group.reason,
          check: group.check,
          onChange: _gestures == 0 && plans.values.any((plan) => plan.kind == DestinationKind.chosenFolder)
              ? () => unawaited(_changeFolder())
              : null,
          shareHint: group.shareHint,
          cloud: group.cloud,
        ),
      for (final MapEntry(key: key, value: folder) in session.pendingConsents.entries)
        _NetworkQuestion(
          key: ValueKey('ai_conversion_network_$key'),
          folder: folder,
          onYes: _gestures == 0 ? () => unawaited(_gesture(() => session.allowNetwork(key))) : null,
          onNo: _gestures == 0
              ? () {
                  _declined.add(key);
                  unawaited(_gesture(() => session.declineNetwork(key)));
                }
              : null,
        ),
      const SizedBox(height: 8),
    ];
  }

  /// "If a 3D version exists" for a 3D photo, as in phase 1; "If a version exists" for the other types, each looked up
  /// by its own kind
  List<Widget> _existingChoice(Translations t, ConversionKind kind) => [
    Text(
      kind == ConversionKind.sbsFromPhoto ? t.ai_immersive_existing : t.ai_immersive_existing_version,
      style: Theme.of(context).textTheme.titleSmall,
    ),
    RadioGroup<ExistingVersionChoice>(
      groupValue: _existing,
      onChanged: (value) {
        if (value != null) {
          setState(() => _existing = value);
        }
      },
      child: Column(
        children: [
          for (final (choice, label) in [
            (
              ExistingVersionChoice.skip,
              kind == ConversionKind.sbsFromPhoto ? t.ai_immersive_existing_skip : t.ai_immersive_existing_skip_version,
            ),
            (ExistingVersionChoice.newVersion, t.ai_immersive_existing_new),
            (ExistingVersionChoice.replace, t.ai_immersive_existing_replace),
          ])
            RadioListTile<ExistingVersionChoice>(
              key: Key('ai_conversion_existing_${choice.name}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: choice,
              title: Text(label),
            ),
        ],
      ),
    ),
  ];
}

/// The settings of desktop_ai.json with "A folder of my choice" while the folders of the library may not be written
/// into: what is written stays what the user chose
class _ChosenFolderStore extends DesktopAiSettingsStore {
  _ChosenFolderStore(this._inner);

  final DesktopAiSettingsStore _inner;

  DesktopAiSettings _chosen(DesktopAiSettings settings) => settings.copyWith(destination: AiDestination.folder);

  @override
  Future<DesktopAiSettings> read() async => _chosen(await _inner.read());

  @override
  Future<void> write(DesktopAiSettings settings) => _inner.write(settings);

  @override
  Future<DesktopAiSettings> update(DesktopAiSettings Function(DesktopAiSettings settings) change) async =>
      _chosen(await _inner.update(change));
}

/// The copy of a photo of a share under way: "Copying salon.jpg from the share: 4.2 MiB of 12.0 MiB", "2 of 5" for a
/// selection, and its bar
class _ShareCopyLine extends StatelessWidget {
  const _ShareCopyLine({super.key, required this.copying});

  final ({int index, int count, String name, int copied, int? total}) copying;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final total = copying.total;
    final secondary = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.ai_immersive_share_copying(
              name: copying.name,
              done: formatBytes(copying.copied),
              all: total == null ? '…' : formatBytes(total),
            ),
          ),
          if (copying.count > 1)
            Text(
              t.ai_immersive_progress_count(index: copying.index + 1, total: copying.count),
              style: secondary,
            ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: total == null || total <= 0 ? null : (copying.copied / total).clamp(0, 1)),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(text, style: TextStyle(color: error ? colors.error : colors.onSurfaceVariant)),
    );
  }
}

/// A folder the 3D photos go to: its path, how many, why it is not next to the original, and Change for a folder of
/// my choice
class _FolderLine extends StatelessWidget {
  const _FolderLine({
    super.key,
    required this.folder,
    required this.count,
    required this.reason,
    required this.check,
    required this.onChange,
    required this.shareHint,
    required this.cloud,
  });

  final String folder;
  final int? count;
  final String? reason;
  final ProbeResult? check;
  final VoidCallback? onChange;
  final bool shareHint;
  final bool cloud;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = Theme.of(context).colorScheme;
    final check = this.check;
    final failure = check == null || check.accepted ? null : _checkText(t, check);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.folder_outlined, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(count == null ? folder : '$folder  ($count)'),
                if (reason case final reason?) Text(reason, style: TextStyle(color: colors.onSurfaceVariant)),
                if (failure != null) Text(failure, style: TextStyle(color: colors.error)),
                if (shareHint) Text(t.ai_immersive_share_hint, style: TextStyle(color: colors.onSurfaceVariant)),
                if (cloud) Text(t.ai_immersive_onedrive_download, style: TextStyle(color: colors.onSurfaceVariant)),
              ],
            ),
          ),
          if (onChange != null)
            TextButton(key: const Key('ai_conversion_change_folder'), onPressed: onChange, child: Text(t.change)),
        ],
      ),
    );
  }

  static String _checkText(Translations t, ProbeResult check) => switch (check.status) {
    ProbeStatus.readOnly => t.ai_immersive_failed_read_only,
    ProbeStatus.diskFull => t.ai_immersive_failed_disk_full,
    ProbeStatus.missing || ProbeStatus.failed => t.ai_immersive_failed_write(message: check.message ?? ''),
    ProbeStatus.ready || ProbeStatus.notChecked => '',
  };
}

/// "Save 3D photos in the folders of this network folder?" with Yes and No
class _NetworkQuestion extends StatelessWidget {
  const _NetworkQuestion({super.key, required this.folder, required this.onYes, required this.onNo});

  final String folder;
  final VoidCallback? onYes;
  final VoidCallback? onNo;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.ai_immersive_network_root_ask),
            const SizedBox(height: 4),
            SelectableText(folder, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('ai_conversion_network_no'),
                  onPressed: onNo,
                  child: Text(t.ai_immersive_network_root_no),
                ),
                FilledButton.tonal(
                  key: const Key('ai_conversion_network_yes'),
                  onPressed: onYes,
                  child: Text(t.ai_immersive_network_root_yes),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What will be done with each photo of the selection: for a mixed one, the photos the type makes, under its name;
/// the photos taken for the 3D version of a 360° photo by their 2:1 frame alone, to be checked; then the photos
/// skipped, each with why
class _PlanList extends StatelessWidget {
  const _PlanList({required this.candidates, required this.kindName});

  final List<ConversionCandidate> candidates;
  final String kindName;

  /// More than this many are counted, not listed
  static const _listed = 20;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final secondary = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final title = Theme.of(context).textTheme.titleSmall;
    final runs = candidates.where((candidate) => candidate.runs).toList();
    final byFrame = runs.where((candidate) => candidate.byFrame).toList();
    final skipped = candidates.where((candidate) => !candidate.runs).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (runs.isNotEmpty && skipped.isNotEmpty)
          Column(
            key: const Key('ai_conversion_made'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text('$kindName (${runs.length})', style: title),
              for (final candidate in runs.take(_listed)) Text(candidate.asset.name, style: secondary),
              if (runs.length > _listed) Text('…', style: secondary),
            ],
          ),
        if (byFrame.isNotEmpty)
          Column(
            key: const Key('ai_conversion_by_frame'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text('${t.ai_immersive_frame_only_360} (${byFrame.length})', style: title),
              for (final candidate in byFrame.take(_listed)) Text(candidate.asset.name, style: secondary),
              if (byFrame.length > _listed) Text('…', style: secondary),
            ],
          ),
        if (skipped.isNotEmpty)
          Column(
            key: const Key('ai_conversion_skipped'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text('${t.ai_immersive_state_skipped} (${skipped.length})', style: title),
              for (final candidate in skipped.take(_listed))
                Text('${candidate.asset.name}: ${conversionSkipText(t, candidate.skip!)}', style: secondary),
              if (skipped.length > _listed) Text('…', style: secondary),
            ],
          ),
      ],
    );
  }
}

/// Under the components to install: what the drive of the components lacks for them, else its free space; and the
/// folder they were moved to when its drive is not connected
class _InstallSpace extends ConsumerWidget {
  const _InstallSpace({required this.choice});

  final AiChoiceFeatures choice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final space = ref.watch(aiInstallSpaceProvider(choice)).valueOrNull;
    final unreachable = ref.watch(aiComponentsFolderMissingProvider).valueOrNull;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (unreachable != null)
          Text(
            t.ai_immersive_components_folder_missing(folder: unreachable),
            key: const Key('ai_conversion_folder_missing'),
            style: TextStyle(color: colors.error),
          )
        else if (space?.shortage case final shortage?)
          Text(
            aiSpaceShortageText(t, shortage),
            key: const Key('ai_conversion_space_short'),
            style: TextStyle(color: colors.error),
          )
        else if (space?.space case final free?)
          Text(
            t.ai_immersive_free_space(free: formatBytes(free.free), drive: free.volume),
            key: const Key('ai_conversion_free_space'),
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
      ],
    );
  }
}
