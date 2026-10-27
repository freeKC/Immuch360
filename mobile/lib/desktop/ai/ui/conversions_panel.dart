// The panel of the 3D conversions of a computer (design-final 2026-10-26, section 5, point 4; spec 5.3 and 5.4): a side
// panel over the window, opened by the button of the app bar and after a launch. Per photo: its thumbnail, its name,
// "2D to 3D SBS", its state in the words of the spec with a bar while it runs, "3 of 12", where its 3D photo goes then
// went, the quality flags of the result, and its actions: Cancel while it waits or runs, Retry once it failed or was
// cancelled; for a 3D photo made, Open folder, View, and Delete this 3D photo. At the bottom: Cancel all, Retry
// failed, Clear finished, and Resume when a disk full paused the queue.
//
// View opens the 3D photo the way a file given to the program opens (open_files.dart), at once, before any scan.
// Delete this 3D photo asks first, then deletes only a file that still carries our XMP with its DerivativeId, read
// again just before: a file of the user that took its name meanwhile is never deleted (design 4.2). The original is
// never touched.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/local_only_message.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/library/versions_section.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ConversionsPanel');

/// What the screens keep of a job besides the queue: the photo for its thumbnail, whether its folder is on the network
/// (no "saved on this computer only" then), and whether the server had edits that the copy of its original lacks
class ConversionJobInfo {
  const ConversionJobInfo({this.asset, this.isNetwork = false, this.serverEdits = false});

  final BaseAsset? asset;
  final bool isNetwork;
  final bool serverEdits;
}

class ConversionJobInfos extends Notifier<Map<String, ConversionJobInfo>> {
  @override
  Map<String, ConversionJobInfo> build() => const {};

  void addAll(Map<String, ConversionJobInfo> infos) => state = {...state, ...infos};
}

final conversionJobInfoProvider = NotifierProvider<ConversionJobInfos, Map<String, ConversionJobInfo>>(
  ConversionJobInfos.new,
);

/// Opens a folder in the file manager of the system; replaced in tests
final conversionFolderOpenerProvider = Provider<Future<void> Function(String folder)>(
  (ref) =>
      (folder) async => openFolder(folder),
);

/// Shows the panel of the conversions on the right of the window
Future<void> showConversionsPanel(BuildContext context) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.black26,
  pageBuilder: (context, _, _) => const Align(
    alignment: AlignmentDirectional.centerEnd,
    child: SafeArea(
      child: Material(
        elevation: 8,
        child: SizedBox(width: 460, height: double.infinity, child: ConversionsPanel()),
      ),
    ),
  ),
);

/// What became of a request to delete a 3D photo
enum VersionDeleteOutcome {
  deleted,

  /// Not a 3D photo of ours with its DerivativeId: kept
  refused,

  /// The system refused it, or it was gone
  failed,
}

/// Deletes the file at [path] when it still carries our XMP with a DerivativeId, read again just before; never any
/// other file
Future<VersionDeleteOutcome> deleteOurVersion(String path) async {
  final head = await readFileHead(path);
  final xmp = head == null ? null : StereoPhotoXmp.findIn(head);
  final id = xmp?.derivativeId;
  if (xmp == null || id == null || id.trim().isEmpty) {
    return head == null ? VersionDeleteOutcome.failed : VersionDeleteOutcome.refused;
  }
  try {
    await File(path).delete();
    return VersionDeleteOutcome.deleted;
  } on FileSystemException catch (error) {
    _log.warning('The 3D photo was not deleted: ${error.message}');
    return VersionDeleteOutcome.failed;
  }
}

/// "Delete this 3D photo": asks first, then deletes the 3D photo at [path] only when it is still one of ours. True
/// when it was deleted; a refusal is said.
Future<bool> confirmDeleteVersion(BuildContext context, String path) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('ai_delete_confirm'),
      title: Text(t.ai_immersive_delete_result),
      content: Text('${t.ai_immersive_delete_confirm}\n${p.basename(path)}'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel)),
        FilledButton(
          key: const Key('ai_delete_confirm_yes'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.delete),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    return false;
  }
  final outcome = await deleteOurVersion(path);
  switch (outcome) {
    case VersionDeleteOutcome.deleted:
      return true;
    case VersionDeleteOutcome.refused:
      messenger?.showSnackBar(SnackBar(content: Text(t.ai_immersive_delete_refused)));
      return false;
    case VersionDeleteOutcome.failed:
      messenger?.showSnackBar(SnackBar(content: Text(t.scaffold_body_error_occurred)));
      return false;
  }
}

