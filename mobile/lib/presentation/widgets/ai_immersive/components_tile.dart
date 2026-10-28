// The AI components of this device in the settings (design-final 2026-10-26, sections 2.2, 4.6 and 5; spec 5.2: know
// the space they take, remove them): each component with its name, its licence (a link), its state and sizes (to
// download and on the disk before the installation, from the catalogue), Remove; then the space the folder really
// takes and Remove all. Shared by the computers ("AI and 3D" of This computer, lot A5c) and the Meta Quest (its
// advanced settings, lot A9b), which pass the components of their system and the way to cancel what uses them.
//
// A removal is refused while a conversion runs: the tile asks whether to cancel it, then removes. A file the system
// keeps (a loaded DLL on Windows) is freed at the next start, which the row and a message say. Nothing is downloaded
// from here unless the user taps Download, which opens the install sheet.
//
// On a computer (design-final 2026-10-27, sections 7.1 and 9.1) the tile is given its system and shows the groups of
// features: "3D photos: 116 MB", "3D scenes: 349 MB", and the 360° panoramas once their engine is in the catalogue.
// Each component is listed under the first group that needs it; Download and Remove act on a whole group, and a
// component another installed group needs stays, its row saying which ("Kept while 3D scenes use it"). The Quest keeps
// the one list of phase 1.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('AiComponentsTile');

/// See the top of this file. [components] are those of this system (aiComponentsFor); [onCancelConversions] stops
/// what uses them (the conversions on a computer, the relief on the Quest), offered when a removal is refused. Its
/// future must complete only once nothing uses the components any more (the queue stopped, the ONNX Runtime session
/// or the relief closed): the tile tries the removal once more right after, and when that try is refused too, it says
/// the conversion is still stopping and removes nothing. [canDownload] false (the AI features off) leaves Remove only.
class AiComponentsTile extends ConsumerStatefulWidget {
  const AiComponentsTile({
    super.key,
    this.components = const [],
    required this.onCancelConversions,
    this.canDownload = true,
    this.platform,
  });

  /// The one list of a system without groups (the Quest)
  final List<AiComponent> components;

  /// The system whose groups of features are shown (a computer); [components] is then left aside
  final AiPlatform? platform;
  final Future<void> Function() onCancelConversions;
  final bool canDownload;

  @override
  ConsumerState<AiComponentsTile> createState() => _AiComponentsTileState();
}

class _AiComponentsTileState extends ConsumerState<AiComponentsTile> {
  late final AiComponentsService _service = ref.read(aiComponentsServiceProvider);

