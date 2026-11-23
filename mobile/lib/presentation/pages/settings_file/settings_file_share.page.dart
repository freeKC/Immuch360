// A folder of a network share to save a settings file in, or a settings file of a share to restore: the shares of
// files set up in the app (SMB, WebDAV), then their folders, as a remote control, a keyboard, a mouse or a finger
// reach them. Back goes up one folder, then back to the list of the shares, then out. Opened by the export and the
// restore pages (see SettingsFileShareIo).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_share_io.dart';
import 'package:logging/logging.dart';

final _log = Logger('SettingsFileSharePage');

enum SettingsFileShareMode {
  /// A folder to save the file in
  save,

  /// A settings file to restore
  open,
}

/// The folder (save) or the file (open) chosen, on its share
class SettingsFileSharePlace {
  const SettingsFileSharePlace(this.source, this.path);

  final NetworkSource source;
  final String path;
}

/// Opens the page above [context]: the place chosen, null when the user goes back
Future<SettingsFileSharePlace?> chooseSettingsFileSharePlace(BuildContext context, SettingsFileShareMode mode) =>
    Navigator.of(context).push<SettingsFileSharePlace>(
      MaterialPageRoute<SettingsFileSharePlace>(builder: (_) => SettingsFileSharePage(mode: mode)),
    );

/// Whether [entry] is shown: the folders, and in open mode the JSON files; never the hidden ones (the partial files of
/// the writer among them)
bool settingsFileShareEntryShown(NetworkEntry entry, SettingsFileShareMode mode) {
  if (entry.name.startsWith('.')) {
    return false;
  }
  if (entry.isDirectory) {
    return true;
  }
  return mode == SettingsFileShareMode.open && entry.name.toLowerCase().endsWith('.json');
}

class SettingsFileSharePage extends HookConsumerWidget {
  const SettingsFileSharePage({super.key, required this.mode});

  final SettingsFileShareMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shares = ref.watch(settingsFileSharesProvider);
    final io = ref.watch(settingsFileShareIoProvider);
    // With a single share, its folders straight away
    final source = useState<NetworkSource?>(shares.length == 1 ? shares.first : null);
    final path = useState<String>(shares.length == 1 ? _startOf(shares.first) : '/');
    final entries = useState<List<NetworkEntry>?>(null);
    final error = useState<Object?>(null);
    final attempt = useState(0);

    useEffect(() {
      final current = source.value;
      entries.value = null;
      error.value = null;
      if (current == null) {
        return null;
      }
      var live = true;
      unawaited(
        io
            .list(current.id, path.value)
            .then((listed) {
              if (live) {
                entries.value = [
                  for (final entry in listed)
                    if (settingsFileShareEntryShown(entry, mode)) entry,
                ];
              }
            })
            .catchError((Object e) {
              _log.info('The share ${current.name} could not be listed: $e');
              if (live) {
                error.value = e;
              }
            }),
      );
      return () => live = false;
    }, [source.value, path.value, attempt.value]);

    final atList = source.value == null;
    final singleShare = shares.length == 1;
    final atStart = !atList && path.value == _startOf(source.value!);

    void up() {
      if (atList) {
        return;
      }
      if (atStart) {
        if (singleShare) {
          Navigator.of(context).maybePop();
          return;
        }
        source.value = null;
        path.value = '/';
        return;
      }
      path.value = shareFolderOfPath(path.value);
    }

    final List<Widget> children;
    Widget? action;
    if (atList) {
      children = [
        for (final share in shares)
          ListTile(
            key: Key('settings_file_share_${share.id}'),
            leading: Icon(networkSourceIcon(share.type)),
            title: Text(share.name),
            subtitle: Text(share.host),
            onTap: () {
              path.value = _startOf(share);
              source.value = share;
            },
          ),
      ];
    } else if (error.value != null) {
      final e = error.value!;
      children = [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            e is NetworkFileSystemException
                ? context.t.network_share_failed(error: e.message)
                : context.t.scaffold_body_error_occurred,
            key: const Key('settings_file_share_error'),
            style: TextStyle(color: context.colorScheme.error),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: () => attempt.value++, child: Text(context.t.retry)),
          ),
        ),
      ];
    } else if (entries.value == null) {
      children = [
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    } else {
      final shown = entries.value!;
      children = [
        for (final entry in shown)
          ListTile(
            key: Key('settings_file_share_entry_${entry.name}'),
            leading: Icon(entry.isDirectory ? Icons.folder_outlined : Icons.description_outlined),
            title: Text(entry.name),
            onTap: () {
              if (entry.isDirectory) {
                path.value = entry.path;
              } else {
                Navigator.of(context).pop(SettingsFileSharePlace(source.value!, entry.path));
              }
            },
          ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              mode == SettingsFileShareMode.open
                  ? context.t.settings_file_share_no_file
                  : context.t.network_share_empty_folder,
              key: const Key('settings_file_share_empty'),
            ),
          ),
      ];
      if (mode == SettingsFileShareMode.save) {
        action = FilledButton.icon(
          key: const Key('settings_file_share_save_here'),
          icon: const Icon(Icons.save_alt_rounded),
          label: Text(context.t.settings_file_share_save_here),
          onPressed: () => Navigator.of(context).pop(SettingsFileSharePlace(source.value!, path.value)),
        );
      }
    }

    final where = atList ? null : '${source.value!.name} · ${path.value}';

    return PopScope(
      // Back goes up the folders first
      canPop: atList || (atStart && singleShare),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          up();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            mode == SettingsFileShareMode.save
                ? context.t.settings_file_share_choose_folder
                : context.t.settings_file_share_choose_file,
          ),
          elevation: 0,
          centerTitle: false,
        ),
        body: RemoteInitialFocus(
          // Each new folder starts on its first entry
          key: ValueKey('${source.value?.id}:${path.value}:${entries.value != null}'),
          enabled: ref.watch(tvModeProvider),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (where != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      where,
                      key: const Key('settings_file_share_where'),
                      style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.only(bottom: 16), children: children),
                ),
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Align(alignment: Alignment.centerRight, child: action),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _startOf(NetworkSource source) => source.rootPath.isEmpty ? '/' : source.rootPath;