/// The words of the state of [job], with its percentage while it computes
String conversionStateText(Translations t, ConversionJob job) => switch (job.phase) {
  ConversionPhase.waiting => t.ai_immersive_state_waiting,
  ConversionPhase.preparing => t.ai_immersive_state_preparing,
  ConversionPhase.computing => '${t.ai_immersive_state_computing} ${(job.progress * 100).round()} %',
  ConversionPhase.finishing => t.ai_immersive_state_finishing,
  ConversionPhase.done => t.ai_immersive_state_done,
  ConversionPhase.skipped => t.ai_immersive_state_skipped,
  ConversionPhase.cancelled => t.ai_immersive_state_cancelled,
  ConversionPhase.failed => t.ai_immersive_state_failed,
};

/// Why a job failed, in words; the message of the system or of the model where the text has room for it
String conversionFailureText(Translations t, ImmersiveErrorCode code, String? message) => switch (code) {
  ImmersiveErrorCode.cancelled => t.ai_immersive_state_cancelled,
  ImmersiveErrorCode.decodeFailed => t.ai_immersive_failed_decode,
  ImmersiveErrorCode.unsupportedFormat => t.ai_immersive_unavailable_format,
  ImmersiveErrorCode.outOfMemory => t.ai_immersive_unavailable_memory,
  ImmersiveErrorCode.writeFailed when message == libraryNotReadyMessage => t.ai_immersive_library_not_ready,
  ImmersiveErrorCode.writeFailed => t.ai_immersive_failed_write(message: message ?? ''),
  ImmersiveErrorCode.diskFull => t.ai_immersive_failed_disk_full,
  ImmersiveErrorCode.readOnly => t.ai_immersive_failed_read_only,
  ImmersiveErrorCode.sourceLost => t.ai_immersive_failed_source,
  ImmersiveErrorCode.modelFailed => t.ai_immersive_failed_model(message: message ?? ''),
  ImmersiveErrorCode.componentsMissing => t.ai_immersive_unavailable_missing,
};

/// The words of a quality flag of a result
String qualityFlagText(Translations t, ReliefQualityFlag flag) => switch (flag) {
  ReliefQualityFlag.lowRelief => t.ai_immersive_quality_flat,
  ReliefQualityFlag.hiddenAreas => t.ai_immersive_quality_hidden,
  ReliefQualityFlag.dark => t.ai_immersive_quality_dark,
};

