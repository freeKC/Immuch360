// "Make 3D (AI)" on a computer (design-final 2026-10-26, section 5, points 1 to 3): the entry in the menu of the viewer
// and in the bottom sheet of a selection, and the dialog that launches the conversions.
//
// The entry is absent while the AI features are off (Settings, This computer, AI and 3D). It is greyed with its reason
// when this computer cannot run them (the hardware gate: system, processor, memory, ONNX Runtime that does not load);
// missing components do not grey it, the dialog offers to install them. In the viewer it is offered for a flat photo
// only.
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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ConversionDialog');

/// The AI features, on or off (Settings, This computer, AI and 3D): off, no AI button anywhere
final aiFeaturesEnabledProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(appConfigProvider.select((config) => config.aiImmersive.enabled)),
);

/// What the hardware gate says now; asked again when a component is installed or removed
final aiGateResultProvider = FutureProvider.autoDispose<AiGateResult>((ref) async {
  final service = ref.watch(aiComponentsServiceProvider);
  final gate = ref.watch(desktopAiGateProvider);
  String states() => [for (final component in aiComponents) service.statusOf(component).state.name].join(',');
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
  return gate.evaluate();
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
};

/// The words of a reason to skip a photo
String conversionSkipText(Translations t, ConversionSkipReason reason, {String? name}) => switch (reason) {
  ConversionSkipReason.video => t.ai_immersive_skipped_video,
  ConversionSkipReason.sphere360 => t.ai_immersive_skipped_360,
  ConversionSkipReason.vr180 => t.ai_immersive_skipped_vr180,
  ConversionSkipReason.spatial => t.ai_immersive_skipped_spatial,
  ConversionSkipReason.alreadyStereo => t.ai_immersive_skipped_3d,
  ConversionSkipReason.unreadableFormat => t.ai_immersive_unavailable_format,
  ConversionSkipReason.sameSettingsExists => t.ai_immersive_skipped_same_settings,
  ConversionSkipReason.nameTaken => t.ai_immersive_exists(name: name ?? ''),
  ConversionSkipReason.unreachable => t.ai_immersive_failed_source,
};

/// What the dialog needs to know of a photo before anything runs: whether it is shown as a sphere, holds two eyes
/// already, is an Apple spatial photo, and how many quarter turns the user sees it with
class ConversionPhotoFacts {
  const ConversionPhotoFacts({
    this.isPanorama = false,
    this.isStereo = false,
    this.isSpatial = false,
    this.quarterTurns = 0,
  });

  final bool isPanorama;
  final bool isStereo;
  final bool isSpatial;
  final int quarterTurns;
}

/// Reads the facts of a photo
typedef ConversionFactsReader = Future<ConversionPhotoFacts> Function(BaseAsset asset);

/// The facts as the viewers know them: the 360° rules, the index of the library and the rule of the name and frame
/// for two eyes side by side, the Apple spatial probe for a HEIF photo, the turns the viewer draws. The providers that
/// read a file are listened to while they do, so that they live until they answer.
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
    final localId = asset.localId;
    var origins = const <String, Object>{};
    try {
      origins = await answer(generatedOriginsProvider.future);
    } catch (error) {
      _log.fine('The origins of the library are not known: $error');
    }
    final isStereo =
        (localId != null && origins.containsKey(localId)) ||
        decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) != null;
    var isSpatial = false;
    if (asset.isImage && isHeifName(asset.name) && !Platform.isLinux) {
      try {
        isSpatial =
            (await answer(appleSpatialInfoProvider(asset).future).timeout(const Duration(seconds: 10)))?.photo != null;
      } catch (error) {
        _log.fine('${asset.name} could not be read for a spatial photo: $error');
      }
    }
    return ConversionPhotoFacts(
      isPanorama: ref.read(isPanoramaProvider(asset)),
      isStereo: isStereo,
      isSpatial: isSpatial,
      quarterTurns: ref.read(displayQuarterTurnsProvider(asset)),
    );
  };
});

