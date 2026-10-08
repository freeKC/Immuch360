// The way to "Folders on this computer" from the pages that list the albums of the device: Library > On this computer
// and the albums chosen for backup. On a computer those albums are the folders the user chose (design 1.6), so before
// the first folder these pages could only say that there is nothing, with no way to the folders page but Settings >
// This computer. The shared pages hand over here on a computer only.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/folders.page.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/routing/router.dart';

/// Whether the folder library has at least one folder; null while it loads
final folderLibraryHasFoldersProvider = Provider<bool?>(
  (ref) => ref.watch(folderLibraryControllerProvider.select((view) => view.valueOrNull?.roots.isNotEmpty)),
);

/// Without a folder, the banner that asks for one; with folders, one line to add or remove some
class FoldersEntry extends ConsumerWidget {
  const FoldersEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(folderLibraryHasFoldersProvider)) {
      null => const SizedBox.shrink(),
      false => const FoldersBanner(),
      true => ListTile(
        key: const Key('desktop_folders_entry'),
        leading: const Icon(Icons.photo_library_outlined),
        title: Text(context.t.desktop_folders_title),
        subtitle: Text(context.t.desktop_folders_choose_title),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.pushRoute(const FoldersRoute()),
      ),
    };
  }
}