/// See the top of this file
class ConversionsPanel extends ConsumerWidget {
  const ConversionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final queue = ref.watch(conversionQueueProvider);
    final notifier = ref.read(conversionQueueProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const Key('ai_conversions_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(child: Text(t.ai_immersive_conversions, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(
                tooltip: t.close,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(t.ai_immersive_relief_estimated, style: TextStyle(color: colors.onSurfaceVariant)),
        ),
        if (queue.isPaused)
          Container(
            key: const Key('ai_conversions_paused'),
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.errorContainer,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(t.ai_immersive_disk_full_paused, style: TextStyle(color: colors.onErrorContainer)),
                ),
                FilledButton(
                  key: const Key('ai_conversions_resume'),
                  onPressed: notifier.resume,
                  child: Text(t.ai_immersive_resume),
                ),
              ],
            ),
          ),
        const Divider(height: 16),
        Expanded(
          child: ListView(
            children: [for (final job in queue.jobs.reversed) _JobRow(key: ValueKey('ai_job_${job.id}'), job: job)],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (queue.hasWork)
                TextButton(
                  key: const Key('ai_conversions_cancel_all'),
                  onPressed: notifier.cancelAll,
                  child: Text(t.ai_immersive_cancel_all),
                ),
              if (queue.hasFailed)
                TextButton(
                  key: const Key('ai_conversions_retry_failed'),
                  onPressed: notifier.retryFailed,
                  child: Text(t.ai_immersive_retry_failed),
                ),
              if (queue.hasEnded)
                TextButton(
                  key: const Key('ai_conversions_clear_finished'),
                  onPressed: notifier.clearFinished,
                  child: Text(t.ai_immersive_clear_finished),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _JobRow extends ConsumerWidget {
  const _JobRow({super.key, required this.job});

  final ConversionJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final colors = Theme.of(context).colorScheme;
    final info = ref.watch(conversionJobInfoProvider.select((infos) => infos[job.id]));
    final notifier = ref.read(conversionQueueProvider.notifier);
    final asset = info?.asset;
    final written = job.writtenPath;
    final folder = written != null ? p.dirname(written) : job.target?.folder;
    final secondary = TextStyle(color: colors.onSurfaceVariant);
    final lines = <Widget>[
      Text(
        [
          t.ai_immersive_job_type,
          if (job.batchSize > 1) t.ai_immersive_progress_count(index: job.batchIndex, total: job.batchSize),
        ].join('  •  '),
        style: secondary,
      ),
      Text(conversionStateText(t, job), key: const Key('ai_job_state')),
      if (job.state.isActive) ...[
        const SizedBox(height: 4),
        LinearProgressIndicator(value: job.phase == ConversionPhase.preparing ? null : job.progress),
      ],
      if (job.skipReason case final reason?)
        Text(conversionSkipText(t, reason, name: job.target?.fileName), style: secondary),
      if (job.state == ConversionState.failed && job.error != null)
        Text(conversionFailureText(t, job.error!, job.message), style: TextStyle(color: colors.error)),
      if (folder != null && !job.state.isEnded || job.state == ConversionState.done) ...[
        if (written != null)
          SelectableText(written, style: secondary)
        else if (folder != null)
          SelectableText(folder, style: secondary),
      ],
      if (job.state == ConversionState.done) ...[
        if (job.reduced && job.eyeWidth != null) Text(t.ai_immersive_reduced(width: job.eyeWidth!), style: secondary),
        for (final flag in job.qualityFlags) Text(qualityFlagText(t, flag), style: secondary),
        if (info?.serverEdits ?? false) Text(t.ai_immersive_server_edits_ignored, style: secondary),
        if (localOnlyMessage(t, isNetwork: info?.isNetwork ?? false) case final message?)
          Text(message, key: const Key('ai_job_local_only'), style: secondary),
      ],
    ];
    final actions = <Widget>[
      if (!job.state.isEnded)
        TextButton(key: const Key('ai_job_cancel'), onPressed: () => notifier.cancel(job.id), child: Text(t.cancel)),
      if (job.target != null && (job.state == ConversionState.failed || job.state == ConversionState.cancelled))
        TextButton(
          key: const Key('ai_job_retry'),
          onPressed: () => notifier.retry(job.id),
          child: Text(t.ai_immersive_retry),
        ),
      if (job.state == ConversionState.done && written != null) ...[
        TextButton(
          key: const Key('ai_job_open_folder'),
          onPressed: () => unawaited(ref.read(conversionFolderOpenerProvider)(p.dirname(written))),
          child: Text(t.ai_immersive_open_folder),
        ),
        TextButton(
          key: const Key('ai_job_view'),
          onPressed: () {
            final open = ref.read(versionOpenerProvider);
            unawaited(Navigator.of(context).maybePop());
            open(written);
          },
          child: Text(t.view),
        ),
        TextButton(
          key: const Key('ai_job_delete'),
          onPressed: () async {
            if (await confirmDeleteVersion(context, written)) {
              notifier.remove(job.id);
            }
          },
          child: Text(t.ai_immersive_delete_result),
        ),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: SizedBox.square(
              dimension: 56,
              child: asset == null
                  ? ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: Icon(Icons.photo_outlined, color: colors.onSurfaceVariant),
                    )
                  : ref.watch(conversionThumbnailProvider)(asset),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.source.name, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                ...lines,
                if (actions.isNotEmpty) Wrap(spacing: 4, children: actions),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The thumbnail of the photo of a job; replaced in tests
final conversionThumbnailProvider = Provider<Widget Function(BaseAsset asset)>(
  (ref) =>
      (asset) => Thumbnail.fromAsset(asset: asset, size: const Size.square(112)),
);
