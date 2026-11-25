// The updates of the AI components on a computer (issue 21, store/m2/release-52/ai-components-update-2026-11-24.md):
// - a button in the app bar of the home pages, beside the one of the conversions, once an installed component has a
//   newer version: its badge counts them, its tooltip says "3 AI components can be updated, 1.2 GiB", a click opens
//   the panel of the updates; while they download it shows their progress;
// - a badge on "This computer" in the list of the settings, and the same panel at the top of "AI and 3D": the line of
//   the updates with Update all, the progress with Pause and Resume, what a failure or no connection left (the
//   installed versions stay), and the files no component needs any more, with their size and Remove;
// - the automatic update once the main page shows, when "Update AI components automatically" is on (the default),
//   never on a metered connection nor above aiUpdateConfirmBytes, which ask the user first.
// Nothing is asked of any server but the releases the components already come from.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_settings_section.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/platform/metered_connection.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_updater.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('AiUpdates');

/// Whether the connection is metered now; replaced in tests
final aiMeteredConnectionProvider = Provider<Future<bool?> Function()>((ref) => desktopMeteredConnection);

/// The updates of the AI components of this computer
final aiComponentsUpdaterProvider = Provider<AiComponentsUpdater>((ref) {
  final updater = AiComponentsUpdater(
    service: ref.watch(aiComponentsServiceProvider),
    platform: ref.watch(aiPlatformProvider),
    metered: ref.watch(aiMeteredConnectionProvider),
    // The engines kept between two conversions hold ONNX Runtime and their models: let go, as a move does
    beforeUpdate: () async {
      if (ref.read(conversionQueueProvider).current == null) {
        await Future.wait([for (final engine in ref.read(keptAiEnginesProvider)) engine.release()]);
      }
    },
  );
  ref.onDispose(updater.dispose);
  return updater;
});

/// The automatic update once the main page shows (desktop_shell.dart): nothing while the AI features are off, and
/// only what [AiComponentsUpdater.automatic] allows
Future<AiUpdateOutcome> runAiUpdatesAtStart(WidgetRef ref) async {
  try {
    if (!ref.read(aiFeaturesEnabledProvider)) {
      return AiUpdateOutcome.notStarted;
    }
    final settings = await ref.read(desktopAiSettingsStoreProvider).read();
    return await ref.read(aiComponentsUpdaterProvider).automatic(enabled: settings.autoUpdateComponents);
  } catch (error, stack) {
    _log.warning('the automatic update of the AI components did not run', error, stack);
    return AiUpdateOutcome.notStarted;
  }
}

/// "3 AI components can be updated, 1.2 GiB"
String aiUpdatesLine(Translations t, AiComponentsUpdater updater) =>
    t.ai_immersive_updates_available(count: updater.updates.length, size: formatBytes(updater.updateBytes));

/// Asks before an update that downloads a lot or goes over a metered connection; true to go on
Future<bool> confirmAiUpdate(BuildContext context, AiUpdateAsk ask) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) {
      final t = context.t;
      final size = formatBytes(ask.bytes);
      return AlertDialog(
        key: const Key('ai_update_confirm'),
        title: Text(t.ai_immersive_update_confirm_title),
        content: Text(
          ask.metered
              ? t.ai_immersive_update_confirm_metered(size: size)
              : t.ai_immersive_update_confirm_large(size: size),
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel)),
          FilledButton(
            key: const Key('ai_update_confirm_yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.ai_immersive_update),
          ),
        ],
      );
    },
  );
  return answer ?? false;
}