  /// The space the folder really takes, the .part files included; null until measured
  int? _spaceUsed;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await _service.load();
      final used = await _service.spaceUsed();
      if (mounted) {
        setState(() => _spaceUsed = used);
      }
    } catch (error, stack) {
      _log.warning('the components folder could not be read', error, stack);
    }
  }

  /// Removes [component], or every component when null; asks to cancel the conversions when one runs
  Future<void> _remove(AiComponent? component) =>
      _removeWith(() => component == null ? _service.removeAll() : _service.remove(component));

  /// Removes the components of [group], those another installed group needs apart
  Future<void> _removeGroup(AiFeatureGroup group) =>
      _removeWith(() async => (await _service.removeGroup(widget.platform!, group)).outcome);

  Future<void> _removeWith(Future<AiRemoveOutcome> Function() attempt) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _removing = true);
    try {
      var outcome = await attempt();
      if (outcome == AiRemoveOutcome.busy) {
        if (!mounted || !await _askToCancel()) {
          return;
        }
        await widget.onCancelConversions();
        outcome = await attempt();
      }
      final message = switch (outcome) {
        AiRemoveOutcome.removed => null,
        AiRemoveOutcome.nextStart => t.ai_immersive_removed_next_start,
        // Only after Yes: what used the components had not stopped yet
        AiRemoveOutcome.busy => t.ai_immersive_components_still_busy,
        AiRemoveOutcome.writeFailed => t.ai_immersive_remove_failed,
      };
      if (message != null) {
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() => _removing = false);
      }
      await _refresh();
    }
  }

  Future<bool> _askToCancel() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(context.t.ai_immersive_components_busy),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.no)),
          TextButton(
            key: const Key('ai_components_cancel_conversions'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.yes),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> _install(List<AiComponent> missing) async {
    await showAiInstallSheet(context, missing);
    await _refresh();
  }

  /// A group: its title and size, Download and Remove, then the components it brings
  Widget _group(BuildContext context, AiPlatform platform, AiGroupComponents group) {
    final t = context.t;
    final missing = aiMissingComponents(_service, group.all);
    final removable = group.own.any((component) {
      final state = _service.statusOf(component).state;
      return state == AiComponentState.installed || state == AiComponentState.damaged;
    });
    final name = group.group.name;
    return Column(
      key: Key('ai_components_group_$name'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(aiFeatureGroupTitle(t, group), style: const TextStyle(fontWeight: FontWeight.w500)),
          trailing: Wrap(
            spacing: 4,
            children: [
              if (missing.isNotEmpty && widget.canDownload)
                TextButton(
                  key: Key('ai_components_group_download_$name'),
                  onPressed: () => unawaited(_install(missing)),
                  child: Text(t.ai_immersive_download),
                ),
              if (removable)
                IconButton(
                  key: Key('ai_components_group_remove_$name'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: t.ai_immersive_remove,
                  onPressed: _removing ? null : () => unawaited(_removeGroup(group.group)),
                ),
            ],
          ),
        ),
        for (final component in group.own)
          _ComponentRow(
            component: component,
            status: _service.statusOf(component),
            onRemove: null,
            inGroup: true,
            keptFor: _service.groupsUsing(platform, component, besides: group.group).firstOrNull,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final platform = widget.platform;
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final groups = platform == null ? null : aiComponentGroupsFor(platform, catalogue: _service.catalogue);
        final missing = groups == null ? aiMissingComponents(_service, widget.components) : const <AiComponent>[];
        final used = _spaceUsed;
        final hasFiles = used != null && used > 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('ai_components_total'),
              leading: const Icon(Icons.memory_rounded),
              title: Text(t.ai_immersive_components, style: const TextStyle(fontWeight: FontWeight.w500)),
              subtitle: used == null ? null : Text(t.ai_immersive_components_total(size: formatBytes(used))),
            ),
            if (groups == null)
              for (final component in widget.components)
                _ComponentRow(
                  component: component,
                  status: _service.statusOf(component),
                  onRemove: _removing ? null : () => unawaited(_remove(component)),
                )
            else
              for (final group in groups) _group(context, platform!, group),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (missing.isNotEmpty && widget.canDownload)
                    TextButton(
                      key: const Key('ai_components_download'),
                      onPressed: () => unawaited(_install(missing)),
                      child: Text(t.ai_immersive_download),
                    ),
                  if (hasFiles)
                    TextButton(
                      key: const Key('ai_components_remove_all'),
                      onPressed: _removing ? null : () => unawaited(_remove(null)),
                      child: Text(t.ai_immersive_remove_all),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The name of a group of features, as the line of a shared component says it
String aiFeatureGroupName(Translations t, AiFeatureGroup group) => switch (group) {
  AiFeatureGroup.photos => t.ai_immersive_feature_photos,
  AiFeatureGroup.scenes => t.ai_immersive_feature_scenes,
  AiFeatureGroup.panoramas => t.ai_immersive_feature_panoramas,
};

/// "3D scenes: 349 MB", the size of the components a group brings itself, from the catalogue
String aiFeatureGroupTitle(Translations t, AiGroupComponents group) {
  final size = formatBytes(AiComponentsService.diskBytesOf(group.own));
  return switch (group.group) {
    AiFeatureGroup.photos => t.ai_immersive_components_photos(size: size),
    AiFeatureGroup.scenes => t.ai_immersive_components_scenes(size: size),
    AiFeatureGroup.panoramas => t.ai_immersive_components_panoramas(size: size),
  };
}

class _ComponentRow extends StatelessWidget {
  const _ComponentRow({
    required this.component,
    required this.status,
    required this.onRemove,
    this.inGroup = false,
    this.keptFor,
  });

  final AiComponent component;
  final AiComponentStatus status;

  final VoidCallback? onRemove;

  /// In a group, which is removed as a whole: no Remove of its own
  final bool inGroup;

  /// The installed group that keeps this component when its own group goes
  final AiFeatureGroup? keptFor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final error = TextStyle(color: Theme.of(context).colorScheme.error);
    final total = status.total;
    final fraction = total == null || total == 0 ? null : (status.received / total).clamp(0.0, 1.0);
    final failure = status.failure;
    final lines = <Widget>[
      ...switch (status.state) {
        AiComponentState.installed => [Text(t.ai_immersive_size_on_disk(size: formatBytes(_diskBytes)))],
        AiComponentState.notInstalled => [
          Text(t.ai_immersive_component_not_installed),
          Text(aiComponentSizes(t, component)),
        ],
        AiComponentState.downloading => [
          Text(t.ai_immersive_downloading(name: component.title, percent: ((fraction ?? 0) * 100).floor())),
          LinearProgressIndicator(value: fraction),
        ],
        AiComponentState.damaged => [Text(t.ai_immersive_component_damaged, style: error)],
        AiComponentState.removedNextStart => [Text(t.ai_immersive_removed_next_start)],
      },
      if (failure != null && status.state != AiComponentState.downloading)
        Text(aiDownloadFailureText(t, failure), style: error),
      if (keptFor != null && status.state == AiComponentState.installed)
        Text(t.ai_immersive_component_shared(feature: aiFeatureGroupName(t, keptFor!))),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: AiLicenceLink(component: component),
      ),
    ];
    final removable =
        !inGroup && (status.state == AiComponentState.installed || status.state == AiComponentState.damaged);
    return ListTile(
      key: Key('ai_component_${component.id}'),
      title: Text(component.title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
      trailing: removable
          ? IconButton(
              key: Key('ai_component_remove_${component.id}'),
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: t.ai_immersive_remove,
              onPressed: onRemove,
            )
          : null,
    );
  }

  /// The space of the installed component: its file and its notices, as the catalogue gives them and the service
  /// checks at each load
  int get _diskBytes => AiComponentsService.diskBytesOf([component]);
}
