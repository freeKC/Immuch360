// The folders of this device at the top of On this device (Library): the folders chosen before, each opening the
// share browser on it with every subfolder, and "Browse a folder", which opens the system picker of Android. The albums
// of the device below list one flat album per folder that holds a photo or a video; here a folder is browsed as it is,
// its subfolders included, those without media and the splat files of a Meta Quest too. Android phones and tablets
// and the Meta Quest; hidden on iOS, on the computers (they have folders of their own), in the TV layout and on a
// television.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/device_folder.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:immich_mobile/providers/network/device_folders.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('DeviceFoldersSection');

/// Browse a folder: the system folder picker, then the share browser on the folder chosen, which stays in the list of
/// On this device. A picker that cannot open is told in a snack bar; nothing happens when the user goes back.
Future<void> browseDeviceFolder(BuildContext context, WidgetRef ref) async {
  // Read before the first await: the page may be gone by then
  final messenger = ScaffoldMessenger.maybeOf(context);
  final failed = context.t.device_folder_picker_failed;
  final String? sourceId;
  try {
    sourceId = await ref.read(deviceFoldersProvider.notifier).browse();
  } catch (error) {
    _log.warning('Could not open the folder picker: $error');
    messenger?.showSnackBar(SnackBar(content: Text(failed)));
    return;
  }
  if (sourceId == null || !context.mounted) {
    return;
  }
  await context.pushRoute(NetworkBrowserRoute(sourceId: sourceId, path: '/'));
}

/// Opens the share browser on [folder], a folder chosen before; says so in a snack bar when it cannot be read now
Future<void> openDeviceFolder(BuildContext context, WidgetRef ref, RecentTree folder) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final gone = context.t.device_folder_gone;
  final sourceId = await ref.read(deviceFoldersProvider.notifier).open(folder);
  if (sourceId == null) {
    messenger?.showSnackBar(SnackBar(content: Text(gone)));
    return;
  }
  if (!context.mounted) {
    return;
  }
  await context.pushRoute(NetworkBrowserRoute(sourceId: sourceId, path: '/'));
}

/// Where [folder] is, as its line under its name shows it: its place on its volume and the volume ("Download/Quest ·
/// Internal shared storage"), the volume or device alone when the provider does not tell the place
String deviceFolderLocation(RecentTree folder) {
  final path = deviceFolderPath(folder.treeUri);
  return path == null || path.isEmpty ? folder.title : '$path · ${folder.title}';
}

class DeviceFoldersSection extends ConsumerStatefulWidget {
  const DeviceFoldersSection({super.key});

  @override
  ConsumerState<DeviceFoldersSection> createState() => _DeviceFoldersSectionState();
}

class _DeviceFoldersSectionState extends ConsumerState<DeviceFoldersSection> {
  @override
  void initState() {
    super.initState();
    // A folder unplugged or deleted while the list was not on screen is told again
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(deviceFoldersSupportedProvider)) {
        unawaited(ref.read(deviceFoldersProvider.notifier).recheck());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(deviceFoldersSupportedProvider)) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(deviceFoldersProvider);
    final hint = ref.watch(deviceFolderPickerHintProvider).valueOrNull ?? false;
    final secondary = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              context.t.folders,
              key: const Key('device_folders_header'),
              style: context.textTheme.titleSmall?.copyWith(color: context.primaryColor, fontWeight: FontWeight.bold),
            ),
          ),
          for (final folder in state.folders)
            _FolderRow(folder: folder, missing: state.missing.contains(folder.treeUri)),
          ListTile(
            key: const Key('device_folder_browse'),
            leading: Icon(Icons.create_new_folder_outlined, color: context.primaryColor, size: 28),
            title: Text(
              context.t.device_folder_browse,
              style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(context.t.device_folder_browse_subtitle, style: secondary),
            onTap: () => unawaited(browseDeviceFolder(context, ref)),
          ),
          if (hint)
            Padding(
              key: const Key('device_folder_picker_hint'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                context.t.device_folder_picker_hint,
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
            ),
          const Divider(height: 16, indent: 10, endIndent: 10),
        ],
      ),
    );
  }
}

/// A folder chosen before: its name and where it is, or that it cannot be read now; a tap opens it, the cross takes it
/// out of the list (nothing on the device changes)
class _FolderRow extends ConsumerWidget {
  const _FolderRow({required this.folder, required this.missing});

  final RecentTree folder;
  final bool missing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secondary = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    return ListTile(
      key: ValueKey('device_folder:${folder.treeUri}'),
      leading: Icon(
        missing ? Icons.folder_off_outlined : Icons.folder_outlined,
        color: missing ? context.colorScheme.onSurfaceVariant : context.primaryColor,
        size: 28,
      ),
      title: Text(
        folder.folderName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        missing ? context.t.device_folder_unavailable : deviceFolderLocation(folder),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: secondary,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: context.t.remove,
        onPressed: () => unawaited(ref.read(deviceFoldersProvider.notifier).remove(folder)),
      ),
      onTap: () => unawaited(openDeviceFolder(context, ref, folder)),
    );
  }
}