/// Updates every component, or [only] that one, asking first when the updater says so
Future<AiUpdateOutcome> startAiUpdate(BuildContext context, AiComponentsUpdater updater, {AiComponent? only}) async {
  Future<AiUpdateOutcome> run({required bool confirmed}) =>
      only == null ? updater.updateAll(confirmed: confirmed) : updater.update(only, confirmed: confirmed);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final t = context.t;
  var outcome = await run(confirmed: false);
  if (outcome == AiUpdateOutcome.needsConfirmation) {
    final bytes = only == null ? updater.updateBytes : AiComponentsService.downloadBytesOf([only]);
    final ask = await updater.askFor(bytes);
    if (!context.mounted || (ask != null && !await confirmAiUpdate(context, ask))) {
      return AiUpdateOutcome.notStarted;
    }
    outcome = await run(confirmed: true);
  }
  if (outcome == AiUpdateOutcome.busy) {
    messenger?.showSnackBar(SnackBar(content: Text(t.ai_immersive_updates_busy)));
  }
  return outcome;
}

/// The panel of the updates; see the top of this file. [always] shows "AI components are up to date" when there is
/// nothing to say (the settings), else nothing at all.
class AiUpdatesPanel extends ConsumerStatefulWidget {
  const AiUpdatesPanel({super.key, this.always = false, this.canDownload = true});

  final bool always;

  /// False while the AI features are off: what is unused can still be removed, nothing is downloaded
  final bool canDownload;

  @override
  ConsumerState<AiUpdatesPanel> createState() => _AiUpdatesPanelState();
}

class _AiUpdatesPanelState extends ConsumerState<AiUpdatesPanel> {
  late final AiComponentsUpdater _updater = ref.read(aiComponentsUpdaterProvider);
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    if (!_updater.isRunning) {
      unawaited(_updater.refresh());
    }
  }

  Future<void> _removeUnused() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _removing = true);
    try {
      final outcome = await _updater.removeUnused();
      final message = switch (outcome) {
        AiRemoveOutcome.removed => null,
        AiRemoveOutcome.nextStart => t.ai_immersive_removed_next_start,
        AiRemoveOutcome.busy => t.ai_immersive_updates_busy,
        AiRemoveOutcome.writeFailed => t.ai_immersive_remove_failed,
      };
      if (message != null) {
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() => _removing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _updater,
    builder: (context, _) {
      final t = context.t;
      final theme = Theme.of(context);
      final error = TextStyle(color: theme.colorScheme.error);
      final updater = _updater;
      final phase = updater.phase;
      final total = updater.totalBytes;
      final fraction = total == 0 ? null : (updater.receivedBytes / total).clamp(0.0, 1.0);
      final progress = (done: formatBytes(updater.receivedBytes), total: formatBytes(total));
      final failure = updater.failure;
      final unused = updater.unused;
      final rows = <Widget>[
        if (phase == AiUpdatePhase.running) ...[
          ListTile(
            key: const Key('ai_updates_running'),
            leading: const Icon(Icons.downloading_rounded),
            title: Text(
              t.ai_immersive_updates_progress(
                name: updater.current?.title ?? '',
                done: progress.done,
                total: progress.total,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: fraction),
            ),
            trailing: TextButton(key: const Key('ai_updates_pause'), onPressed: updater.pause, child: Text(t.pause)),
          ),
        ] else if (phase == AiUpdatePhase.paused)
          ListTile(
            key: const Key('ai_updates_paused'),
            leading: const Icon(Icons.pause_circle_outline_rounded),
            title: Text(t.ai_immersive_updates_paused(done: progress.done, total: progress.total)),
            trailing: TextButton(
              key: const Key('ai_updates_resume'),
              onPressed: widget.canDownload ? () => unawaited(updater.resume()) : null,
              child: Text(t.ai_immersive_resume),
            ),
          )
        else if (updater.updates.isNotEmpty)
          ListTile(
            key: const Key('ai_updates_available'),
            leading: const Icon(Icons.system_update_alt_rounded),
            title: Text(aiUpdatesLine(t, updater)),
            subtitle: Text(t.ai_immersive_update_kept),
            trailing: FilledButton(
              key: const Key('ai_updates_update_all'),
              onPressed: widget.canDownload ? () => unawaited(startAiUpdate(context, updater)) : null,
              child: Text(t.ai_immersive_update_all),
            ),
          ),
        if (phase == AiUpdatePhase.failed) ...[
          if (updater.outcome == AiUpdateOutcome.offline)
            ListTile(
              key: const Key('ai_updates_offline'),
              title: Text(t.ai_immersive_updates_offline, style: error),
            )
          else
            ListTile(
              key: const Key('ai_updates_failed'),
              title: Text(
                updater.failed.isEmpty
                    ? (failure == null ? '' : aiDownloadFailureText(t, failure))
                    : t.ai_immersive_updates_failed(count: updater.failed.length),
                style: error,
              ),
              subtitle: updater.failed.isEmpty || failure == null ? null : Text(aiDownloadFailureText(t, failure)),
            ),
        ],
        if (phase == AiUpdatePhase.done && updater.updates.isEmpty)
          ListTile(
            key: const Key('ai_updates_done'),
            leading: const Icon(Icons.check_circle_outline_rounded),
            title: Text(t.ai_immersive_updates_done),
          )
        else if (widget.always && updater.updates.isEmpty && phase == AiUpdatePhase.idle)
          ListTile(
            key: const Key('ai_updates_none'),
            leading: const Icon(Icons.check_circle_outline_rounded),
            title: Text(t.ai_immersive_updates_none),
          ),
        if (unused.bytes > 0)
          ListTile(
            key: const Key('ai_updates_unused'),
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(t.ai_immersive_unused_files(size: formatBytes(unused.bytes))),
            trailing: TextButton(
              key: const Key('ai_updates_remove_unused'),
              onPressed: _removing || updater.isRunning ? null : () => unawaited(_removeUnused()),
              child: Text(t.ai_immersive_remove),
            ),
          ),
      ];
      return Column(key: const Key('ai_updates_panel'), crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    },
  );
}

/// Shows the panel of the updates in a dialog
Future<void> showAiUpdatesDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(context.t.ai_immersive_components),
    content: const SizedBox(width: 520, child: SingleChildScrollView(child: AiUpdatesPanel(always: true))),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.close))],
  ),
);

