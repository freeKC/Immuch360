// The pieces of the conversion dialog that the dialog of a splat scene shows too (plan 2026-11-01, sections 2.4 and
// 2.1, lot SP7): a note under a choice, the line of a folder the versions go to with Change, the question of a network
// folder, and the free space of the drive of the AI components under the components to install. Moved here from
// conversion_dialog.dart as they were, their keys and their rendering unchanged, so that both dialogs say these things
// the same way.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// A line of the dialog in the colour of secondary text, or of an error
class ConversionNote extends StatelessWidget {
  const ConversionNote({super.key, required this.text, this.error = false});

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
class ConversionFolderLine extends StatelessWidget {
  const ConversionFolderLine({
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
class ConversionNetworkQuestion extends StatelessWidget {
  const ConversionNetworkQuestion({super.key, required this.folder, required this.onYes, required this.onNo});

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

/// Under the components to install: what the drive of the components lacks for them, else its free space; and the
/// folder they were moved to when its drive is not connected
class ConversionInstallSpace extends ConsumerWidget {
  const ConversionInstallSpace({super.key, required this.choice});

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
