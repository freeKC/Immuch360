// "AI and 3D" in the This computer settings (design-final 2026-10-26, section 5, point 7): the switch of the AI
// features (on by default, the app being a lab; off, no AI button anywhere and nothing downloaded), the AI components
// (their sizes, licences, Remove, the total, Remove all), where the 3D photos go by default, what happens when a 3D
// photo with the same name exists, whether photos that already have a 3D version are skipped, the network folders
// allowed to receive 3D photos (each can be taken back), whether the AI versions are backed up to Immich (the switch
// follows the album "Immuch360 AI versions" of the backup pages, design 4.3), and what this computer has: its
// logical processors, its memory, its GPU, which phase 1 does not use yet.
//
// Phases 2 and 3 (design-final 2026-10-27, sections 7.4 and 9.1, point 5): the components grouped by feature ("3D
// photos", "3D scenes"), each group with its size, Download and Remove; "Move the AI components" to a folder the user
// picks, another drive, with its folder, its progress and what a refusal means, and the folder said when its drive is
// not connected; "Also save a .glb copy" of each 3D scene, off by default. The line of the graphics card and the
// integrated graphics are lot C6.
//
// The settings of the conversions live in desktop_ai.json (DesktopAiSettings); the switch of the AI features is a
// setting shared with the Meta Quest (AiImmersiveConfig).

import 'dart:async';
import 'dart:ffi' show Abi;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/network_root_consent.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/components_tile.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('AiSettingsSection');

/// Turns the AI features on or off; replaced in tests
final aiFeaturesSwitchProvider = Provider<Future<void> Function(bool on)>(
  (ref) =>
      (on) => ref.read(settingsProvider).write(.aiImmersiveEnabled, on),
);

/// The download folder, "A folder of my choice" while none was chosen
final aiDefaultFolderProvider = FutureProvider.autoDispose<String>((ref) => DownloadFolder.instance.currentPath());

/// The name of the GPU in use, where the system tells it (Windows)
final aiGpuNameProvider = FutureProvider.autoDispose<String?>(
  (ref) async => (await DesktopGpuDecoders.adapter())?.name,
);

/// Turns the backup of the AI versions on or off (lot A6a); replaced in tests
final aiBackupGeneratedSetterProvider = Provider<Future<bool> Function(bool on)>(
  (ref) => ref.watch(generatedAlbumKeeperProvider).setBacksUpGenerated,
);

/// The AI platform of this computer, null where the AI features do not run
final aiPlatformProvider = Provider<AiPlatform?>((ref) => aiPlatformOf(Abi.current()));

/// The settings of desktop_ai.json as the section shows them, read again after each change
final _aiSettingsProvider = FutureProvider.autoDispose<DesktopAiSettings>(
  (ref) => ref.watch(desktopAiSettingsStoreProvider).read(),
);