/// Where the original of a photo of the app is for a conversion; the tests give their own
abstract interface class ConversionAssetFiles {
  /// The original of [asset] and the source its job reads, null when this computer cannot reach it
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset);
}

/// A file opened with the program, a file of the folder library, or the original of a photo of the server
class DesktopConversionAssetFiles implements ConversionAssetFiles {
  const DesktopConversionAssetFiles();

  @override
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset) async {
    final localId = asset.localId;
    if (localId != null) {
      final opened = OpenedFiles.file(localId);
      if (opened != null) {
        return (
          location: OpenedOriginal(name: opened.name, path: opened.path),
          source: LocalFileSource(opened.path, exif: _exifOf(asset)),
        );
      }
      try {
        final library = await FolderLibrary.shared();
        final original = LibraryOriginal.of(library, localId);
        if (original != null && (library.file(localId)?.available ?? false)) {
          return (location: original, source: LocalFileSource(original.path, exif: _exifOf(asset)));
        }
      } catch (error, stack) {
        _log.warning('The file of ${asset.name} is not found in the library', error, stack);
      }
    }
    final remoteId = asset is RemoteAsset ? asset.id : null;
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
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
ImmersiveExif _exifOf(BaseAsset asset) {
  final name = asset.name.toLowerCase();
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
    return const ImmersiveExif();
  }
  final date = asset.createdAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return ImmersiveExif(
    dateTimeOriginal:
        '${date.year}:${two(date.month)}:${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}',
  );
}

final conversionAssetFilesProvider = Provider<ConversionAssetFiles>((ref) => const DesktopConversionAssetFiles());

/// The DestinationSession of a dialog (lot A5b); the tests give theirs
typedef DestinationSessionFactory =
    DestinationSession Function(List<DestinationJob> jobs, DesktopAiSettingsStore store);

final destinationSessionFactoryProvider = Provider<DestinationSessionFactory>(
  (ref) =>
      (jobs, store) => DestinationSession(jobs, store: store),
);

/// A photo of the selection as the dialog sees it
class ConversionCandidate {
  const ConversionCandidate({
    required this.asset,
    required this.source,
    this.location,
    this.skip,
    this.quarterTurns = 0,
    this.id,
  });

  final BaseAsset asset;
  final ConversionSource source;
  final OriginalLocation? location;
  final ConversionSkipReason? skip;
  final int quarterTurns;

  /// Its id in the destination session of the dialog, null for a photo skipped
  final String? id;

  bool get runs => skip == null;
}

