// "Versions" on the page of a photo of a share, on a computer (FreeKC, 30 October 2026: the result of "Make 3D (AI)"
// seen where it sits on the share). The library has its section in the details of the viewer (versions_section.dart);
// a share has no index, so its versions are those its folder holds, found as the Quest finds them (findShareVersions:
// the names of the versions, the head of each, kept when our XMP in it names the photo): each listed with what it is,
// in the words of its honesty label, and opening its own page. On a version of ours, what it was made from, when that
// photo is in its folder. Both are looked for again once a version is put in the folder (shareFolderChangesProvider).

import 'dart:async';
import 'dart:typed_data';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('ShareVersionsButton');

/// What a version of a photo of a share is, in the words of its honesty label
String shareVersionKindText(Translations t, ShareVersion version) => switch (version.kind) {
  ImmersiveKind.stereoPhoto =>
    (version.photo?.isEstimatedRelief ?? false) ? t.ai_immersive_3d_photo_estimated : t.ai_immersive_3d_photo,
  ImmersiveKind.volumetricScene => t.ai_immersive_version_scene,
  ImmersiveKind.panorama360 => t.ai_immersive_version_panorama,
  ImmersiveKind.stereoPanorama360 =>
    version.xmp.origin == ImmersiveOrigin.generatedContent
        ? t.ai_immersive_version_stereo_panorama
        : t.ai_immersive_version_stereo_360,
  null => t.ai_immersive_newer_version,
};

/// The photo of its folder [head] (the head of the file at [entry]) says it was made from, when our XMP in it names a
/// photo of [neighbours] by its name and its size; null otherwise
NetworkEntry? shareVersionOriginal(NetworkEntry entry, Uint8List head, Iterable<NetworkEntry> neighbours) {
  final xmp = holdsImmuch360Xmp(head) ? StereoPhotoXmp.findIn(head) : null;
  final name = xmp?.sourceName;
  if (xmp == null || name == null || xmp.derivativeId == null) {
    return null;
  }
  final folder = shareFolderOf(entry.path);
  for (final neighbour in neighbours) {
    final size = neighbour.size;
    if (neighbour.isDirectory ||
        neighbour.path == entry.path ||
        size == null ||
        shareFolderOf(neighbour.path) != folder) {
      continue;
    }
    final candidate = DerivedRuleCandidate(name: entry.name, folder: folder, xmp: xmp);
    if (isDerivedFrom(candidate, DerivedRuleOriginal(name: neighbour.name, size: size, folder: folder))) {
      return neighbour;
    }
  }
  return null;
}

/// Opens the page of a file of a share; replaced in tests
final shareFileOpenerProvider = Provider<void Function(BuildContext context, NetworkEntry entry)>(
  (ref) =>
      (context, entry) => unawaited(context.router.push(NetworkPhotoRoute(sourceId: entry.sourceId, path: entry.path))),
);

/// See the top of this file: the button of the app bar of the page of the photo of a share at [entry], absent while
/// the photo has neither versions nor an original in its folder; [neighbours], the files of its folder the browser
/// read, else its folder is listed
class DesktopShareVersionsButton extends ConsumerStatefulWidget {
  const DesktopShareVersionsButton({super.key, required this.entry, this.neighbours});

  final NetworkEntry entry;
  final List<NetworkEntry>? neighbours;

  @override
  ConsumerState<DesktopShareVersionsButton> createState() => _DesktopShareVersionsButtonState();
}

class _DesktopShareVersionsButtonState extends ConsumerState<DesktopShareVersionsButton> {
  List<ShareVersion> _versions = const [];
  NetworkEntry? _original;
  var _looks = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_look(listAgain: false));
  }

  /// Looks for the versions of the photo and its original among the files of its folder: those the browser read,
  /// unless [listAgain] (a version was put there since)
  Future<void> _look({required bool listAgain}) async {
    final look = ++_looks;
    final entry = widget.entry;
    if (!entry.isImage) {
      return;
    }
    try {
      final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(entry.sourceId);
      final read = widget.neighbours;
      final neighbours = !listAgain && read != null ? read : await fileSystem.list(shareFolderOf(entry.path));
      final versions = await findShareVersions(
        entry,
        neighbours,
        readerOf: (neighbour) => networkFileReader(fileSystem, neighbour.path),
      );
      final head = await networkFileReader(fileSystem, entry.path)(0, shareVersionHeadLength);
      final original = shareVersionOriginal(entry, head, neighbours);
      if (mounted && look == _looks) {
        setState(() {
          _versions = versions;
          _original = original;
        });
      }
    } catch (error) {
      _log.info('The versions of ${entry.name} could not be looked for: $error');
    }
  }

  /// Closes the dialog of [dialogContext], then opens the page of [entry] from the page of the photo
  void _open(BuildContext dialogContext, NetworkEntry entry) {
    final open = ref.read(shareFileOpenerProvider);
    Navigator.of(dialogContext).pop();
    open(context, entry);
  }

  Future<void> _show() => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final t = dialogContext.t;
      final original = _original;
      return AlertDialog(
        key: const Key('desktop_share_versions_dialog'),
        title: Text(t.ai_immersive_versions),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (original != null)
                  ListTile(
                    key: const Key('desktop_share_made_from'),
                    leading: const Icon(Icons.photo_outlined),
                    title: Text(t.ai_immersive_made_from(name: original.name)),
                    onTap: () => _open(dialogContext, original),
                  ),
                for (final version in _versions)
                  ListTile(
                    key: ValueKey('desktop_share_version_${version.entry.path}'),
                    leading: _VersionThumbnail(entry: version.entry),
                    title: Text(version.entry.name),
                    subtitle: Text(shareVersionKindText(t, version)),
                    onTap: () => _open(dialogContext, version.entry),
                  ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(t.close))],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    // A version put in the folder since: looked for again
    ref.listen(
      shareFolderChangesProvider.select(
        (changes) => changes[shareFolderChangeKey(entry.sourceId, shareFolderOf(entry.path))],
      ),
      (_, _) => unawaited(_look(listAgain: true)),
    );
    if (_versions.isEmpty && _original == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    return IconButton(
      key: const Key('desktop_share_versions'),
      icon: Badge.count(
        count: _versions.length,
        isLabelVisible: _versions.isNotEmpty,
        child: const Icon(Icons.layers_outlined),
      ),
      tooltip: _versions.isEmpty ? t.ai_immersive_made_from(name: _original!.name) : t.ai_immersive_versions,
      onPressed: () => unawaited(_show()),
    );
  }
}

/// The thumbnail of a version in its row, through the media bridge as the tiles of the browser show it
class _VersionThumbnail extends ConsumerWidget {
  const _VersionThumbnail({required this.entry});

  final NetworkEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(_bridgeUrlProvider(entry));
    final image = url.valueOrNull;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: SizedBox.square(
        dimension: 48,
        child: image == null
            ? const Icon(Icons.image_outlined)
            : Image(image: ref.watch(networkThumbnailImageProvider)(image), fit: BoxFit.cover),
      ),
    );
  }
}

final _bridgeUrlProvider = FutureProvider.autoDispose.family<Uri, NetworkEntry>(
  (ref, entry) => ref.read(networkConnectionsProvider).mediaUrl(entry.sourceId, entry.path),
);
