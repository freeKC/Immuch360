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
// A 360° photo (a raw one of a 360° camera and a VR180 one among them), a photo with two eyes (side by side by its name
// and frame, one of our 3D photos, a version of ours that holds two, an Apple spatial photo) and the picture of a 3D
// scene or a splat scene are skipped with their reason ("360° and 3D photos come in a later version"): the engine
// writes a flat picture with our XMP only, so the GPano tags or the two eyes would be lost (enhanceSkipOf). A photo
// above 50 megapixels is skipped too, and the levels are judged on the others.
// "Protect faces" of the study is not offered: it needs a face detector, a model this lot does not add.
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
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/desktop_enhance.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_gpu.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
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
  const DesktopEnhanceDialogFacts(this.gate, this.engines, {this.memory = const SystemMemoryProbe()});

  final HardwareGate gate;
  final Map<EnhanceLevel, DesktopEnhanceEngine> engines;
  final MemoryProbe memory;

  @override
  Future<EnhanceMachine> machine() async {
    final facts = AiHardwareFacts.ofThisComputer();
    final read = memory.read();
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

/// A photo of the selection as the dialog read it: where its original is (null when this computer cannot reach it)
class _Photo {
  const _Photo(this.asset, this.found, this.id, {this.skip});

  final BaseAsset asset;
  final ({OriginalLocation location, ConversionSource source})? found;

  /// Its id in the destination session, null for one skipped
  final String? id;

  /// Why it is skipped, known before anything runs; null for one that runs, or one this computer cannot reach
  final ConversionSkipReason? skip;

  (int, int) get size => enhanceSizeOf(asset);
}

/// The size of [asset] as the library knows it, 12 MP when it does not
(int, int) enhanceSizeOf(BaseAsset asset) => switch ((asset.width, asset.height)) {
  (final width?, final height?) when width > 0 && height > 0 => (width, height),
  _ => _unknownSize,
};

/// The reasons to skip a photo that tell a 360° or 3D one, said together in the dialog
const enhanceImmersiveSkips = {
  ConversionSkipReason.sphere360,
  ConversionSkipReason.vr180,
  ConversionSkipReason.raw360,
  ConversionSkipReason.alreadyStereo,
  ConversionSkipReason.spatial,
  ConversionSkipReason.alreadyVersion,
};

/// Why "Enhance (AI)" skips [asset], from its [facts] as the dialog of "Make 3D (AI)" reads them; null when it runs:
///  - a video;
///  - a 360° photo (a raw one of a 360° camera, a VR180 one, a panorama the app generated): the result would be a flat
///    picture of 2:1, its GPano tags lost, and the seam of the sphere would not match;
///  - two eyes (side by side, ours, a version of ours that holds two, an Apple spatial photo): each eye would get
///    other invented details, and the result would be shown flat;
///  - the picture of a 3D scene or a splat scene of ours, which carries its scene: the original is the one to enhance;
///  - above 50 megapixels by the size the library knows (the engine checks the picture it decodes too).
/// An enhanced photo may be enhanced again.
ConversionSkipReason? enhanceSkipOf(BaseAsset asset, ConversionPhotoFacts facts) {
  if (asset.isVideo || !asset.isImage) {
    return ConversionSkipReason.video;
  }
  if (facts.isRaw360) {
    return ConversionSkipReason.raw360;
  }
  final version = facts.version?.kind;
  if (facts.isPanorama || version == ImmersiveKind.panorama360) {
    final half =
        (facts.coverage ?? guessSphereCoverage(fileName: asset.name, width: asset.width, height: asset.height)) ==
        SphereCoverage.half;
    return half ? ConversionSkipReason.vr180 : ConversionSkipReason.sphere360;
  }
  if (facts.isStereo || (facts.version != null && versionHoldsTwoEyes(facts.version!))) {
    return ConversionSkipReason.alreadyStereo;
  }
  if (facts.isSpatial) {
    return ConversionSkipReason.spatial;
  }
  if (facts.version != null && version != ImmersiveKind.enhancedPhoto) {
    return ConversionSkipReason.alreadyVersion;
  }
  final (width, height) = enhanceSizeOf(asset);
  if (width * height > enhanceMaxPixels) {
    return ConversionSkipReason.tooLarge;
  }
  return null;
}

/// The words of a refusal of a level
String enhanceRefusalText(Translations t, EnhanceRefusal refusal) => switch (refusal) {
  EnhanceRefusal.notOnThisSystem => t.ai_enhance_refused_system,
  EnhanceRefusal.macNotYet => t.ai_enhance_refused_mac,
  EnhanceRefusal.intelMacNotChecked => t.ai_enhance_refused_intel_mac,
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

String _levelLine(Translations t, EnhanceLevel level) => switch (level) {
  EnhanceLevel.sharpen => t.ai_enhance_level_sharpen_line,
  EnhanceLevel.rebuild => t.ai_enhance_level_rebuild_line,
  EnhanceLevel.natural => t.ai_enhance_level_natural_line,
};

/// See the top of this file
class EnhanceDialog extends ConsumerStatefulWidget {
  const EnhanceDialog({super.key, required this.assets});

  final List<BaseAsset> assets;

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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_session?.close());
    super.dispose();
  }

  Future<void> _load() async {
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
      if (found != null && isEquirectFrame(asset.width, asset.height)) {
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
      photos.add(_Photo(asset, found, found == null ? null : 'enhance-$index'));
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
    if (!mounted) {
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

  /// Sharpen when it is offered for the photos, else Natural, else Rebuild details
  EnhanceLevel _firstOffered() {
    for (final level in [EnhanceLevel.sharpen, EnhanceLevel.natural, EnhanceLevel.rebuild]) {
      if (_verdict(level).isOffered) {
        return level;
      }
    }
    return EnhanceLevel.sharpen;
  }

  Iterable<_Photo> get _runs => (_photos ?? const []).where((photo) => photo.id != null);

  /// The verdict of [level] for the selection: refused when it is refused for its largest photo. The photos above 50
  /// megapixels are skipped and left out of it, unless no other runs: the levels then say why.
  EnhanceVerdict _verdict(EnhanceLevel level) {
    final machine = _machine;
    if (machine == null) {
      return EnhanceVerdict(level, refusal: EnhanceRefusal.notOnThisSystem);
    }
    var sizes = [for (final photo in _runs) photo.size];
    if (sizes.isEmpty) {
      sizes = [
        for (final photo in _photos ?? const <_Photo>[])
          if (photo.skip == ConversionSkipReason.tooLarge) photo.size,
      ];
    }
    final (width, height) = sizes.isEmpty ? _unknownSize : sizes.reduce((a, b) => a.$1 * a.$2 >= b.$1 * b.$2 ? a : b);
    final largest = enhanceVerdict(level, machine, width: width, height: height);
    if (!largest.isOffered || sizes.length <= 1) {
      return largest;
    }
    final total = enhanceBatchEstimate(level, machine, sizes);
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
    final runs = _runs.toList();
    return runs.isNotEmpty && runs.every((photo) => session.checkOf(photo.id!)?.accepted ?? false);
  }

  Future<void> _launch(DestinationSession session) async {
    if (_launched) {
      return;
    }
    _launched = true;
    final photos = _photos!;
    final requests = <ConversionRequest>[];
    for (final photo in photos) {
      final found = photo.found;
      final plan = photo.id == null ? null : session.destinations[photo.id];
      if (found == null || plan == null || plan.share != null) {
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
            folder: plan.folder,
            fileName: versionTargetName(ImmersiveKind.enhancedPhoto, found.location.name),
          ),
          pixels: width * height,
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
          kind: ConversionKind.enhanceAt(_level),
          existing: ExistingVersionChoice.newVersion,
          enhance: EnhanceSettings(level: _level, strength: _strengths[_level]!),
        );
    final infos = <String, ConversionJobInfo>{};
    for (final (index, id) in ids.indexed) {
      final photo = photos[index];
      final plan = photo.id == null ? null : session.destinations[photo.id];
      final part = photo.id == null ? null : session.takePart(photo.id!);
      if (part != null) {
        output.adopt(id, part);
      }
      infos[id] = ConversionJobInfo(asset: photo.asset, isNetwork: plan?.isNetwork ?? false);
    }
    ref.read(conversionJobInfoProvider.notifier).addAll(infos);
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final photos = _photos;
    final session = _session;
    final count = widget.assets.where((asset) => asset.isImage).length;
    final title = Text(count > 1 ? t.ai_enhance_action_count(count: count) : t.ai_enhance_action);
    if (photos == null || session == null) {
      return AlertDialog(
        key: const Key('ai_enhance_dialog'),
        title: title,
        content: const SizedBox(width: 560, child: LinearProgressIndicator()),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel))],
      );
    }
    final colors = context.colorScheme;
    final secondary = TextStyle(color: colors.onSurfaceVariant);
    final verdict = _verdict(_level);
    final files = _files[_level];
    final runs = _runs.length;
    final immersive = photos.where((photo) => enhanceImmersiveSkips.contains(photo.skip)).length;
    final tooLarge = photos.where((photo) => photo.skip == ConversionSkipReason.tooLarge).length;
    final skipped = photos.length - runs - immersive - tooLarge;
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
                  _level.onGraphicsCard ? t.ai_enhance_estimate_card : t.ai_enhance_estimate_processor,
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
              if (immersive > 0)
                Text(
                  t.ai_enhance_skipped_immersive(count: immersive),
                  key: const Key('ai_enhance_skipped_immersive'),
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
    final reason = switch (verdict.refusal) {
      final refusal? => enhanceRefusalText(t, refusal),
      null when files?.notInThisVersion ?? false => t.ai_enhance_refused_not_yet,
      null => null,
    };
    final chosen = level == _level;
    return ListTile(
      key: Key('ai_enhance_level_${level.name}'),
      contentPadding: EdgeInsets.zero,
      enabled: verdict.isOffered,
      selected: chosen,
      leading: Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(enhanceLevelName(t, level)),
      subtitle: Text(reason == null ? _levelLine(t, level) : '${_levelLine(t, level)}\n$reason'),
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

  List<Widget> _destinationPart(Translations t, DestinationSession session, TextStyle secondary) {
    final plans = [for (final photo in _runs) ?session.destinations[photo.id]];
    if (plans.isEmpty) {
      return const [];
    }
    final beside = plans.every((plan) => plan.kind == DestinationKind.nextToOriginal);
    return [
      if (beside)
        Text(t.ai_enhance_saved_beside, key: const Key('ai_enhance_saved_beside'))
      else ...[
        Text(t.ai_enhance_saved_folder(folder: session.chosenFolder), key: const Key('ai_enhance_saved_folder')),
        if (plans.any((plan) => plan.reason == DestinationReason.sourceReadOnly))
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
        Text(t.ai_immersive_network_root_ask),
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