/// The reason to skip [asset] known before anything runs, from its [facts], null when it is converted. [linux]: no
/// decoder for HEIF and AVIF there.
ConversionSkipReason? conversionSkipOf(BaseAsset asset, ConversionPhotoFacts facts, {bool? linux}) {
  if (asset.isVideo || !asset.isImage) {
    return ConversionSkipReason.video;
  }
  if (facts.isPanorama) {
    final half = guessSphereCoverage(fileName: asset.name, width: asset.width, height: asset.height);
    return half == SphereCoverage.half ? ConversionSkipReason.vr180 : ConversionSkipReason.sphere360;
  }
  if (facts.isStereo) {
    return ConversionSkipReason.alreadyStereo;
  }
  if (facts.isSpatial) {
    return ConversionSkipReason.spatial;
  }
  final name = asset.name.toLowerCase();
  if ((linux ?? Platform.isLinux) && (isHeifName(name) || name.endsWith('.avif'))) {
    return ConversionSkipReason.unreadableFormat;
  }
  return null;
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

/// Whether the viewer offers "Make 3D (AI)" for [asset]: a flat photo, neither 360° nor two eyes side by side
final aiFlatPhotoProvider = Provider.autoDispose.family<bool, BaseAsset>((ref, asset) {
  if (!asset.isImage || ref.watch(isPanoramaProvider(asset))) {
    return false;
  }
  final localId = asset.localId;
  final made =
      localId != null && ref.watch(generatedOriginsProvider.select((origins) => origins.valueOrNull?[localId])) != null;
  return !made && decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) == null;
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
    if (source == ActionSource.viewer && !ref.watch(aiFlatPhotoProvider(assets.first))) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final gate = ref.watch(aiGateResultProvider).valueOrNull;
    final refusal = aiGateRefuses(gate) ? aiGateReasonText(t, gate!) : null;
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

/// Opens the conversion dialog for [assets]; once photos were handed to the queue, the panel of the conversions shows
/// and the selection ends
Future<void> openConversionDialog(
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
    builder: (context) => ConversionDialog(assets: assets),
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
  const ConversionDialog({super.key, required this.assets});

  final List<BaseAsset> assets;

  @override
  ConsumerState<ConversionDialog> createState() => _ConversionDialogState();
}

class _ConversionDialogState extends ConsumerState<ConversionDialog> {
  late final DesktopAiSettingsStore _store = ref.read(desktopAiSettingsStoreProvider);
  List<ConversionCandidate>? _candidates;
  DestinationSession? _session;
  DesktopAiSettings _settings = const DesktopAiSettings();
  ExistingVersionChoice _existing = ExistingVersionChoice.skip;
  AiDestination _saveTo = AiDestination.nextToOriginal;

  /// False while the album of the generated photos is not out of the backup: no folder of the library then
  var _libraryReady = true;
  var _gestures = 0;
  var _launched = false;
  var _closed = false;

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
  }

  Future<void> _prepare() async {
    _settings = await _store.read();
    _existing = _settings.skipExisting ? ExistingVersionChoice.skip : ExistingVersionChoice.newVersion;
    final facts = ref.read(conversionFactsReaderProvider);
    final files = ref.read(conversionAssetFilesProvider);
    final candidates = <ConversionCandidate>[];
    for (final (index, asset) in widget.assets.indexed) {
      final known = await facts(asset);
      final skip = conversionSkipOf(asset, known);
      final found = skip == null ? await files.locate(asset) : null;
      if (skip != null || found == null) {
        candidates.add(
          ConversionCandidate(
            asset: asset,
            source: _SkippedSource(asset.name),
            skip: skip ?? ConversionSkipReason.unreachable,
          ),
        );
        continue;
      }
      candidates.add(
        ConversionCandidate(
          asset: asset,
          source: found.source,
          location: found.location,
          quarterTurns: known.quarterTurns,
          id: 'photo-$index',
        ),
      );
    }

    // No folder of the library is checked nor written into before the album of the versions is out of the backup
    final guard = ref.read(aiWriteGuardProvider);
    final libraryFolders = {
      for (final candidate in candidates)
        if (candidate.location case LibraryOriginal(:final path)) p.dirname(path),
    };
    for (final folder in libraryFolders) {
      if (!await guard(folder)) {
        _libraryReady = false;
        break;
      }
    }
    _saveTo = _libraryReady ? _settings.destination : AiDestination.folder;

    final jobs = [
      for (final candidate in candidates)
        if (candidate.runs) DestinationJob(id: candidate.id!, original: candidate.location!),
    ];
    final session = jobs.isEmpty
        ? null
        : ref.read(destinationSessionFactoryProvider)(jobs, _libraryReady ? _store : _ChosenFolderStore(_store));
    if (!mounted || _closed) {
      return;
    }
    setState(() {
      _candidates = candidates;
      _session = session;
    });
    if (session != null) {
      await _gesture(session.open);
    }
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
      await _gesture(() => session.chooseFolder(picked!));
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

  /// Whether every photo that runs has a folder that may receive its 3D photo
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
    if (_launched) {
      return;
    }
    _launched = true;
    final candidates = _candidates!;
    final settings = await _store.read();
    final requests = <ConversionRequest>[];
    for (final candidate in candidates) {
      final plan = candidate.runs ? session.destinations[candidate.id] : null;
      requests.add(
        plan == null
            ? ConversionRequest(source: candidate.source, skip: candidate.skip ?? ConversionSkipReason.unreachable)
            : ConversionRequest(
                source: candidate.source,
                target: ConversionTarget(folder: plan.folder, fileName: sbsTargetName(candidate.location!.name)),
                quarterTurns: candidate.quarterTurns,
              ),
      );
    }
    // The version of the app goes into each 3D photo
    await ref.read(aiAppVersionProvider.future);
    final output = ref.read(safeWriterOutputProvider);
    final ids = ref
        .read(conversionQueueProvider.notifier)
        .add(requests, existing: _existing, whenExists: settings.whenExists);
    final infos = <String, ConversionJobInfo>{};
    for (final (index, candidate) in candidates.indexed) {
      final id = ids[index];
      final plan = candidate.id == null ? null : session.destinations[candidate.id];
      final part = candidate.id == null ? null : session.takePart(candidate.id!);
      if (part != null) {
        output.adopt(id, part);
      }
      infos[id] = ConversionJobInfo(
        asset: candidate.asset,
        isNetwork: plan?.isNetwork ?? false,
        serverEdits: candidate.location is ServerOriginal && candidate.asset.isEdited,
      );
    }
    ref.read(conversionJobInfoProvider.notifier).addAll(infos);
    _close();
    if (settings.skipExisting != (_existing == ExistingVersionChoice.skip)) {
      unawaited(_store.update((kept) => kept.copyWith(skipExisting: _existing == ExistingVersionChoice.skip)));
    }
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final gate = ref.watch(aiGateResultProvider);
    final candidates = _candidates;
    final session = _session;
    final found = gate.valueOrNull;
    final refused = aiGateRefuses(found);
    final missing = found != null && !found.isAvailable && !refused;
    final busy = _gestures > 0 || candidates == null;
    final canConvert = !busy && found != null && found.isAvailable && session != null && _ready(session);
    final skipped = candidates?.where((candidate) => !candidate.runs).toList() ?? const <ConversionCandidate>[];
    final count = widget.assets.length;

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
              Text(t.ai_immersive_dialog_title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(t.ai_immersive_no_guarantee, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              if (gate.isLoading || candidates == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (refused)
                _Note(key: const Key('ai_conversion_refused'), text: aiGateReasonText(t, found!), error: true),
              if (missing && found.platform != null)
                Card(
                  key: const Key('ai_conversion_install'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: AiInstallPanel(
                      components: aiComponentsFor(found.platform!),
                      onInstalled: () => ref.invalidate(aiGateResultProvider),
                    ),
                  ),
                ),
              if (candidates != null && !refused) ...[
                if (session != null) ..._destination(t, session),
                if (session != null) ..._existingChoice(t),
                if (_runs.any((candidate) => candidate.quarterTurns != 0))
                  _Note(key: const Key('ai_conversion_rotation'), text: t.ai_immersive_rotation_applied),
                if (_runs.any((candidate) => candidate.location is ServerOriginal && candidate.asset.isEdited))
                  _Note(key: const Key('ai_conversion_server_edits'), text: t.ai_immersive_server_edits_ignored),
                if (skipped.isNotEmpty) _SkippedList(skipped: skipped),
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
      (candidate) => candidate.location is LibraryOriginal || candidate.location is OpenedOriginal,
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
          onNo: _gestures == 0 ? () => unawaited(_gesture(() => session.declineNetwork(key))) : null,
        ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _existingChoice(Translations t) => [
    Text(t.ai_immersive_existing, style: Theme.of(context).textTheme.titleSmall),
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
            (ExistingVersionChoice.skip, t.ai_immersive_existing_skip),
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

/// The photos that will be skipped, each with why
class _SkippedList extends StatelessWidget {
  const _SkippedList({required this.skipped});

  final List<ConversionCandidate> skipped;

  /// More than this many are counted, not listed
  static const _listed = 20;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const Key('ai_conversion_skipped'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('${t.ai_immersive_state_skipped} (${skipped.length})', style: Theme.of(context).textTheme.titleSmall),
        for (final candidate in skipped.take(_listed))
          Text(
            '${candidate.asset.name}: ${conversionSkipText(t, candidate.skip!)}',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        if (skipped.length > _listed) Text('…', style: TextStyle(color: colors.onSurfaceVariant)),
      ],
    );
  }
}
