import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('DownloadFolderTile');

/// The download folder in the "This computer" settings: where "Download" puts the files of the server, and a button
/// that changes it with the system's folder dialog. The path is shown in full, since it is the answer to "where did my
/// photos go".
class DownloadFolderTile extends StatefulWidget {
  const DownloadFolderTile({super.key, this.folder});

  /// The setting shown; the app's own when null
  final DownloadFolder? folder;

  @override
  State<DownloadFolderTile> createState() => _DownloadFolderTileState();
}

class _DownloadFolderTileState extends State<DownloadFolderTile> {
  DownloadFolder get _folder => widget.folder ?? DownloadFolder.instance;

  String? _path;

  @override
  void initState() {
    super.initState();
    _folder.chosen.addListener(_refresh);
    _refresh();
  }

  @override
  void didUpdateWidget(DownloadFolderTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.folder ?? DownloadFolder.instance;
    if (previous != _folder) {
      previous.chosen.removeListener(_refresh);
      _folder.chosen.addListener(_refresh);
      _refresh();
    }
  }

  @override
  void dispose() {
    _folder.chosen.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    unawaited(
      _folder.currentPath().then((path) {
        if (mounted) {
          setState(() => _path = path);
        }
      }),
    );
  }

  Future<void> _change() async {
    try {
      final picked = await filePickers.folder(
        initialDirectory: _path,
        confirmButtonText: context.t.desktop_download_folder_change,
      );
      if (picked != null) {
        await _folder.choose(picked);
      }
    } on Exception catch (error) {
      // A dialog that fails, or a settings file that cannot be written: the folder stays as it was, and says so
      _log.warning('The download folder was not changed: $error');
      snackbar.error(StaticTranslations.instance.scaffold_body_error_occurred);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return ListTile(
      key: const Key('desktop_settings_download_folder'),
      leading: const Icon(Icons.download_outlined),
      title: Text(context.t.desktop_download_folder),
      subtitle: Text(
        path == null
            ? context.t.desktop_download_folder_subtitle
            : '${context.t.desktop_download_folder_subtitle}\n$path',
      ),
      isThreeLine: path != null,
      trailing: IconButton(
        key: const Key('desktop_settings_download_folder_change'),
        icon: const Icon(Icons.folder_open_outlined),
        tooltip: context.t.desktop_download_folder_change,
        onPressed: _change,
      ),
      onTap: _change,
    );
  }
}
