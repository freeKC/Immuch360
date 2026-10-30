import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_button.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_splat.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatPage');

/// A Gaussian splat file of another tool (lot S5): of the share [sourceId] at [path] ([size] bytes when known), or a
/// file of the headset at [path] without a share (picked with Open a splat file). The page says what the head of the
/// file says (its name, its size, its gaussians and format, the tool a comment of a PLY names) and offers "Explore the
/// splat scene", which opens it in the immersive viewer of a Meta Quest 3 or 3S, or greys it with its reason. A splat
/// joins no previous and next, and is never sent to the Immich server, which takes no such file.
@RoutePage()
class SplatPage extends ConsumerWidget {
  const SplatPage({super.key, this.sourceId, required this.path, this.size});

  final String? sourceId;
  final String path;
  final int? size;

  String get _name => path.split('/').where((part) => part.isNotEmpty).lastOrNull ?? path;

  /// Opens the splat of [splat] in the immersive viewer: through the media bridge for a file of a share, from its
  /// place for a file of the headset
  Future<void> _open(BuildContext context, WidgetRef ref, GaussianSplatRequest splat) async {
    // Read before the first await: the page may be gone by then
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorMessage = context.t.immersive_viewer_open_failed;
    final stereoLabels = stereoPhotoViewerLabels(context.t);
    final connections = ref.read(networkConnectionsProvider);
    try {
      final sourceId = this.sourceId;
      final url = sourceId == null
          ? Uri.file(path).toString()
          : (await connections.mediaUrl(sourceId, path)).toString();
      final request = ImmersiveRequest(
        url: url,
        isVideo: false,
        title: _name,
        view: stereoPhotoSphereView,
        stereoPair: StereoPhotoRequest.splat(splat).toImmersiveJson(),
      );
      _log.info('Opening the splat $_name: ${splat.toJsonString()}');
      await openImmersiveUrl(ref, request: request, stereoLabels: stereoLabels);
    } catch (error) {
      _log.warning('Could not open the splat $_name: $error');
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final probe = ref.watch(splatProbeProvider((sourceId: sourceId, path: path, size: size)));
    final value = probe.valueOrNull;
    final Widget body;
    if (value != null) {
      body = _SplatDetails(
        name: _name,
        size: size ?? _localSize(),
        probe: value,
        open: (request) => _open(context, ref, request),
      );
    } else if (probe.hasError) {
      _log.warning('Could not read the splat $_name: ${probe.error}');
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.t.splat_open_file_failed,
            key: const Key('splat_page_error'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(context.t.splat_reading)],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(_name), elevation: 0, centerTitle: false),
      body: SafeArea(child: body),
    );
  }

  /// The size of a file of the headset, null for a file of a share or one gone
  int? _localSize() {
    if (sourceId != null) {
      return null;
    }
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return null;
    }
  }
}

class _SplatDetails extends ConsumerWidget {
  const _SplatDetails({required this.name, required this.size, required this.probe, required this.open});

  final String name;
  final int? size;
  final SplatProbe probe;
  final Future<void> Function(GaussianSplatRequest request) open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final head = probe is SplatHead ? probe as SplatHead : null;
    final size = this.size;
    // A file of a share whose size it did not give: 1 byte for the request, the headset reading the file again
    final fileBytes = size ?? 1;
    final verdict = splatVerdictOf(ref, probe, name: name, fileBytes: fileBytes);
    final request = verdict?.request;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      children: [
        Icon(Icons.blur_on_rounded, size: 72, color: context.colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(name, textAlign: TextAlign.center, style: context.textTheme.titleMedium),
        if (size != null)
          Text(
            formatHumanReadableBytes(size, 1),
            key: const Key('splat_page_size'),
            textAlign: TextAlign.center,
            style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        if (head != null) ...[
          const SizedBox(height: 8),
          Text(splatFileLine(t, head, locale), key: const Key('splat_page_line'), textAlign: TextAlign.center),
          if (request != null && head.gaussians > request.maxGaussians)
            Text(
              t.splat_will_reduce(count: splatCountText(request.maxGaussians, locale)),
              key: const Key('splat_page_reduce'),
              textAlign: TextAlign.center,
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
        ],
        const SizedBox(height: 24),
        SplatButton(probe: probe, name: name, fileBytes: fileBytes, open: open),
      ],
    );
  }
}
