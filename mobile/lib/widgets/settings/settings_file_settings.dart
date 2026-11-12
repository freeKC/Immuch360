// Settings, Settings file (issue 16): export this install's servers, sources, settings and backup albums to a file,
// or restore them from one. Shown with and without a server, on every device.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_export.page.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_import.page.dart';

class SettingsFileSettings extends StatelessWidget {
  const SettingsFileSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      children: [
        ListTile(
          key: const Key('settings_file_export'),
          leading: const Icon(Icons.upload_file_rounded),
          title: Text(context.t.settings_file_export_title),
          subtitle: Text(context.t.settings_file_export_subtitle),
          onTap: () => unawaited(
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsFileExportPage())),
          ),
        ),
        ListTile(
          key: const Key('settings_file_import'),
          leading: const Icon(Icons.settings_backup_restore_rounded),
          title: Text(context.t.settings_file_import_title),
          subtitle: Text(context.t.settings_file_import_subtitle),
          onTap: () => unawaited(openSettingsFileImport(context)),
        ),
      ],
    );
  }
}