/// The button of the app bar: shown while an update can be made or runs, and the AI features are on
class AiUpdatesBarButton extends ConsumerWidget {
  const AiUpdatesBarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiFeaturesEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final updater = ref.watch(aiComponentsUpdaterProvider);
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final t = context.t;
        final phase = updater.phase;
        final running = phase == AiUpdatePhase.running;
        if (updater.updates.isEmpty && !running && phase != AiUpdatePhase.paused) {
          return const SizedBox.shrink();
        }
        final total = updater.totalBytes;
        final tooltip = running
            ? t.ai_immersive_updates_progress(
                name: updater.current?.title ?? '',
                done: formatBytes(updater.receivedBytes),
                total: formatBytes(total),
              )
            : phase == AiUpdatePhase.paused
            ? t.ai_immersive_updates_paused(done: formatBytes(updater.receivedBytes), total: formatBytes(total))
            : aiUpdatesLine(t, updater);
        return IconButton(
          key: const Key('ai_updates_button'),
          tooltip: tooltip,
          onPressed: () => unawaited(showAiUpdatesDialog(context)),
          icon: running
              ? SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    value: total == 0 ? null : (updater.receivedBytes / total).clamp(0.0, 1.0),
                  ),
                )
              : Badge(
                  isLabelVisible: updater.updates.isNotEmpty,
                  label: Text('${updater.updates.length}'),
                  child: const Icon(Icons.system_update_alt_rounded),
                ),
        );
      },
    );
  }
}

/// [child] with the number of AI components that can be updated, for "This computer" in the list of the settings
class AiUpdatesBadge extends ConsumerWidget {
  const AiUpdatesBadge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updater = ref.watch(aiComponentsUpdaterProvider);
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) => Badge(
        key: const Key('ai_updates_badge'),
        isLabelVisible: updater.updates.isNotEmpty,
        label: Text('${updater.updates.length}'),
        child: child,
      ),
    );
  }
}
