// What the dialog of a splat scene makes of a selection before anything runs (plan 2026-11-01, sections 2.1 and 4.1,
// lot SP7), in pure Dart so that it is tested without a screen: the refusals (fewer than SplatV1.minImages photos left,
// photos and a video together, several videos, a video under SplatV1.minVideo or over SplatV1.maxVideo, a 360° video,
// a video that cannot be reached), the photos left out with their reason (360°, unreadable here, already 3D, a version
// the app made, not reachable), SplatV1.maxPhotos photos at most spread evenly in time, the warning under
// SplatV1.fewImages photos, the lenses when the photos come from several, the name proposed and the folder the scene
// goes to (that of the photos when they share one, else the folder that holds the most), the frames a video gives, and
// the time on this computer.
//
// The blurred photos are not known here: they are found while the photos are prepared (lot SP5) and said at the end
// of the job.

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_time.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;

/// Why a photo of the selection is left out of the scene before anything runs, in the order the dialog says them
enum SplatLeftOutReason {
  /// A 360° or VR180 photo, or the raw photo of a 360° camera: not taken yet
  sphere360,

  /// A format this computer cannot read (HEIF and AVIF on Linux), or what is neither a photo nor a video
  unreadable,

  /// Two eyes already: a 3D photo, side by side or spatial
  threeD,

  /// A version the app made (a 3D scene, a panorama)
  aiVersion,

  /// Its original cannot be reached from this computer
  unreachable,
}

/// Why the dialog refuses the selection, before anything runs
enum SplatRefusal {
  /// Fewer than SplatV1.minImages photos left once those left out are counted
  tooFewPhotos,

  /// Photos and a video together
  mixed,

  /// More than one video
  severalVideos,

  /// A video shorter than SplatV1.minVideo
  videoShort,

  /// A video longer than SplatV1.maxVideo
  videoLong,

  /// A 360° video
  video360,

  /// The original of the video cannot be reached from this computer
  videoUnreachable,

  /// Neither a photo nor a video
  nothing,
}

/// A photo or a video of the selection as the dialog read it once
class SplatCandidate {
  const SplatCandidate({
    required this.asset,
    this.found,
    this.facts = const ConversionPhotoFacts(),
    this.isVideo360 = false,
    this.focal35,
  });

  final BaseAsset asset;

  /// Where its original is and the source its job reads, null when this computer cannot reach it
  final ({OriginalLocation location, ConversionSource source})? found;

  /// What the viewers know of a photo: 360°, two eyes, a version of ours, readable here
  final ConversionPhotoFacts facts;

  /// A video of a 360° camera, or one the user views as 360°
  final bool isVideo360;

  /// The focal length equivalent to 35 mm its EXIF tells, null when it does not or when it was not read
  final int? focal35;

  /// The same photo with the focal length read from its head
  SplatCandidate withFocal(int? focal35) =>
      SplatCandidate(asset: asset, found: found, facts: facts, isVideo360: isVideo360, focal35: focal35);
}

/// The plan of a selection for a splat scene, see the top of this file
class SplatSelectionPlan {
  const SplatSelectionPlan({
    this.used = const [],
    this.leftOut = const {},
    this.usable = 0,
    this.folders = 0,
    this.refusal,
    this.isVideo = false,
    this.videoDuration,
    this.lenses = const [],
    this.defaultName = '',
    this.destination,
  });

  /// What the scene is made from: the photos in the order of their time, SplatV1.maxPhotos at most, or the video
  final List<SplatCandidate> used;

  /// The photos left out, counted by reason in the order of [SplatLeftOutReason]
  final Map<SplatLeftOutReason, int> leftOut;

  /// The photos that could be used, before the cap of SplatV1.maxPhotos
  final int usable;

  /// The folders the photos used come from, the server counted as one
  final int folders;

  /// Null when the selection is taken
  final SplatRefusal? refusal;
  final bool isVideo;

  /// The length of the video, null for photos and for a video whose length is not known (null or 0 in its asset)
  final Duration? videoDuration;

  /// The lenses of the photos used (their focal lengths equivalent to 35 mm), the one that took the most first; empty
  /// when they all come from one
  final List<int> lenses;

  /// The name the dialog proposes: the folder of the photos when they share one (the share at the root of a share,
  /// see splatFolderName), else the first photo in time; the video without its extension
  final String defaultName;

  /// The photo, or the video, whose place the destination of the scene is planned for: one of the folder that holds
  /// the most photos (the first in time of them), the first photo when none is in a folder of this computer
  final SplatCandidate? destination;

  /// More photos could be used than a scene takes: SplatV1.maxPhotos of them, spread evenly in time
  bool get capped => !isVideo && usable > SplatV1.maxPhotos;

  /// Enough photos, but few: the scene may have holes
  bool get fewPhotos => refusal == null && !isVideo && usable < SplatV1.fewImages;

