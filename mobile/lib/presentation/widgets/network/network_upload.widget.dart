// The upload of photos and videos of a network share to the Immich server as the browser and the viewers show it: the
// progress of each file over its tile, the line of the whole upload with its cancel button, and the result.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// Above this many bytes on mobile data, the upload sheet warns before sending
const networkUploadMobileDataWarning = 500 * 1024 * 1024;

/// Sends [entries], files of the share [sourceId], to the server (see [NetworkUploadNotifier.upload]) and tells how it
/// went in a toast. Nothing happens while another upload from a share is under way.
///
/// The upload sheet (see [NetworkUploadSheet]) asks first when the files include spheres without GPano tags, whose
/// 360° tags are an option, and always when [alwaysAsk] (the drone page, whose files may be large videos);
/// [hasFlightData] tells it that videos among them have flight data, which places them on the map.
Future<void> uploadNetworkEntries(
  BuildContext context,
  WidgetRef ref,
  String sourceId,
  List<NetworkEntry> entries, {
  bool alwaysAsk = false,
  bool hasFlightData = false,
}) async {
  // Read before the first await: the page may be gone once the upload ends
  final notifier = ref.read(networkUploadProvider.notifier);
  final toasts = ref.read(toastServiceProvider);
  final media = ref.read(networkMediaServiceProvider);
  // What the browser read already: a file not shown yet is not read for the sheet
  final spheres = entries.where((entry) => entry.isImage && (media.cached(entry)?.isUntaggedSphere ?? false)).length;
  var options = const NetworkUploadOptions();
  if (alwaysAsk || spheres > 0) {
    final chosen = await showNetworkUploadSheet(context, ref, entries, spheres: spheres, hasFlightData: hasFlightData);
    if (chosen == null || !context.mounted) {
      return;
    }
    options = chosen;
  }
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
    summary = await notifier.upload(sourceId, entries, options: options);
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
  final refused = summary.refused;
  final parts = [
    if (summary.cancelled) t.network_upload_cancelled,
    if (summary.sent > 0) t.network_upload_done(count: summary.sent),
    if (summary.duplicates > 0) t.network_upload_duplicates(count: summary.duplicates),
    if (summary.inTrash > 0) t.upload_in_trash(count: summary.inTrash),
    // One failure says why; several say how many, the server giving the same reason for each most of the time
    if (summary.failed == 1 && lastError != null)
      t.network_upload_error(error: lastError)
    else if (summary.failed > 0)
      t.network_upload_failed(count: summary.failed),
    if (summary.spheresTagged > 0) t.upload_spheres_tagged(count: summary.spheresTagged),
    if (summary.spheresAlreadyThere > 0) t.upload_spheres_already_there(count: summary.spheresAlreadyThere),
    if (summary.placed > 0) t.upload_placed(count: summary.placed),
    if (summary.placesPending > 0) t.upload_places_pending(count: summary.placesPending),
    if (refused.isNotEmpty) ...[
      t.upload_refused(count: refused.length),
      t.upload_refused_reason(kind: _extensionOf(refused.first)),
    ],
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(dot + 1).toLowerCase();
}

/// Asks how to send [entries] in a bottom sheet (see [NetworkUploadSheet]) and gives the options chosen, null when
/// the user goes back. The choice of the 360° tags is remembered for the next upload.
Future<NetworkUploadOptions?> showNetworkUploadSheet(
  BuildContext context,
  WidgetRef ref,
  List<NetworkEntry> entries, {
  required int spheres,
  bool hasFlightData = false,
}) async {
  final totalBytes = entries.fold<int>(0, (sum, entry) => sum + (entry.size ?? 0));
  var onMobileData = false;
  if (totalBytes > networkUploadMobileDataWarning) {
    try {
      final capabilities = await ref.read(connectivityApiProvider).getCapabilities();
      onMobileData = capabilities.hasCellular && !capabilities.hasWifi;
    } catch (_) {
      // Unknown: no warning
    }
  }
  if (!context.mounted) {
    return null;
  }
  final settings = ref.read(settingsProvider);
  final tagSpheres = ref.read(appConfigProvider).uploadTagSpheres;
  final chosen = await showModalBottomSheet<NetworkUploadOptions>(
    context: context,
    isScrollControlled: true,
    builder: (context) => NetworkUploadSheet(
      count: entries.length,
      totalBytes: totalBytes,
      spheres: spheres,
      hasFlightData: hasFlightData,
      onMobileData: onMobileData,
      tagSpheres: tagSpheres,
    ),
  );
  if (chosen != null && spheres > 0 && chosen.tagSpheres != tagSpheres) {
    unawaited(settings.write(.uploadTagSpheres, chosen.tagSpheres));
  }
  return chosen;
}

/// What an upload from a share or the drone page will send, and how: the count and the size of the files, the 360°
/// tags of the spheres of drones when there are some (off unless chosen before), a line on the videos placed on the
/// map from their flight data, a warning on mobile data. Gives back the options, or nothing when the user goes back.
class NetworkUploadSheet extends StatefulWidget {
  const NetworkUploadSheet({
    super.key,
    required this.count,
    required this.totalBytes,
    required this.spheres,
    required this.hasFlightData,
    required this.onMobileData,
    required this.tagSpheres,
  });

  final int count;
  final int totalBytes;

  /// The spheres without GPano tags among the files
  final int spheres;
  final bool hasFlightData;
  final bool onMobileData;

  /// The choice of the last upload
  final bool tagSpheres;

  @override
  State<NetworkUploadSheet> createState() => _NetworkUploadSheetState();
}

class _NetworkUploadSheetState extends State<NetworkUploadSheet> {
  late bool _tagSpheres = widget.tagSpheres;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final size = formatHumanReadableBytes(widget.totalBytes, 1);
    final muted = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.network_upload_action, style: context.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              t.upload_sheet_size(count: widget.count, size: size),
              key: const Key('upload_sheet_size'),
              style: muted,
            ),
            if (widget.spheres > 0) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('upload_sheet_tag_spheres'),
                contentPadding: EdgeInsets.zero,
                value: _tagSpheres,
                onChanged: (value) => setState(() => _tagSpheres = value),
                title: Text(t.upload_tag_spheres_title),
                subtitle: Text(t.upload_tag_spheres_subtitle),
              ),
            ],
            if (widget.hasFlightData)
              ListTile(
                key: const Key('upload_sheet_flight_data'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined),
                title: Text(t.upload_flight_data_line),
              ),
            if (widget.onMobileData)
              ListTile(
                key: const Key('upload_sheet_mobile_data'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.signal_cellular_alt_rounded, color: context.colorScheme.error),
                title: Text(t.upload_mobile_data_warning(size: size)),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('upload_sheet_send'),
                  icon: const Icon(Icons.backup_outlined),
                  label: Text(t.network_upload_action),
                  onPressed: () =>
                      Navigator.of(context).pop(NetworkUploadOptions(tagSpheres: widget.spheres > 0 && _tagSpheres)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
