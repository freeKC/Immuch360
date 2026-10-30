// The tile of a Gaussian splat file in the browser of a share (lot S5): no picture (a splat has none to show without
// the headset rendering it), an icon, the "3D splat" badge, its name and the count its head gives. A .ply that holds
// a mesh or a point cloud is no splat: [SplatFileGrid] leaves it out once its head was read.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/network/network_splat.provider.dart';
import 'package:intl/intl.dart';

/// The key of the probe of a splat [entry] of a share
SplatFileKey splatFileKeyOf(NetworkEntry entry) => (sourceId: entry.sourceId, path: entry.path, size: entry.size);

/// [count] with the grouping of [locale]: 452,451 in English
String splatCountText(int count, String locale) {
  try {
    return NumberFormat.decimalPattern(locale).format(count);
  } on ArgumentError {
    return NumberFormat.decimalPattern('en').format(count);
  }
}

/// Whether the browser lists the file whose head said [probe] (null while it is read): a splat, or one it cannot
/// read yet (compressed, ASCII, newer, damaged) so that the page says why; never a mesh or a point cloud
bool splatIsListed(AsyncValue<SplatProbe> probe) {
  if (probe.hasError) {
    return false;
  }
  final value = probe.valueOrNull;
  return !(value is SplatRefused && value.problem == SplatFileProblem.notASplat);
}

/// The tile of the splat [entry], opened with [onTap]
class SplatTile extends ConsumerWidget {
  const SplatTile({super.key, required this.entry, required this.onTap});

  final NetworkEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final probe = ref.watch(splatProbeProvider(splatFileKeyOf(entry)));
    final locale = Localizations.localeOf(context).toLanguageTag();
    final head = probe.valueOrNull;
    final line = head is SplatHead ? context.t.splat_count(count: splatCountText(head.gaussians, locale)) : null;
    const shadows = [Shadow(blurRadius: 4, color: Colors.black54)];
    return Semantics(
      label: '${entry.name}, ${context.t.splat_badge}',
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: RemoteFocusable(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: context.colorScheme.surfaceContainerHighest),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.blur_on_rounded, size: 40, color: context.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 6),
                    Text(
                      entry.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: context.textTheme.bodySmall,
                    ),
                    if (line != null)
                      Text(
                        line,
                        key: const Key('splat_tile_count'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.labelSmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                      ),
                    if (probe.isLoading)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                  ],
                ),
              ),
              Positioned(
                key: const Key('splat_tile_badge'),
                left: 6,
                top: 6,
                child: Text(
                  context.t.splat_badge,
                  style: TextStyle(
                    color: context.colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    shadows: shadows,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The splats of a folder, after its photos and videos: those whose head says they are splats, in the order of
/// [entries], each opened with [onOpen]
class SplatFileGrid extends ConsumerWidget {
  const SplatFileGrid({super.key, required this.entries, required this.onOpen});

  final List<NetworkEntry> entries;
  final void Function(NetworkEntry entry) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listed = [
      for (final entry in entries)
        if (splatIsListed(ref.watch(splatProbeProvider(splatFileKeyOf(entry))))) entry,
    ];
    if (listed.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 24),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: listed.length,
        itemBuilder: (context, index) {
          final entry = listed[index];
          return SplatTile(key: ValueKey('splat:${entry.path}'), entry: entry, onTap: () => onOpen(entry));
        },
      ),
    );
  }
}