/// Stops the conversions so that the components can be removed: every job cancelled, then, once none runs any more,
/// the model let go. Ends when nothing uses the components, or after [wait] at most: the tile then says the conversion
/// is still stopping.
Future<void> stopConversionsForRemoval(WidgetRef ref, {Duration wait = const Duration(seconds: 30)}) async {
  ref.read(conversionQueueProvider.notifier).cancelAll();
  final engine = ref.read(desktopAiEngineProvider);
  final until = DateTime.now().add(wait);
  while ((engine.isRunning || ref.read(conversionQueueProvider).current != null) && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await engine.release();
}

/// Moves the AI components into the folder [chosen] the user picked, [onProgress] getting the bytes copied and those to
/// copy (moveAiComponents)
typedef AiComponentsMover = Future<AiMoveResult> Function(String chosen, void Function(int done, int total) onProgress);

/// The move of the app; replaced in tests. An engine kept between two jobs holds ONNX Runtime: it is let go first, so
/// that the old folder empties now rather than at the next start.
final aiComponentsMoverProvider = Provider<AiComponentsMover>(
  (ref) => (chosen, onProgress) async {
    if (ref.read(conversionQueueProvider).current == null) {
      await ref.read(desktopAiEngineProvider).release();
    }
    return moveAiComponents(
      ref.read(aiComponentsServiceProvider),
      chosen,
      store: ref.read(desktopAiSettingsStoreProvider),
      onProgress: onProgress,
    );
  },
);

/// The folder of the AI components now, null when it cannot be told
final aiComponentsFolderPathProvider = FutureProvider.autoDispose<String?>((ref) async {
  try {
    return (await ref.watch(aiComponentsFolderProvider)()).path;
  } catch (error) {
    _log.warning('The folder of the AI components is not known: $error');
    return null;
  }
});

/// What a move of the components says when it did not simply move them; null when it did
String? aiMoveOutcomeText(Translations t, AiMoveResult result) => switch (result.outcome) {
  AiMoveOutcome.moved || AiMoveOutcome.same => null,
  AiMoveOutcome.movedNextStart => t.ai_immersive_removed_next_start,
  AiMoveOutcome.busy => t.ai_immersive_move_busy,
  AiMoveOutcome.notEmpty => t.ai_immersive_move_not_empty,
  AiMoveOutcome.notEnoughSpace => t.ai_immersive_move_no_space(
    drive: result.shortage?.volume ?? '',
    needed: formatBytes(result.shortage?.needed ?? 0),
    free: formatBytes(result.shortage?.free ?? 0),
  ),
  AiMoveOutcome.failed => t.ai_immersive_move_failed(reason: result.detail ?? ''),
};

/// How a root or a volume allowed reads: "//nas/photos/2024" for "net-//nas/photos:/2024"
String networkRootLabel(String key) {
  var label = key;
  for (final prefix in const ['net-', 'mnt-']) {
    if (label.startsWith(prefix)) {
      label = label.substring(prefix.length);
      break;
    }
  }
  final inside = label.indexOf(':/');
  if (inside > 0 && !RegExp(r'^[A-Za-z]:/').hasMatch(label)) {
    final rest = label.substring(inside + 2);
    label = rest.isEmpty ? label.substring(0, inside) : '${label.substring(0, inside)}/$rest';
  }
  return label;
}

/// See the top of this file
class DesktopAiSettingsSection extends ConsumerWidget {
  const DesktopAiSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final enabled = ref.watch(aiFeaturesEnabledProvider);
    final platform = ref.watch(aiPlatformProvider);
    final settings = ref.watch(_aiSettingsProvider).valueOrNull;
    final secondary = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Column(
      key: const Key('ai_settings_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingGroupTitle(title: t.ai_immersive_settings_title, icon: Icons.view_in_ar_outlined),
        SwitchListTile(
          key: const Key('ai_settings_enabled'),
          value: enabled,
          title: Text(t.ai_immersive_enabled),
          subtitle: Text(t.ai_immersive_enabled_subtitle),
          onChanged: (on) => unawaited(ref.read(aiFeaturesSwitchProvider)(on)),
        ),
        // The components stay listed with the features off, so that their space can still be freed; nothing is
        // downloaded then
        if (platform != null) ...[
          AiComponentsTile(
            platform: platform,
            onCancelConversions: () => stopConversionsForRemoval(ref),
            canDownload: enabled,
          ),
          const _MoveComponents(),
        ] else
          ListTile(title: Text(t.ai_immersive_unavailable_system, style: secondary)),
        if (enabled && settings != null) ...[
          _SaveTo(settings: settings),
          _WhenExists(settings: settings),
          SwitchListTile(
            key: const Key('ai_settings_skip_existing'),
            value: settings.skipExisting,
            title: Text(t.ai_immersive_existing_skip),
            onChanged: (on) => unawaited(_update(ref, (kept) => kept.copyWith(skipExisting: on))),
          ),
          SwitchListTile(
            key: const Key('ai_settings_export_glb'),
            value: settings.exportGlb,
            title: Text(t.ai_immersive_export_glb_setting),
            onChanged: (on) => unawaited(_update(ref, (kept) => kept.copyWith(exportGlb: on))),
          ),
          if (settings.networkRootsAllowed.isNotEmpty) _NetworkRoots(roots: settings.networkRootsAllowed),
          const _BackupGenerated(),
          const _Hardware(),
        ],
      ],
    );
  }
}

