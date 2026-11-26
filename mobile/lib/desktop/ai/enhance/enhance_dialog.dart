// "Enhance (AI)" on a computer (release 51, lots E1 to E3): the entry in the menu of the viewer of a photo, in the
// bottom sheet and the menu of a selection, beside "Make 3D (AI)", and the dialog that hands the photos to the queue of
// the conversions (one job per photo, the batch with Pause, Stop and Resume in the panel of the conversions).
//
// The dialog offers the three levels (enhance_levels.dart), each with what it does in one line, greyed with its reason
// when this computer cannot run it for these photos (enhance_plan.dart: no graphics card, an integrated chip for
// Rebuild details, a Mac, less than 16 GB for Natural, a photo above 50 megapixels...), and for the chosen level:
//  - the time for the selection on this computer from the measures of the probe, and what they were measured on;
//  - the warnings: the memory free below the need of the level ("close other programs first", the figures), the card
//    busy, a long run;
//  - the honesty lines, always visible: details invented by AI (faces, text, small objects), for Rebuild details that
//    faces may become someone else, and that strong camera shake is not repaired;
//  - the strength, 60 % for Sharpen, 70 % for Rebuild details, 100 % for Natural by default;
//  - its components when some are missing (the panel of the AI components: names, sizes, licences, Download), "not in
//    this version yet" for a level whose engine is not published, or the folder of the developer override when it is on;
//  - where the files go: beside each original as name_enhanced.jpg, the original never changed; a photo of the server
//    (or one whose folder refuses a file) in the folder of my choice, with Change; the question of a network folder.
// A 360° photo and a 3D photo (side by side or one above the other, a 360° 3D photo too) are enhanced as such since
// release 53 (enhance_layout.dart): each eye alike, the seam of the sphere wrapped and its poles on faces of a cube,
// the GPano tags and the eyes written in the result; Rebuild details is not offered on a 3D photo, whose eyes would get
// other invented details (the dialog says so). Still skipped with their reason: a VR180 photo, an Apple spatial photo,
// a raw photo of a 360° camera, and a version the app made (its original is the one to enhance) (enhanceSkipOf). A
// photo above 50 megapixels is skipped too, and the levels are judged on the others.
//
// Every source (FreeKC, 22 and 25 November 2026: the AI functions take remote files, downloading them themselves): a
// photo of the library or opened with the program is read in place, one of the Immich server downloaded by its job,
// one of a share opened in the app (SMB, WebDAV, DLNA, Plex, Jellyfin, Emby) copied once as the dialog opens, its name
// and its bytes shown with Cancel, as the dialog of "Make 3D (AI)" does (share_conversion.dart). Its result goes beside
// its original on a share that takes files (SMB, WebDAV, through the writer of the shares: under its name, or the first
// free "name (n)", never over a file; share_publisher.dart), else to the folder of my choice; the dialog says which
// before anything runs.
// "Protect faces" of the study is not offered: it needs a face detector, a model this lot does not add.
// On a Mac with an Apple chip (release 53) the three levels are offered by the gates of the Mac (enhance_plan.dart:
// the memory of the Mac and its GPU as Metal tells it), and the line of the times says plainly that nothing was tried on
// a Mac yet: the times are those measured on the Windows laptop.
// Escape closes the dialog (a dialog of the shell, lot feat-desktop-escape-51).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/desktop_enhance.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_gpu.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_layout.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/gpu/metal_probe.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart' show decideStereoPhoto;
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('EnhanceDialog');

/// The size the time of a photo is told for when the app does not know its size: 12 MP
const _unknownSize = (4000, 3000);

/// What the dialog reads of this computer: the machine of the gates, the files of each level; the tests give theirs
abstract interface class EnhanceDialogFacts {
  Future<EnhanceMachine> machine();

  Future<EnhanceComponentsFound> filesOf(EnhanceLevel level, AiPlatform platform);
}

/// The facts of this computer: its memory, the card of each level of the card, the files of each level
class DesktopEnhanceDialogFacts implements EnhanceDialogFacts {
  const DesktopEnhanceDialogFacts(
    this.gate,
    this.engines, {
    this.memory = const SystemMemoryProbe(),
    this.metal = const SystemMetalProbe(),
  });

  final HardwareGate gate;
  final Map<EnhanceLevel, DesktopEnhanceEngine> engines;
  final MemoryProbe memory;
  final MetalProbe metal;

  @override
  Future<EnhanceMachine> machine() async {
    final facts = AiHardwareFacts.ofThisComputer();
    final read = memory.read();
    final platform = aiPlatformOf(facts.abi);
    if (platform == AiPlatform.macosArm64 || platform == AiPlatform.macosX64) {
      // No Vulkan on a Mac: the GPU as Metal tells it
      return EnhanceMachine(
        platform: platform,
        physicalMemory: read.physical ?? facts.physicalMemory,
        freeMemory: read.available,
        processors: facts.processors,
        metal: platform == AiPlatform.macosArm64 ? metal.read() : null,
      );
    }
    final report = await gate.gpuReport();
    // The card the dialog tells of: that of Rebuild details when there is one, else that of Sharpen
    final card = enhanceCardOf(EnhanceLevel.rebuild, report) ?? enhanceCardOf(EnhanceLevel.sharpen, report);
    return EnhanceMachine(
      platform: aiPlatformOf(facts.abi),
      physicalMemory: read.physical ?? facts.physicalMemory,
      freeMemory: read.available,
      processors: facts.processors,
      card: card,
    );
  }

