// The upload of photos and videos of a network share to the Immich server as the browser and the viewers show it: the
// progress of each file over its tile, the line of the whole upload with its cancel button, and the result.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

/// Sends [entries], files of the share [sourceId], to the server (see [NetworkUploadNotifier.upload]) and tells how it
/// went in a toast. Nothing happens while another upload from a share is under way.
Future<void> uploadNetworkEntries(
  BuildContext context,
  WidgetRef ref,
  String sourceId,
  List<NetworkEntry> entries,
) async {
  // Read before the first await: the page may be gone once the upload ends
  final notifier = ref.read(networkUploadProvider.notifier);
  final toasts = ref.read(toastServiceProvider);
  if (entries.length == 1) {
    // The viewers show no progress line: the file being sent and the reminder in a snack bar
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '${context.t.network_upload_sending_file(name: entries.single.name)}\n${context.t.network_upload_keep_open}',
        ),
      ),
    );
  }

  final NetworkUploadSummary? summary;
  try {
    summary = await notifier.upload(sourceId, entries);
  } catch (error) {
    await toasts.error(StaticTranslations.instance.network_upload_error(error: networkErrorMessage(error)));
    return;
  }
  if (summary == null) {
    return;
  }
  final message = networkUploadResultMessage(StaticTranslations.instance, summary);
  if (message == null) {
    return;
  }
  if (summary.failed > 0) {
    await toasts.error(message);
  } else {
    await toasts.success(message);
  }
}

/// What the toast at the end of an upload from a share says, null when there is nothing to say
String? networkUploadResultMessage(Translations t, NetworkUploadSummary summary) {
  final lastError = summary.lastError;
  final parts = [
    if (summary.cancelled) t.network_upload_cancelled,
    if (summary.sent > 0) t.network_upload_done(count: summary.sent),
    if (summary.duplicates > 0) t.network_upload_duplicates(count: summary.duplicates),
    // One failure says why; several say how many, the server giving the same reason for each most of the time
    if (summary.failed == 1 && lastError != null)
      t.network_upload_error(error: lastError)
    else if (summary.failed > 0)
      t.network_upload_failed(count: summary.failed),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The upload from a share under way at the bottom of the browser: which file of how many, the progress of the whole,
/// the reminder to keep the app open, and a cancel button. Nothing when no upload is under way.
class NetworkUploadProgressBar extends ConsumerWidget {
  const NetworkUploadProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upload = ref.watch(networkUploadProvider);
    if (!upload.isRunning) {
      return const SizedBox.shrink();
    }
    return Material(
      color: context.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: upload.fraction),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.t.network_upload_progress(done: upload.current, total: upload.total),
                          style: context.textTheme.titleSmall,
                        ),
                        Text(
                          context.t.network_upload_keep_open,
                          style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref.read(networkUploadProvider.notifier).cancel(),
                    child: Text(context.t.cancel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Over the tile of a file to send: the part sent, or an error mark once it could not be sent (see
/// [NetworkUploadState.progress]). Like the upload overlay of the timeline tiles.
class NetworkUploadProgressOverlay extends StatelessWidget {
  const NetworkUploadProgressOverlay({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final isError = progress < 0;
    return ColoredBox(
      color: isError ? Colors.red.withValues(alpha: 0.6) : Colors.black54,
      child: Center(
        child: isError
            ? const Icon(Icons.error_outline, color: Colors.white, size: 36)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 3,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(progress * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
      ),
    );
  }
}