/// Changes desktop_ai.json, then shows it again
Future<void> _update(WidgetRef ref, DesktopAiSettings Function(DesktopAiSettings settings) change) async {
  try {
    await ref.read(desktopAiSettingsStoreProvider).update(change);
  } catch (error, stack) {
    _log.warning('The settings of the conversions were not kept', error, stack);
    snackbar.error(StaticTranslations.instance.scaffold_body_error_occurred);
  }
  ref.invalidate(_aiSettingsProvider);
}

class _SaveTo extends ConsumerWidget {
  const _SaveTo({required this.settings});

  final DesktopAiSettings settings;

  Future<void> _change(WidgetRef ref, String? current) async {
    final String? picked;
    try {
      picked = await filePickers.folder(initialDirectory: current);
    } on Exception catch (error) {
      _log.warning('The folder dialog failed: $error');
      return;
    }
    if (picked != null) {
      await _update(ref, (kept) => kept.copyWith(destination: AiDestination.folder, folder: () => picked));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final folder = settings.folder ?? ref.watch(aiDefaultFolderProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(title: Text(t.ai_immersive_save_to)),
        RadioGroup<AiDestination>(
          groupValue: settings.destination,
          onChanged: (value) {
            if (value != null) {
              unawaited(_update(ref, (kept) => kept.copyWith(destination: value)));
            }
          },
          child: Column(
            children: [
              RadioListTile<AiDestination>(
                key: const Key('ai_settings_next_to_original'),
                value: AiDestination.nextToOriginal,
                title: Text(t.ai_immersive_next_to_original),
              ),
              RadioListTile<AiDestination>(
                key: const Key('ai_settings_chosen_folder'),
                value: AiDestination.folder,
                title: Text(t.ai_immersive_chosen_folder),
                subtitle: folder == null ? null : Text(folder, key: const Key('ai_settings_folder')),
                secondary: TextButton(
                  key: const Key('ai_settings_change_folder'),
                  onPressed: () => unawaited(_change(ref, folder)),
                  child: Text(t.change),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WhenExists extends ConsumerWidget {
  const _WhenExists({required this.settings});

  final DesktopAiSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(title: Text(t.ai_immersive_existing)),
        RadioGroup<AiWhenExists>(
          groupValue: settings.whenExists,
          onChanged: (value) {
            if (value != null) {
              unawaited(_update(ref, (kept) => kept.copyWith(whenExists: value)));
            }
          },
          child: Column(
            children: [
              for (final (choice, label) in [
                (AiWhenExists.keepBoth, t.ai_immersive_keep_both),
                (AiWhenExists.replace, t.ai_immersive_replace),
                (AiWhenExists.skip, t.ai_immersive_skip),
              ])
                RadioListTile<AiWhenExists>(
                  key: Key('ai_settings_when_exists_${choice.name}'),
                  value: choice,
                  title: Text(label),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NetworkRoots extends ConsumerWidget {
  const _NetworkRoots({required this.roots});

  final List<String> roots;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    return Column(
      key: const Key('ai_settings_network_roots'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(title: Text(t.ai_immersive_network_roots)),
        for (final root in roots)
          ListTile(
            key: ValueKey('ai_settings_network_root_$root'),
            leading: const Icon(Icons.lan_outlined),
            title: Text(networkRootLabel(root)),
            trailing: IconButton(
              key: ValueKey('ai_settings_network_root_remove_$root'),
              tooltip: t.remove,
              icon: const Icon(Icons.close_rounded),
              onPressed: () async {
                try {
                  await NetworkRootConsent(store: ref.read(desktopAiSettingsStoreProvider)).withdraw(root);
                } catch (error) {
                  _log.warning('The network folder was not taken back: $error');
                }
                ref.invalidate(_aiSettingsProvider);
              },
            ),
          ),
      ],
    );
  }
}

/// "Move the AI components": the folder they are in, then the folder the user picks, the copies with their progress,
/// and a message when the move did not simply happen. Offered with the AI features off too, as Remove is: it frees the
/// drive of the app.
class _MoveComponents extends ConsumerStatefulWidget {
  const _MoveComponents();

  @override
  ConsumerState<_MoveComponents> createState() => _MoveComponentsState();
}

class _MoveComponentsState extends ConsumerState<_MoveComponents> {
  /// From 0 to 1 while the components are being moved, null otherwise
  double? _progress;

  Future<void> _move() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final current = ref.read(aiComponentsFolderPathProvider).valueOrNull;
    final String? picked;
    try {
      picked = await filePickers.folder(
        initialDirectory: current == null ? null : p.dirname(current),
        confirmButtonText: t.ai_immersive_move_components,
      );
    } on Exception catch (error) {
      _log.warning('The folder dialog failed: $error');
      return;
    }
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _progress = 0);
    AiMoveResult result;
    try {
      result = await ref.read(aiComponentsMoverProvider)(picked, (done, total) {
        if (mounted) {
          setState(() => _progress = total <= 0 ? 1 : done / total);
        }
      });
    } catch (error, stack) {
      _log.warning('The AI components were not moved', error, stack);
      result = AiMoveResult(AiMoveOutcome.failed, detail: '$error');
    }
    if (!mounted) {
      return;
    }
    setState(() => _progress = null);
    // The components are read from their new folder now
    ref.invalidate(aiComponentsFolderPathProvider);
    ref.invalidate(aiComponentsFolderMissingProvider);
    ref.invalidate(aiGateResultForProvider);
    if (aiMoveOutcomeText(t, result) case final message?) {
      // A new answer takes the place of the one before
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = Theme.of(context).colorScheme;
    final folder = ref.watch(aiComponentsFolderPathProvider).valueOrNull;
    final unreachable = ref.watch(aiComponentsFolderMissingProvider).valueOrNull;
    final progress = _progress;
    return ListTile(
      key: const Key('ai_settings_move_components'),
      leading: const Icon(Icons.drive_file_move_outline),
      title: Text(t.ai_immersive_move_components),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (folder != null) Text(folder, key: const Key('ai_settings_components_folder')),
          if (unreachable != null)
            Text(
              t.ai_immersive_components_folder_missing(folder: unreachable),
              key: const Key('ai_settings_components_folder_missing'),
              style: TextStyle(color: colors.error),
            ),
          if (progress != null) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: progress),
            Text(t.ai_immersive_moving_components(percent: (progress * 100).floor())),
          ],
        ],
      ),
      onTap: progress == null ? () => unawaited(_move()) : null,
    );
  }
}

class _BackupGenerated extends ConsumerWidget {
  const _BackupGenerated();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final on = ref.watch(generatedAlbumBackupProvider).valueOrNull;
    return SwitchListTile(
      key: const Key('ai_settings_backup_generated'),
      value: on ?? false,
      title: Text(t.ai_immersive_backup_ai_versions),
      subtitle: Text(t.ai_immersive_backup_ai_versions_hint),
      // Until the album reached the local tables, there is nothing to turn
      onChanged: on == null ? null : (value) => unawaited(ref.read(aiBackupGeneratedSetterProvider)(value)),
    );
  }
}

class _Hardware extends ConsumerWidget {
  const _Hardware();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final gate = ref.watch(aiGateResultProvider).valueOrNull;
    final gpu = ref.watch(aiGpuNameProvider).valueOrNull;
    if (gate == null) {
      return const SizedBox.shrink();
    }
    final memory = gate.physicalMemory;
    return ListTile(
      key: const Key('ai_settings_hardware'),
      leading: const Icon(Icons.memory_outlined),
      title: Text(
        t.ai_immersive_hardware(processors: gate.processors, memory: memory == null ? '?' : formatBytes(memory)),
      ),
      subtitle: Text([?gpu, t.ai_immersive_gpu_later].join('\n')),
    );
  }
}
