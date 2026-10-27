// The rows of the details panel of the viewer of a computer for the 3D versions of a photo (design-final 2026-10-26,
// section 4.2): on an original, "Versions", each one with its thumbnail, what it is ("3D photo, relief estimated by
// AI") and its folder, greyed with its reason on a drive that is not connected; on a version, "Made from salon.jpg"
// or "Original not found". A row opens its file the way a file given to the program opens (open_files.dart), even
// before the next scan, and has "Delete this 3D photo" (lot A5c), which asks first and deletes only a file that still
// carries our XMP with its DerivativeId, never the original. What they find is in versions.provider.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:path/path.dart' as p;

const _separator = '  •  ';

/// Opens a file of the library in the viewer; replaced in tests
final versionOpenerProvider = Provider<void Function(String path)>(
  (ref) =>
      (path) => DesktopOpenRequests.add([path]),
);

/// The 3D photos deleted from the app in this session: the index keeps them until the next scan of their folder (up to
/// a quarter of an hour on a network folder), so their rows are left out while their files stay gone
class DeletedVersions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String path) => state = {...state, path};
}

final deletedVersionsProvider = NotifierProvider<DeletedVersions, Set<String>>(DeletedVersions.new);

/// The thumbnail of a version in its row; replaced in tests
final versionThumbnailProvider = Provider<Widget Function(VersionFile file)>(
  (ref) =>
      (file) => Thumbnail.fromAsset(asset: file.asset, size: const Size.square(96)),
);

/// The versions of [asset], or the photo it was made from; nothing for a photo without either
class DesktopVersionsTiles extends ConsumerWidget {
  const DesktopVersionsTiles({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(photoVersionsProvider(asset)).valueOrNull;
    if (found == null) {
      return const SizedBox.shrink();
    }
    final self = found.self;
    if (self != null) {
      return _MadeFromTile(self: self, original: found.original);
    }
    final deleted = ref.watch(deletedVersionsProvider);
    // A 3D photo made again at the same place comes back
    final versions = [
      for (final version in found.versions)
        if (!deleted.contains(version.path) || File(version.path).existsSync()) version,
    ];
    if (versions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('desktop_versions'),
      children: [
        const SizedBox(height: 16),
        SheetTile(
          title: context.t.ai_immersive_versions,
          titleStyle: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceSecondary),
        ),
        for (final version in versions) _VersionTile(version: version, original: asset),
      ],
    );
  }
}

/// What a version is, in the words of the honesty label when its relief was estimated
String _kindOf(VersionFile file, Translations t) =>
    file.isEstimatedRelief ? t.ai_immersive_3d_photo_estimated : t.ai_immersive_3d_photo;

class _VersionTile extends ConsumerWidget {
  const _VersionTile({required this.version, required this.original});

  final VersionFile version;

  /// The photo whose details show it, whose versions are read again once it is deleted
  final BaseAsset original;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final available = version.available;
    final tile = SheetTile(
      key: ValueKey('desktop_version_${version.asset.id}'),
      title: version.name,
      titleStyle: context.textTheme.labelLarge,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: SizedBox.square(dimension: 48, child: ref.watch(versionThumbnailProvider)(version)),
      ),
      subtitle: [
        _kindOf(version, t),
        if (!available) t.ai_immersive_version_unavailable,
        p.dirname(version.path),
      ].join('\n'),
      subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
      onTap: available ? () => ref.read(versionOpenerProvider)(version.path) : null,
      trailing: available
          ? IconButton(
              key: ValueKey('desktop_version_delete_${version.asset.id}'),
              tooltip: t.ai_immersive_delete_result,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                if (await confirmDeleteVersion(context, ref, version.path)) {
                  ref.invalidate(photoVersionsProvider(original));
                }
              },
            )
          : null,
    );
    return available ? tile : Opacity(opacity: 0.5, child: tile);
  }
}

class _MadeFromTile extends ConsumerWidget {
  const _MadeFromTile({required this.self, required this.original});

  final VersionFile self;
  final VersionFile? original;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final original = this.original;
    final titleStyle = context.textTheme.labelLarge;
    final available = original?.available ?? false;
    return Column(
      children: [
        const SizedBox(height: 16),
        SheetTile(
          key: const Key('desktop_made_from'),
          title: original == null ? t.ai_immersive_original_missing : t.ai_immersive_made_from(name: original.name),
          titleStyle: titleStyle,
          leading: Icon(Icons.view_in_ar_outlined, size: 24, color: titleStyle?.color),
          subtitle: [
            _kindOf(self, t),
            if (original != null && !available) t.ai_immersive_version_unavailable,
          ].join(_separator),
          subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
          onTap: original != null && available ? () => ref.read(versionOpenerProvider)(original.path) : null,
        ),
      ],
    );
  }
}