  /// The images the poses and the training work on: the photos used, or the frames the video gives
  int get images => isVideo ? splatVideoFrameCount(videoDuration ?? SplatV1.videoFramesUntil) : used.length;

  /// The same plan once the focal lengths of the photos used were read ([focals], in the order of [used], null where
  /// one was not read): their lenses. The dialog reads them for the photos used only, after the cap.
  SplatSelectionPlan withFocals(List<int?> focals) {
    assert(focals.length == used.length, 'One focal length per photo used');
    final read = [for (final (index, photo) in used.indexed) photo.withFocal(focals[index])];
    return SplatSelectionPlan(
      used: read,
      leftOut: leftOut,
      usable: usable,
      folders: folders,
      refusal: refusal,
      isVideo: isVideo,
      videoDuration: videoDuration,
      lenses: splatLensesOf(read),
      defaultName: defaultName,
      destination: destination,
    );
  }
}

/// The lenses of [photos] (their focal lengths equivalent to 35 mm), the one that took the most first; empty when they
/// all come from one, or when none is known
List<int> splatLensesOf(Iterable<SplatCandidate> photos) {
  final lenses = <int, int>{};
  for (final photo in photos) {
    if (photo.focal35 case final focal? when focal > 0) {
      lenses[focal] = (lenses[focal] ?? 0) + 1;
    }
  }
  final byUse = lenses.keys.toList()..sort((a, b) => lenses[b]!.compareTo(lenses[a]!));
  return byUse.length > 1 ? byUse : const [];
}

/// [items] when they are [max] at most, else [max] of them spread evenly, the first and the last kept, in their order
List<T> spreadEvenly<T>(List<T> items, int max) {
  if (items.length <= max) {
    return List.of(items);
  }
  if (max <= 1) {
    return max == 1 ? [items.first] : [];
  }
  return [for (var index = 0; index < max; index++) items[(index * (items.length - 1) / (max - 1)).round()]];
}

/// Why [candidate], a photo, is left out of a scene, null when it is used; [linux]: no decoder for HEIF and AVIF there
SplatLeftOutReason? splatLeftOutOf(SplatCandidate candidate, {bool? linux}) {
  final asset = candidate.asset;
  final facts = candidate.facts;
  if (!asset.isImage) {
    return SplatLeftOutReason.unreadable;
  }
  if (facts.isPanorama || facts.isRaw360) {
    return SplatLeftOutReason.sphere360;
  }
  if (isUnreadableHere(asset.name, linux: linux)) {
    return SplatLeftOutReason.unreadable;
  }
  if (facts.isStereo || facts.isSpatial) {
    return SplatLeftOutReason.threeD;
  }
  if (facts.version != null) {
    return SplatLeftOutReason.aiVersion;
  }
  if (candidate.found == null) {
    return SplatLeftOutReason.unreachable;
  }
  return null;
}

/// The folder of the original of [candidate] on this computer, null for an original of the server
String? _folderOf(SplatCandidate candidate, p.Context paths) => switch (candidate.found?.location) {
  LibraryOriginal(:final path) || OpenedOriginal(:final path) => paths.dirname(path),
  _ => null,
};

/// The name [folder] gives a scene: its last segment; at the root of a share (\\nas\photo) the name of the share; at
/// the root of a drive (D:\) or of the computer, none, and the first photo names the scene
String splatFolderName(String folder, {p.Context? paths}) {
  final context = paths ?? p.context;
  final root = context.rootPrefix(folder);
  if (root.isEmpty || context.split(folder).length > 1) {
    return context.basename(folder);
  }
  final segments = root.split(RegExp(r'[\\/]+')).where((segment) => segment.isNotEmpty).toList();
  final share = (root.startsWith(r'\\') || root.startsWith('//')) && segments.length >= 2;
  return share ? segments.last : '';
}

/// Orders by the time they were taken, then by name
int _byTime(SplatCandidate a, SplatCandidate b) {
  final time = a.asset.createdAt.compareTo(b.asset.createdAt);
  return time != 0 ? time : a.asset.name.compareTo(b.asset.name);
}

