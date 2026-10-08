import 'dart:async';

import 'package:auto_route/auto_route.dart';
// The folder picker of the system through the interface, whose Windows, macOS and Linux implementations the app
// already has (image_picker brings them): file_selector itself would add its Android and iOS plugins to the phones
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:path/path.dart' as p;

/// Asks the user for a folder; null when they gave up. Replaced in tests.
final folderPickerProvider = Provider<Future<String?> Function()>(
  (ref) =>
      () => FileSelectorPlatform.instance.getDirectoryPathWithOptions(const FileDialogOptions()),
);

/// "Folders on this computer": the folders whose photos and videos the app shows on a computer, in place of the
/// gallery of a phone. Nothing is scanned before the user chose a folder here.
@RoutePage()
class FoldersPage extends ConsumerWidget {
  const FoldersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(folderLibraryControllerProvider);
    final scanning = view.valueOrNull?.scanning ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.desktop_folders_title),
        actions: [
          IconButton(
            key: const Key('desktop_folders_refresh'),
            tooltip: context.t.refresh,
            icon: const Icon(Icons.refresh),
            // The user asks: the network folders too, which the automatic rescans read only now and then
            onPressed: () => unawaited(ref.read(folderLibraryControllerProvider.notifier).refresh(everyRoot: true)),
          ),
        ],
      ),
      body: switch (view) {
        AsyncData(:final value) => _FoldersList(view: value, scanning: scanning),
        AsyncError() => Center(child: Text(context.t.failed_to_load_folder)),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _FoldersList extends ConsumerWidget {
  const _FoldersList({required this.view, required this.scanning});

  final FolderLibraryView view;
  final bool scanning;

  Future<void> _add(BuildContext context, WidgetRef ref, String path) async {
    final controller = ref.read(folderLibraryControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final notFound = context.t.folder_not_found;
    try {
      await controller.addFolder(path);
    } on FolderNotAddedException {
      messenger.showSnackBar(SnackBar(content: Text(notFound)));
    }
  }

  Future<void> _pickAndAdd(BuildContext context, WidgetRef ref) async {
    final path = await ref.read(folderPickerProvider)();
    if (path == null || !context.mounted) {
      return;
    }
    await _add(context, ref, path);
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, LibraryRoot root) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t.desktop_folders_remove),
        content: Text('${root.path}\n\n${dialogContext.t.desktop_folders_remove_info}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(dialogContext.t.cancel)),
          TextButton(
            key: const Key('desktop_folders_remove_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t.remove),
          ),
        ],
      ),
    );
    if ((remove ?? false) && context.mounted) {
      await ref.read(folderLibraryControllerProvider.notifier).removeFolder(root.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final roots = view.roots;
    final suggestions = view.suggestions;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(t.desktop_folders_choose_body, style: context.textTheme.bodyMedium),
        ),
        if (scanning) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Semantics(liveRegion: true, child: Text(t.desktop_folders_scanning)),
          ),
        ],
        const SizedBox(height: 16),
        if (roots.isEmpty)
          ListTile(leading: const Icon(Icons.folder_off_outlined), title: Text(t.desktop_folders_empty))
        else
          for (final root in roots)
            _RootTile(
              key: ValueKey('desktop_folder_${root.id}'),
              root: root,
              onRemove: () => unawaited(_confirmRemove(context, ref, root)),
              onIncludeCloudOnly: () =>
                  unawaited(ref.read(folderLibraryControllerProvider.notifier).includeCloudOnly(root.id)),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const Key('desktop_folders_add'),
              onPressed: () => unawaited(_pickAndAdd(context, ref)),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(t.desktop_folders_add),
            ),
          ),
        ),
        if (suggestions.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Semantics(
              header: true,
              child: Text(t.desktop_folders_suggestions, style: context.textTheme.titleSmall),
            ),
          ),
          for (final suggestion in suggestions)
            _SuggestionTile(
              key: ValueKey('desktop_folder_suggestion_${suggestion.path}'),
              suggestion: suggestion,
              root: _rootOf(suggestion.path, roots),
              onAdd: () => unawaited(_add(context, ref, suggestion.path)),
              onRemove: (root) => unawaited(_confirmRemove(context, ref, root)),
            ),
        ],
      ],
    );
  }

  /// The root that covers [path]: the root at that folder or one around it
  static LibraryRoot? _rootOf(String path, List<LibraryRoot> roots) {
    for (final root in roots) {
      if (p.equals(root.path, path) || p.isWithin(root.path, path)) {
        return root;
      }
    }
    return null;
  }
}

class _RootTile extends StatelessWidget {
  const _RootTile({super.key, required this.root, required this.onRemove, required this.onIncludeCloudOnly});

  final LibraryRoot root;
  final VoidCallback onRemove;
  final VoidCallback onIncludeCloudOnly;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final details = [
      root.path,
      if (!root.available) t.desktop_folders_drive_missing else t.desktop_folders_count(count: root.fileCount),
      if (root.isNetwork) t.desktop_folders_network_hint,
    ];
    final cloudOnly = root.cloudOnlyCount > 0 && !root.includeCloudOnly;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(
            !root.available
                ? Icons.usb_off_outlined
                : root.isNetwork
                ? Icons.lan_outlined
                : Icons.folder_outlined,
          ),
          title: Text(root.displayName),
          subtitle: Text(details.join('\n')),
          isThreeLine: details.length > 2,
          trailing: IconButton(
            key: ValueKey('desktop_folder_remove_${root.id}'),
            tooltip: t.desktop_folders_remove,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: onRemove,
          ),
        ),
        if (cloudOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.desktop_cloud_only_count(count: root.cloudOnlyCount), style: context.textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(t.desktop_cloud_only_info, style: context.textTheme.bodySmall),
                TextButton.icon(
                  key: ValueKey('desktop_folder_cloud_${root.id}'),
                  onPressed: onIncludeCloudOnly,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: Text(t.desktop_cloud_only_include),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    super.key,
    required this.suggestion,
    required this.root,
    required this.onAdd,
    required this.onRemove,
  });

  final FolderSuggestion suggestion;

  /// The root that already covers the suggestion, if any
  final LibraryRoot? root;
  final VoidCallback onAdd;
  final ValueChanged<LibraryRoot> onRemove;

  @override
  Widget build(BuildContext context) {
    final covering = root;
    // Only the root at the very folder can be taken out from here; one around it is taken out from its own tile
    final canUncheck = covering != null && p.equals(covering.path, suggestion.path);
    void changed(bool? checked) {
      if (covering == null && (checked ?? false)) {
        onAdd();
      } else if (covering != null && !(checked ?? true)) {
        onRemove(covering);
      }
    }

    return CheckboxListTile(
      value: covering != null,
      onChanged: covering == null || canUncheck ? changed : null,
      secondary: const Icon(Icons.photo_library_outlined),
      title: Text(p.basename(suggestion.path)),
      subtitle: Text(suggestion.path),
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}

/// Shown at the top of the Photos tab of a session without a server on a computer, where a phone asks for the gallery
/// permission: the way to the folders page while no folder is chosen
class FoldersBanner extends StatelessWidget {
  const FoldersBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        color: context.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_outlined, color: context.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.t.desktop_folders_choose_title,
                      style: context.textTheme.titleSmall?.copyWith(color: context.colorScheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                context.t.desktop_folders_choose_body,
                style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSecondaryContainer),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('desktop_folders_open'),
                onPressed: () => context.pushRoute(const FoldersRoute()),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(context.t.desktop_folders_add),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