  @override
  Future<EnhanceComponentsFound> filesOf(EnhanceLevel level, AiPlatform platform) => engines[level]!.filesNow(platform);
}

final enhanceDialogFactsProvider = Provider<EnhanceDialogFacts>(
  (ref) => DesktopEnhanceDialogFacts(ref.watch(desktopAiGateProvider), ref.watch(desktopEnhanceEnginesProvider)),
);

/// "Enhance (AI)" for the photos of [source]: a menu item of the viewer, or a button of the bottom sheet of a selection
class DesktopEnhanceButton extends ConsumerWidget {
  const DesktopEnhanceButton({super.key, required this.source, this.menuItem = false});

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
    final t = context.t;
    void open() => unawaited(openEnhanceDialog(context, ref, assets, source: source));
    return menuItem
        ? ImmichMenuItem(
            key: const Key('ai_enhance'),
            icon: Icons.auto_fix_high_outlined,
            label: t.ai_enhance_action,
            onPressed: open,
          )
        : ImmichColumnButton(
            key: const Key('ai_enhance'),
            icon: Icons.auto_fix_high_outlined,
            label: t.ai_enhance_action,
            onPressed: open,
          );
  }
}

/// Opens the dialog for the photos of [assets]; once photos were handed to the queue, the panel of the conversions
/// shows and the selection ends
Future<void> openEnhanceDialog(
  BuildContext context,
  WidgetRef ref,
  List<BaseAsset> assets, {
  ActionSource source = ActionSource.viewer,
}) async {
  final clearSelection = ref.read(clearSelectionProvider(source));
  final navigator = Navigator.of(context, rootNavigator: true);
  final launched = await showDialog<bool>(
    context: context,
    builder: (context) => EnhanceDialog(assets: assets),
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

/// Opens the dialog on [entries], files of one share opened in the app; once photos were handed to the queue, the
/// panel of the conversions shows. True once they were.
Future<bool> openShareEnhanceDialog(BuildContext context, List<NetworkEntry> entries) async {
  // The page that opened the dialog may be gone when it closes: the panel opens from the navigator
  final navigator = Navigator.of(context, rootNavigator: true);
  final launched = await showDialog<bool>(
    context: context,
    builder: (context) => EnhanceDialog(shareFiles: entries),
  );
  if (launched != true) {
    return false;
  }
  final overlay = navigator.mounted ? navigator.overlay : null;
  if (overlay != null && overlay.mounted) {
    unawaited(showConversionsPanel(overlay.context));
  }
  return true;
}

/// Opens the dialog of "Enhance (AI)" on files of a share, true once they were handed to the queue; replaced in tests
final shareEnhanceOpenerProvider = Provider<Future<bool> Function(BuildContext context, List<NetworkEntry> entries)>(
  (ref) => openShareEnhanceDialog,
);

/// "Enhance (AI)" in the menu of the page of a photo of a share (network_photo.page.dart), shown while the AI features
/// are on; [onOpen] opens the dialog once the menu closed
PopupMenuItem<void> desktopShareEnhanceMenuItem(BuildContext context, {required VoidCallback onOpen}) =>
    PopupMenuItem<void>(
      key: const Key('ai_enhance'),
      onTap: onOpen,
      child: ListTile(
        leading: const Icon(Icons.auto_fix_high_outlined),
        title: Text(context.t.ai_enhance_action),
        contentPadding: EdgeInsets.zero,
      ),
    );

/// "Enhance (AI)" in the bar of a selection of the browser of a share, next to "Make 3D (AI)": the dialog on the files
/// picked ([entries]); greyed for a selection without a photo. [onLaunched] once photos were handed to the queue.
class DesktopShareEnhanceButton extends ConsumerWidget {
  const DesktopShareEnhanceButton({super.key, required this.entries, required this.onLaunched});

  final List<NetworkEntry> entries;
  final VoidCallback onLaunched;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiFeaturesEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final photos = entries.any((entry) => entry.isImage);
    Future<void> open() async {
      if (await ref.read(shareEnhanceOpenerProvider)(context, entries)) {
        onLaunched();
      }
    }

    return FilledButton.tonalIcon(
      key: const Key('ai_enhance'),
      icon: const Icon(Icons.auto_fix_high_outlined),
      label: Text(context.t.ai_enhance_action),
      onPressed: photos ? () => unawaited(open()) : null,
    );
  }
}

/// A photo of the selection as the dialog read it: where its original is (null when this computer cannot reach it)
class _Photo {
  const _Photo(this.asset, this.found, this.id, {this.skip, this.layout = EnhanceLayout.flat});

  final BaseAsset asset;
  final ({OriginalLocation location, ConversionSource source})? found;

  /// Its id in the destination session, null for one skipped
  final String? id;

  /// Why it is skipped, known before anything runs; null for one that runs, or one this computer cannot reach
  final ConversionSkipReason? skip;

  /// What it is: flat, 360°, 3D (enhance_layout.dart)
  final EnhanceLayout layout;

  (int, int) get size => enhanceSizeOf(asset);

  /// A 3D photo, which Rebuild details does not take
  bool get isStereo => layout.isStereo;

  /// A photo of a share opened in the app
  bool get onShare => found?.location is ShareOriginal;
}

/// The size of [asset] as the library knows it, 12 MP when it does not
(int, int) enhanceSizeOf(BaseAsset asset) => switch ((asset.width, asset.height)) {
  (final width?, final height?) when width > 0 && height > 0 => (width, height),
  _ => _unknownSize,
};

/// The reasons to skip a photo that tell a kind of photo Enhance does not take, said together in the dialog
const enhanceKindSkips = {
  ConversionSkipReason.sphere360,
  ConversionSkipReason.vr180,
  ConversionSkipReason.raw360,
  ConversionSkipReason.alreadyStereo,
  ConversionSkipReason.spatial,
  ConversionSkipReason.alreadyVersion,
};

/// Why "Enhance (AI)" skips [asset], from its [facts] as the dialog of "Make 3D (AI)" reads them; null when it runs
/// (a flat, 360° or 3D photo, see [enhanceLayoutOf]):
///  - a video;
///  - a raw photo of a 360° camera: its two lenses are not stitched into a picture of the sphere;
///  - a version the app made (a 3D photo, a 3D scene, a panorama generated, its 3D version, the picture of a splat
///    scene): its original is the one to enhance, then the version made again. An enhanced photo may be enhanced
///    again;
///  - an Apple spatial photo: its two pictures live in a HEIC file, which the engine does not write;
///  - a VR180 photo: two half spheres side by side, whose edges and poles the engine does not handle yet;
///  - above 50 megapixels by the size the library knows (the engine checks the picture it decodes too).
ConversionSkipReason? enhanceSkipOf(BaseAsset asset, ConversionPhotoFacts facts) {
  if (asset.isVideo || !asset.isImage) {
    return ConversionSkipReason.video;
  }
  if (facts.isRaw360) {
    return ConversionSkipReason.raw360;
  }
  final version = facts.version;
  if (version != null && version.kind != ImmersiveKind.enhancedPhoto) {
    return ConversionSkipReason.alreadyVersion;
  }
  if (facts.isSpatial) {
    return ConversionSkipReason.spatial;
  }
  if (facts.isPanorama &&
      (facts.coverage ?? guessSphereCoverage(fileName: asset.name, width: asset.width, height: asset.height)) ==
          SphereCoverage.half) {
    return ConversionSkipReason.vr180;
  }
  final (width, height) = enhanceSizeOf(asset);
  if (width * height > enhanceMaxPixels) {
    return ConversionSkipReason.tooLarge;
  }
  return null;
}

/// What [asset] is for the engine, once [enhanceSkipOf] took it:
///  - a 360° photo: a picture of the sphere, or two of them stacked (a square frame) or side by side (a 4:1 frame), as
///    the 360° viewers tell them by their frame;
///  - a 3D photo side by side by its name and frame (or one of ours by its XMP): its eyes as the viewers read them;
///  - a photo whose name says its eyes are one above the other (_TB, _OU...) and whose frame agrees
///    ([enhanceTopBottomOf]);
///  - else a flat photo.
EnhanceLayout enhanceLayoutOf(BaseAsset asset, ConversionPhotoFacts facts) {
  final width = asset.width;
  final height = asset.height;
  if (facts.isPanorama) {
    final eyes = switch (guessStereoLayout(width: width, height: height, hasGPanoCrop: facts.partialSphere)) {
      StereoLayout.topBottom => EnhanceEyes.topBottom,
      StereoLayout.leftRight => EnhanceEyes.sideBySide,
      StereoLayout.mono => EnhanceEyes.none,
    };
    return EnhanceLayout(eyes: eyes, sphere: true);
  }
  if (facts.isStereo) {
    final told = decideStereoPhoto(name: asset.name, width: width, height: height);
    return EnhanceLayout(
      eyes: EnhanceEyes.sideBySide,
      halfEyes: told?.eyes == StereoEyes.half,
      rightFirst: told?.eyeOrder == EyeOrder.rightLeft,
    );
  }
  if (enhanceTopBottomOf(asset.name, width, height)) {
    return const EnhanceLayout(eyes: EnhanceEyes.topBottom);
  }
  return EnhanceLayout.flat;
}

// The words of a name that mark eyes one above the other. Those no title uses count in any case; the short ones are
// words of languages too (French "ou", "fou", a "tab") and count only in capitals, as the rippers and players write
// them ("_OU", "3D-TB"). Those of [_halfTopBottomWords], or "half" next to one, say the eyes are squeezed to half their
// height.
const _topBottomWordsAnyCase = {'overunder', 'topbottom', '3dou', 'htb', 'ftb', 'htab'};
const _topBottomWordsInCapitals = {'OU', 'TB', 'TAB', 'HOU', 'FOU'};
const _halfTopBottomWords = {'htb', 'htab', 'hou'};

/// Whether a photo named [name] of [width] x [height] holds two eyes one above the other: its name says so (see the
/// words above) and its frame agrees: 1:1 to 1:2 for two full eyes (each 1:1 to 2:1), 1:1 to 2.4:1 for eyes squeezed
/// to half their height. A photo whose frame is not known is told by its name.
bool enhanceTopBottomOf(String name, int? width, int? height) {
  final words = name.split(RegExp(r'[._\- ]+'));
  var stacked = false;
  var half = false;
  for (var at = 0; at < words.length; at++) {
    final word = words[at];
    final lower = word.toLowerCase();
    if (_topBottomWordsAnyCase.contains(lower) || _topBottomWordsInCapitals.contains(word)) {
      stacked = true;
      half |=
          _halfTopBottomWords.contains(lower) ||
          (at > 0 && words[at - 1].toLowerCase() == 'half') ||
          (at + 1 < words.length && words[at + 1].toLowerCase() == 'half');
    }
  }
  if (!stacked) {
    return false;
  }
  if (width == null || height == null || width <= 0 || height <= 0) {
    return true;
  }
  final ratio = width / height;
  return half ? ratio >= 1.0 && ratio <= 2.4 : ratio >= 0.5 && ratio <= 1.0;
}

/// The words of a refusal of a level
String enhanceRefusalText(Translations t, EnhanceRefusal refusal) => switch (refusal) {
  EnhanceRefusal.notOnThisSystem => t.ai_enhance_refused_system,
  EnhanceRefusal.appleChipNeeded => t.ai_enhance_refused_mac,
  EnhanceRefusal.intelMacNotChecked => t.ai_enhance_refused_intel_mac,
  EnhanceRefusal.macGraphicsUnusable => t.ai_enhance_refused_mac_graphics,
  EnhanceRefusal.macRebuildNotYet => t.ai_enhance_refused_mac_rebuild,
  EnhanceRefusal.noGraphicsCard => t.ai_enhance_refused_no_card,
  EnhanceRefusal.dedicatedCardNeeded => t.ai_enhance_refused_dedicated,
  EnhanceRefusal.graphicsCardTooSmall => t.ai_enhance_refused_card_small,
  EnhanceRefusal.memoryTooSmall => t.ai_enhance_refused_memory,
  EnhanceRefusal.tooLarge => t.ai_enhance_refused_too_large,
};

/// The name and the line of a level
String enhanceLevelName(Translations t, EnhanceLevel level) => switch (level) {
  EnhanceLevel.sharpen => t.ai_enhance_level_sharpen,
  EnhanceLevel.rebuild => t.ai_enhance_level_rebuild,
  EnhanceLevel.natural => t.ai_enhance_level_natural,
};

/// [appleChip]: on a Mac with an Apple chip Natural opens its graphs with Core ML first (natural_backend.dart)
String _levelLine(Translations t, EnhanceLevel level, {required bool appleChip}) => switch (level) {
  EnhanceLevel.sharpen => t.ai_enhance_level_sharpen_line,
  EnhanceLevel.rebuild => t.ai_enhance_level_rebuild_line,
  EnhanceLevel.natural when appleChip => t.ai_enhance_level_natural_line_mac,
  EnhanceLevel.natural => t.ai_enhance_level_natural_line,
};

/// Whether [level] takes a 3D photo: Rebuild details invents details, other ones in each eye (enhance_layout.dart)
bool enhanceTakesStereo(EnhanceLevel level) => level != EnhanceLevel.rebuild;

/// See the top of this file
class EnhanceDialog extends ConsumerStatefulWidget {
  const EnhanceDialog({super.key, this.assets = const [], this.shareFiles = const []});

  final List<BaseAsset> assets;

  /// The files of a share opened in the app it is opened on instead of [assets]: each photo is copied once through
  /// the media bridge as the dialog opens, and its facts read from that copy (share_conversion.dart)
  final List<NetworkEntry> shareFiles;

  @override
  ConsumerState<EnhanceDialog> createState() => _EnhanceDialogState();
}

class _EnhanceDialogState extends ConsumerState<EnhanceDialog> {
  late final DesktopAiSettingsStore _store = ref.read(desktopAiSettingsStoreProvider);
  List<_Photo>? _photos;
  DestinationSession? _session;
  EnhanceMachine? _machine;
  final _files = <EnhanceLevel, EnhanceComponentsFound>{};
  EnhanceLevel _level = EnhanceLevel.sharpen;
  final _strengths = {for (final level in EnhanceLevel.values) level: level.defaultStrength};
  var _gestures = 0;
  var _launched = false;
  var _closed = false;

  /// The copy of the photos of a share under way: which photo, of how many, and its bytes copied of their total
  ({int index, int count, String name, int copied, int? total})? _copying;

  /// The copies of the photos of a share this dialog made; those no job takes are deleted as it closes or launches
  final _shareSources = <ShareFileSource>[];

  /// The photos are being read (or copied from their share): their copies are deleted once that ends
  var _reading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_session?.close());
    // A copy under way stops at its next bytes, and its photos are deleted once the reading ends
    if (!_launched && !_reading) {
      _releaseShareSources();
    }
    super.dispose();
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

  int get _count => widget.shareFiles.isNotEmpty
      ? widget.shareFiles.where((entry) => entry.isImage).length
      : widget.assets.where((asset) => asset.isImage).length;

  Future<void> _load() async {
    _reading = true;
    List<_Photo>? photos;
    try {
      photos = widget.shareFiles.isEmpty ? await _readAssets() : await _readShareFiles();
    } finally {
      _reading = false;
    }
    if (photos == null || _closed || !mounted) {
      if (!_launched) {
        _releaseShareSources();
      }
      return;
    }
    final session = ref.read(destinationSessionFactoryProvider)([
      for (final photo in photos)
        if (photo.found case final found? when photo.id != null)
          DestinationJob(id: photo.id!, original: found.location, kind: ImmersiveKind.enhancedPhoto),
    ], _store);
    final facts = ref.read(enhanceDialogFactsProvider);
    EnhanceMachine machine;
    try {
      machine = await facts.machine();
    } catch (error) {
      _log.warning('The facts of this computer could not be read: $error');
      machine = const EnhanceMachine(platform: null);
    }
    final platform = machine.platform;
    if (platform != null) {
      for (final level in EnhanceLevel.values) {
        try {
          _files[level] = await facts.filesOf(level, platform);
        } catch (error) {
          _log.warning('The files of ${level.name} could not be read: $error');
        }
      }
    }
    if (!mounted || _closed) {
      unawaited(session.close());
      return;
    }
    setState(() {
      _photos = photos;
      _session = session;
      _machine = machine;
      _level = _firstOffered();
    });
    await _gesture(session.open);
  }

  /// The photos of the app the dialog was opened on, as it reads them once
  Future<List<_Photo>> _readAssets() async {
    final locator = ref.read(conversionAssetFilesProvider);
    final readFacts = ref.read(conversionFactsReaderProvider);
    final probe = ref.read(conversionFileProbeProvider);
    final photos = <_Photo>[];
    for (final (index, asset) in widget.assets.indexed) {
      if (!asset.isImage) {
        photos.add(_Photo(asset, null, null, skip: ConversionSkipReason.video));
        continue;
      }
      ConversionPhotoFacts facts;
      try {
        facts = await readFacts(asset);
      } catch (error) {
        _log.warning('The facts of ${asset.name} could not be read: $error');
        // Two eyes by its name and frame at least
        facts = ConversionPhotoFacts(
          isStereo: decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) != null,
        );
      }
      if (enhanceSkipOf(asset, facts) case final skip?) {
        photos.add(_Photo(asset, null, null, skip: skip));
        continue;
      }
      ({OriginalLocation location, ConversionSource source})? found;
      try {
        found = await locator.locate(asset);
      } catch (error) {
        _log.warning('The original of ${asset.name} is not found: $error');
      }
      // A photo of the frame of a whole sphere the scan has not flagged: its file tells whether it is a 360° one, as
      // the dialog of "Make 3D (AI)" reads it
      if (found != null && !facts.isPanorama && isEquirectFrame(asset.width, asset.height)) {
        try {
          if (await probe(found.source, asset) case final read?) {
            facts = facts.withFileRead(isPanorama: read.isPanorama, isRaw360: read.raw360);
          }
        } catch (error) {
          _log.fine('${asset.name} could not be read for a 360° projection: $error');
        }
        if (enhanceSkipOf(asset, facts) case final skip?) {
          photos.add(_Photo(asset, null, null, skip: skip));
          continue;
        }
      }
      photos.add(_Photo(asset, found, found == null ? null : 'enhance-$index', layout: enhanceLayoutOf(asset, facts)));
    }
    return photos;
  }

  /// The files of a share the dialog was opened on: each photo copied once through the media bridge, its name and its
  /// bytes shown meanwhile, then its facts read from that copy as the dialog of "Make 3D (AI)" reads them. A photo
  /// whose copy fails cannot be reached; once a copy finds no room on this computer, that photo and the ones after it
  /// are skipped with "Disk full", without trying their copies. Null once the dialog closed meanwhile (Cancel): the
  /// copy under way stops.
  Future<List<_Photo>?> _readShareFiles() async {
    final make = ref.read(shareConversionSourceProvider);
    final read = ref.read(shareCopyFactsReaderProvider);
    // A share that takes files has its versions next to their originals (destination.dart); a media server has not
    final folderOf = ref.read(shareFolderOfProvider);
    final files = widget.shareFiles;
    final photos = <_Photo>[];
    var full = false;
    for (final (index, entry) in files.indexed) {
      if (_closed) {
        return null;
      }
      final listed = shareConversionAsset(entry);
      if (!entry.isImage) {
        photos.add(_Photo(listed, null, null, skip: ConversionSkipReason.video));
        continue;
      }
      if (full) {
        photos.add(_Photo(listed, null, null, skip: ConversionSkipReason.diskFull));
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
        final known = await read(entry, copy);
        source.exif = known.exif;
        final asset = shareConversionAsset(entry, width: known.width, height: known.height);
        if (enhanceSkipOf(asset, known.facts) case final skip?) {
          _shareSources.remove(source);
          unawaited(source.release());
          photos.add(_Photo(asset, null, null, skip: skip));
          continue;
        }
        photos.add(
          _Photo(
            asset,
            (location: ShareOriginal(name: entry.name, folder: folderOf(entry)), source: source),
            'enhance-$index',
            layout: enhanceLayoutOf(asset, known.facts),
          ),
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
          _Photo(listed, null, null, skip: full ? ConversionSkipReason.diskFull : ConversionSkipReason.unreachable),
        );
      }
    }
    if (mounted && !_closed) {
      setState(() => _copying = null);
    }
    return photos;
  }

  /// Sharpen when it is offered for the photos, else Natural, else Rebuild details
  EnhanceLevel _firstOffered() {
    for (final level in [EnhanceLevel.sharpen, EnhanceLevel.natural, EnhanceLevel.rebuild]) {
      if (_verdict(level).isOffered && _runsAt(level).isNotEmpty) {
        return level;
      }
    }
    return EnhanceLevel.sharpen;
  }

  Iterable<_Photo> get _runs => (_photos ?? const []).where((photo) => photo.id != null);

  /// The photos [level] runs on: Rebuild details leaves the 3D photos out
  Iterable<_Photo> _runsAt(EnhanceLevel level) => _runs.where((photo) => enhanceTakesStereo(level) || !photo.isStereo);

  /// The verdict of [level] for the selection: refused when it is refused for its largest photo. The photos above 50
  /// megapixels are skipped and left out of it, unless no other runs: the levels then say why. The time is that of
  /// every photo it runs on, each in its pieces (the eyes of a 3D photo, the seam and the poles of a 360° one).
  EnhanceVerdict _verdict(EnhanceLevel level) {
    final machine = _machine;
    if (machine == null) {
      return EnhanceVerdict(level, refusal: EnhanceRefusal.notOnThisSystem);
    }
    final runs = _runsAt(level).toList();
    var sizes = [for (final photo in runs) (photo.size, photo.layout)];
    if (sizes.isEmpty) {
      sizes = [
        for (final photo in _photos ?? const <_Photo>[])
          if (photo.skip == ConversionSkipReason.tooLarge) (photo.size, photo.layout),
      ];
    }
    // The largest in the pixels the model works on, which decides the memory (a 360° photo works on more than its own)
    int work(((int, int), EnhanceLayout) photo) => enhanceWorkPixels(photo.$1.$1, photo.$1.$2, photo.$2);
    final ((width, height), layout) = sizes.isEmpty
        ? (_unknownSize, EnhanceLayout.flat)
        : sizes.reduce((a, b) => work(a) >= work(b) ? a : b);
    final largest = enhanceVerdict(level, machine, width: width, height: height, layout: layout);
    if (!largest.isOffered || runs.isEmpty || (runs.length == 1 && runs.single.layout.isFlat)) {
      return largest;
    }
    var total = Duration.zero;
    for (final photo in runs) {
      final (photoWidth, photoHeight) = photo.size;
      total += enhanceLayoutEstimate(level, photoWidth, photoHeight, photo.layout, processors: machine.processors);
    }
    return EnhanceVerdict(
      level,
      warnings: [
        ...largest.warnings.where((warning) => warning != EnhanceWarning.longRun),
        if (total > enhanceLongRun) EnhanceWarning.longRun,
      ],
      estimate: total,
      memoryNeeded: largest.memoryNeeded,
    );
  }

  Future<void> _gesture(Future<void> Function() gesture) async {
    setState(() => _gestures++);
    try {
      await gesture();
    } catch (error, stack) {
      _log.warning('A gesture of the dialog failed', error, stack);
    } finally {
      if (mounted) {
        setState(() => _gestures--);
      }
    }
  }

  Future<void> _reloadFiles() async {
    final platform = _machine?.platform;
    if (platform == null) {
      return;
    }
    final found = await ref.read(enhanceDialogFactsProvider).filesOf(_level, platform);
    if (mounted) {
      setState(() => _files[_level] = found);
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
      await _gesture(() => session.chooseFolder(picked!));
    }
  }

  bool _ready(DestinationSession session) {
    if (session.pendingConsents.isNotEmpty || _gestures > 0) {
      return false;
    }
    final runs = _runsAt(_level).toList();
    return runs.isNotEmpty && runs.every((photo) => session.checkOf(photo.id!)?.accepted ?? false);
  }

  Future<void> _launch(DestinationSession session) async {
    if (_launched) {
      return;
    }
    _launched = true;
    final level = _level;
    final photos = _photos!;
    final requests = <ConversionRequest>[];
    for (final photo in photos) {
      final found = photo.found;
      final plan = photo.id == null ? null : session.destinations[photo.id];
      if (found != null && photo.isStereo && !enhanceTakesStereo(level)) {
        requests.add(ConversionRequest(source: found.source, skip: ConversionSkipReason.enhanceStereoInvents));
        continue;
      }
      // A result beside its original on a share is made here first, in a folder of its own, then put there
      var folder = plan?.folder;
      if (plan?.share != null) {
        try {
          folder = await ref.read(shareStagingFolderProvider)();
        } catch (error) {
          _log.warning('No folder to make the enhanced photo of ${photo.asset.name} in: $error');
          folder = null;
        }
      }
      if (found == null || plan == null || folder == null) {
        requests.add(
          ConversionRequest(
            source: found?.source ?? _Unreachable(photo.asset.name),
            skip: photo.skip ?? ConversionSkipReason.unreachable,
          ),
        );
        continue;
      }
      final (width, height) = photo.size;
      requests.add(
        ConversionRequest(
          source: found.source,
          target: ConversionTarget(
            folder: folder,
            fileName: versionTargetName(ImmersiveKind.enhancedPhoto, found.location.name),
          ),
          pixels: width * height,
          enhanceLayout: photo.layout,
        ),
      );
    }
    // The version of the app goes into each file
    await ref.read(aiAppVersionProvider.future);
    final output = ref.read(safeWriterOutputProvider);
    final ids = ref
        .read(conversionQueueProvider.notifier)
        .add(
          requests,
          kind: ConversionKind.enhanceAt(level),
          existing: ExistingVersionChoice.newVersion,
          enhance: EnhanceSettings(level: level, strength: _strengths[level]!),
        );
    // The copies of the photos of a share go with their jobs; those of the photos skipped go now
    _releaseShareSources(
      kept: {
        for (final request in requests)
          if (request.skip == null) request.source,
      },
    );
    final infos = <String, ConversionJobInfo>{};
    final shared = <String, ShareVersionTarget>{};
    for (final (index, id) in ids.indexed) {
      final photo = photos[index];
      final plan = photo.id == null ? null : session.destinations[photo.id];
      if (plan?.share case final folder? when requests[index].skip == null) {
        // Never over a file: under its name, or the first free "name (n)"
        shared[id] = ShareVersionTarget(
          folder: folder,
          fallbackFolder: session.chosenFolder,
          fallbackIsNetwork: session.chosenFolderIsNetwork,
        );
      }
      final part = photo.id == null || plan?.share != null ? null : session.takePart(photo.id!);
      if (part != null) {
        output.adopt(id, part);
      }
      infos[id] = ConversionJobInfo(
        // A photo of a share is no photo of the app: its row shows no thumbnail of the timeline
        asset: photo.onShare ? null : photo.asset,
        isNetwork: plan?.isNetwork ?? false,
      );
    }
    ref.read(conversionJobInfoProvider.notifier).addAll(infos);
    ref.read(sharePublisherProvider.notifier).follow(shared);
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final photos = _photos;
    final session = _session;
    final count = _count;
    final title = Text(count > 1 ? t.ai_enhance_action_count(count: count) : t.ai_enhance_action);
    if (photos == null || session == null) {
      final copying = _copying;
      return AlertDialog(
        key: const Key('ai_enhance_dialog'),
        title: title,
        content: SizedBox(
          width: 560,
          child: copying != null
              ? ShareCopyLine(key: const Key('ai_enhance_share_copy'), copying: copying)
              : const LinearProgressIndicator(),
        ),
        actions: [
          TextButton(
            key: const Key('ai_enhance_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.cancel),
          ),
        ],
      );
    }
    final colors = context.colorScheme;
    final secondary = TextStyle(color: colors.onSurfaceVariant);
    final verdict = _verdict(_level);
    final files = _files[_level];
    final runs = _runsAt(_level).length;
    final kinds = photos.where((photo) => enhanceKindSkips.contains(photo.skip)).length;
    final tooLarge = photos.where((photo) => photo.skip == ConversionSkipReason.tooLarge).length;
    final stereoLeft = _runs.length - runs;
    final skipped = photos.length - _runs.length - kinds - tooLarge;
    final spheres = _runsAt(_level).any((photo) => photo.layout.sphere);
    final stereo = _runsAt(_level).any((photo) => photo.isStereo);
    final filesReady = files?.files != null;
    final canStart = verdict.isOffered && filesReady && _ready(session) && !_launched;
    final warn = TextStyle(color: colors.error);
    return AlertDialog(
      key: const Key('ai_enhance_dialog'),
      title: title,
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final level in EnhanceLevel.values) _levelTile(t, level),
              const Divider(),
              if (verdict.isOffered) ...[
                if (verdict.estimate case final estimate?)
                  Text(
                    runs > 1
                        ? t.ai_enhance_estimate_batch(time: videoDurationText(t, estimate), count: runs)
                        : t.ai_enhance_estimate(time: videoDurationText(t, estimate)),
                    key: const Key('ai_enhance_estimate'),
                  ),
                Text(
                  _machine?.platform == AiPlatform.macosArm64
                      ? t.ai_enhance_mac_untried
                      : _level.onGraphicsCard
                      ? t.ai_enhance_estimate_card
                      : t.ai_enhance_estimate_processor,
                  key: const Key('ai_enhance_measured_on'),
                  style: secondary,
                ),
                if (_level == EnhanceLevel.rebuild) Text(t.ai_enhance_first_run, style: secondary),
                for (final warning in verdict.warnings) Text(_warningText(t, warning, verdict), style: warn),
              ],
              const SizedBox(height: 8),
              Text(t.ai_enhance_invented, key: const Key('ai_enhance_invented'), style: warn),
              if (_level == EnhanceLevel.rebuild)
                Text(t.ai_enhance_rebuild_faces, key: const Key('ai_enhance_rebuild_faces'), style: warn),
              Text(t.ai_enhance_shake, style: secondary),
              if (spheres)
                Text(t.ai_enhance_layout_sphere, key: const Key('ai_enhance_layout_sphere'), style: secondary),
              if (stereo)
                Text(t.ai_enhance_layout_stereo, key: const Key('ai_enhance_layout_stereo'), style: secondary),
              const SizedBox(height: 8),
              Text(t.ai_enhance_strength(percent: _strengths[_level]!)),
              Slider(
                key: const Key('ai_enhance_strength'),
                value: _strengths[_level]!.toDouble(),
                max: 100,
                divisions: 20,
                label: '${_strengths[_level]} %',
                onChanged: (value) => setState(() => _strengths[_level] = value.round()),
              ),
              Text(t.ai_enhance_strength_help, style: secondary),
              const SizedBox(height: 8),
              ..._componentsPart(t, files),
              ..._destinationPart(t, session, secondary),
              if (kinds > 0)
                Text(
                  t.ai_enhance_skipped_kinds(count: kinds),
                  key: const Key('ai_enhance_skipped_kinds'),
                  style: secondary,
                ),
              if (stereoLeft > 0)
                Text(
                  t.ai_enhance_skipped_rebuild_3d(count: stereoLeft),
                  key: const Key('ai_enhance_skipped_rebuild_3d'),
                  style: secondary,
                ),
              if (tooLarge > 0)
                Text(
                  t.ai_enhance_skipped_too_large(count: tooLarge),
                  key: const Key('ai_enhance_skipped_too_large'),
                  style: secondary,
                ),
              if (skipped > 0) Text(t.ai_enhance_skipped(count: skipped), style: secondary),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ai_enhance_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.cancel),
        ),
        FilledButton(
          key: const Key('ai_enhance_start'),
          onPressed: canStart ? () => unawaited(_launch(session)) : null,
          child: Text(t.ai_enhance_start),
        ),
      ],
    );
  }

  Widget _levelTile(Translations t, EnhanceLevel level) {
    final verdict = _verdict(level);
    final files = _files[level];
    // Rebuild details on 3D photos only: none it takes
    final onlyStereo = _runs.isNotEmpty && _runsAt(level).isEmpty;
    final reason = switch (verdict.refusal) {
      final refusal? => enhanceRefusalText(t, refusal),
      null when onlyStereo => t.ai_enhance_refused_rebuild_3d,
      null when files?.notInThisVersion ?? false => t.ai_enhance_refused_not_yet,
      null => null,
    };
    final offered = verdict.isOffered && !onlyStereo;
    final chosen = level == _level;
    final line = _levelLine(t, level, appleChip: _machine?.platform == AiPlatform.macosArm64);
    return ListTile(
      key: Key('ai_enhance_level_${level.name}'),
      contentPadding: EdgeInsets.zero,
      enabled: offered,
      selected: chosen,
      leading: Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(enhanceLevelName(t, level)),
      subtitle: Text(reason == null ? line : '$line\n$reason'),
      onTap: () => setState(() => _level = level),
    );
  }

  String _warningText(Translations t, EnhanceWarning warning, EnhanceVerdict verdict) => switch (warning) {
    EnhanceWarning.closeOtherPrograms => t.ai_enhance_close_programs(
      free: formatBytes(_machine?.freeMemory ?? 0),
      need: formatBytes(verdict.memoryNeeded ?? 0),
    ),
    EnhanceWarning.graphicsMemoryBusy => t.ai_enhance_card_busy,
    EnhanceWarning.longRun => t.ai_enhance_long,
  };

  List<Widget> _componentsPart(Translations t, EnhanceComponentsFound? files) {
    if (files == null || !_verdict(_level).isOffered) {
      return const [];
    }
    if (files.notInThisVersion) {
      return [Text(t.ai_enhance_refused_not_yet, key: const Key('ai_enhance_not_yet'))];
    }
    if (files.files?.fromProbe ?? false) {
      return [
        Text(
          t.ai_enhance_override(folder: enhanceProbeFolder() ?? ''),
          key: const Key('ai_enhance_override'),
          style: TextStyle(color: context.colorScheme.tertiary),
        ),
      ];
    }
    if (files.missing.isNotEmpty) {
      return [
        AiInstallPanel(
          key: Key('ai_enhance_install_${_level.name}'),
          components: files.missing,
          onInstalled: () => unawaited(_reloadFiles()),
        ),
      ];
    }
    return const [];
  }

  /// Where the results go, said before anything runs: beside each original (on its share for a photo of a share that
  /// takes files), or in the folder of my choice with why and Change
  List<Widget> _destinationPart(Translations t, DestinationSession session, TextStyle secondary) {
    final runs = _runsAt(_level).toList();
    final plans = [for (final photo in runs) ?session.destinations[photo.id]];
    if (plans.isEmpty) {
      return const [];
    }
    final shares = {for (final plan in plans) ?plan.share?.label};
    final beside = plans.where((plan) => plan.kind == DestinationKind.nextToOriginal && plan.share == null).isNotEmpty;
    final chosen = plans.any((plan) => plan.kind == DestinationKind.chosenFolder);
    // A media server (DLNA, Plex, Jellyfin, Emby) takes no file
    final mediaServer = runs.any(
      (photo) => switch (photo.found?.location) {
        ShareOriginal(:final folder) => folder == null,
        _ => false,
      },
    );
    return [
      if (beside) Text(t.ai_enhance_saved_beside, key: const Key('ai_enhance_saved_beside')),
      for (final label in shares)
        Text(t.ai_enhance_saved_share(folder: label), key: const Key('ai_enhance_saved_share')),
      if (chosen) ...[
        Text(t.ai_enhance_saved_folder(folder: session.chosenFolder), key: const Key('ai_enhance_saved_folder')),
        if (mediaServer)
          Text(
            t.ai_enhance_saved_folder_media_server,
            key: const Key('ai_enhance_saved_folder_media'),
            style: secondary,
          )
        else if (plans.any((plan) => plan.reason == DestinationReason.sourceReadOnly))
          Text(t.ai_enhance_saved_folder_why, style: secondary),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('ai_enhance_change_folder'),
            onPressed: _gestures > 0 ? null : () => unawaited(_changeFolder()),
            child: Text(t.change),
          ),
        ),
      ],
      for (final MapEntry(key: consent, value: folder) in session.pendingConsents.entries) ...[
        Text(t.ai_enhance_network_root_ask),
        Text(folder, style: secondary),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: Key('ai_enhance_network_yes_$consent'),
              onPressed: () => unawaited(_gesture(() => session.allowNetwork(consent))),
              child: Text(t.ai_immersive_network_root_yes),
            ),
            TextButton(
              key: Key('ai_enhance_network_no_$consent'),
              onPressed: () => unawaited(_gesture(() => session.declineNetwork(consent))),
              child: Text(t.ai_immersive_network_root_no),
            ),
          ],
        ),
      ],
      SizedBox(height: math.min(8, plans.length.toDouble())),
    ];
  }
}

/// The source of a photo this computer cannot reach, skipped from the start
class _Unreachable implements ConversionSource {
  const _Unreachable(this.name);

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
