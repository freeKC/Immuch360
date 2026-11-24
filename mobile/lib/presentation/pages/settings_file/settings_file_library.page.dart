// The page of the "Settings file" card of the Library: what the file is for, then the two entries of Settings, Export
// the settings and Restore settings from a file (SettingsFileSettings), so that the card and Settings lead to the same
// pages. A remote control starts on the first entry; Back leaves.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/settings/settings_file_settings.dart';

class SettingsFileLibraryPage extends ConsumerWidget {
  const SettingsFileLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t.settings_file_title), elevation: 0, centerTitle: false),
      body: RemoteInitialFocus(
        enabled: ref.watch(tvModeProvider),
        child: SafeArea(
          child: ListView(
            key: const Key('settings_file_library_page'),
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  context.t.settings_file_subtitle,
                  style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ),
              const SettingsFileSettings(),
            ],
          ),
        ),
      ),
    );
  }
}