/// See the top of this file; [linux] and [paths] for the tests, the system of this computer and its paths by default
SplatSelectionPlan planSplatSelection(List<SplatCandidate> candidates, {bool? linux, p.Context? paths}) {
  final context = paths ?? p.context;
  final videos = [
    for (final candidate in candidates)
      if (candidate.asset.isVideo) candidate,
  ];
  final photos = [
    for (final candidate in candidates)
      if (!candidate.asset.isVideo) candidate,
  ];
  if (videos.isNotEmpty && photos.isNotEmpty) {
    return const SplatSelectionPlan(refusal: SplatRefusal.mixed);
  }
  if (videos.length > 1) {
    return const SplatSelectionPlan(refusal: SplatRefusal.severalVideos, isVideo: true);
  }
  if (videos.length == 1) {
    return _planVideo(videos.single);
  }
  if (photos.isEmpty) {
    return const SplatSelectionPlan(refusal: SplatRefusal.nothing);
  }

  final leftOut = <SplatLeftOutReason, int>{};
  final usable = <SplatCandidate>[];
  for (final photo in photos) {
    final reason = splatLeftOutOf(photo, linux: linux);
    if (reason == null) {
      usable.add(photo);
    } else {
      leftOut[reason] = (leftOut[reason] ?? 0) + 1;
    }
  }
  final ordered = {for (final reason in SplatLeftOutReason.values) reason: ?leftOut[reason]};
  usable.sort(_byTime);
  final used = spreadEvenly(usable, SplatV1.maxPhotos);

  // The folders, the server counted as one place; the folder that holds the most, the first in time on a tie
  final byFolder = <String, List<SplatCandidate>>{};
  var server = false;
  for (final photo in used) {
    final folder = _folderOf(photo, context);
    if (folder == null) {
      server = true;
    } else {
      (byFolder[folder] ??= []).add(photo);
    }
  }
  List<SplatCandidate>? most;
  for (final group in byFolder.values) {
    if (most == null || group.length > most.length) {
      most = group;
    }
  }
  final oneFolder = byFolder.length == 1 && !server ? byFolder.keys.single : null;
  final folderName = oneFolder == null ? '' : splatFolderName(oneFolder, paths: context);

  return SplatSelectionPlan(
    used: used,
    leftOut: ordered,
    usable: usable.length,
    folders: byFolder.length + (server ? 1 : 0),
    refusal: usable.length < SplatV1.minImages ? SplatRefusal.tooFewPhotos : null,
    lenses: splatLensesOf(used),
    defaultName: folderName.isNotEmpty ? folderName : (used.isEmpty ? '' : fileStem(used.first.asset.name)),
    destination: most?.first ?? used.firstOrNull,
  );
}

SplatSelectionPlan _planVideo(SplatCandidate video) {
  // A length the library could not read comes as 0, not null: the library of the computer reads it only in the mvhd
  // box of a MP4 or a MOV and never opens a file kept online only, and the sync of the server stores 0 too
  final ms = video.asset.durationMs;
  final duration = ms != null && ms > 0 ? Duration(milliseconds: ms) : null;
  SplatRefusal? refusal;
  if (video.isVideo360) {
    refusal = SplatRefusal.video360;
  } else if (video.found == null) {
    refusal = SplatRefusal.videoUnreachable;
  } else if (duration != null && duration < SplatV1.minVideo) {
    refusal = SplatRefusal.videoShort;
  } else if (duration != null && duration > SplatV1.maxVideo) {
    refusal = SplatRefusal.videoLong;
  }
  return SplatSelectionPlan(
    used: [video],
    usable: 1,
    folders: 1,
    refusal: refusal,
    isVideo: true,
    videoDuration: duration,
    defaultName: fileStem(video.asset.name),
    destination: video,
  );
}

/// [location] named [name], the name chosen in the dialog, so that the destination checks the folder for
/// `<name>_splat.spz` (DestinationJob.finalName)
OriginalLocation splatNamedLocation(OriginalLocation location, String name) => switch (location) {
  LibraryOriginal() => LibraryOriginal(
    name: name,
    path: location.path,
    rootId: location.rootId,
    rootPath: location.rootPath,
    rootIsNetwork: location.rootIsNetwork,
    cloudOnly: location.cloudOnly,
  ),
  OpenedOriginal() => OpenedOriginal(name: name, path: location.path),
  ShareOriginal() => ShareOriginal(name: name, folder: location.folder),
  ServerOriginal() => ServerOriginal(name: name),
};

/// The time of a splat scene on this computer: the poses on the processor, the training on the graphics card, and the
/// whole job with the copy for the headset
typedef SplatTime = ({Duration poses, Duration training, Duration total});

/// The time of a scene of [images] photos, or frames of a video ([video]), from the times of its steps on this computer
/// ([timings], those of 150 images), as the engine counts it when the job starts (SplatTimeModel of splat_time.dart):
/// the preparation of the images, their points and the mapping follow the images, the matching follows its pairs
/// (every pair, or the list of a long video), the training follows its steps, the rest stays what it is. The dialog
/// and the panel so say the same time.
SplatTime splatTimeOf(AiTimings timings, {required int images, required bool video}) {
  const kind = ConversionKind.splatScene;
  final key = kind.timingsKey(fromVideo: video);
  final stages = kind.stagesOf(fromVideo: video);
  final model = SplatTimeModel(
    reference: {
      for (final stage in stages)
        if (timings.of(key, stage.name) case final millis?) stage: Duration(milliseconds: millis),
    },
    stages: stages,
    images: images,
    video: video,
  );
  final poses = stages
      .takeWhile((stage) => stage != ImmersiveStage.training)
      .fold(Duration.zero, (sum, stage) => sum + model.expected(stage));
  return (poses: poses, training: model.expected(ImmersiveStage.training), total: model.total);
}
