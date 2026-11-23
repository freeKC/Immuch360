// The "Settings file" card of the Library, beside Drone (FreeKC, 22 November 2026: "une tuile d'export des paramètres
// directement dans Bibliothèque à côté de drone"): the export and the restore of the settings file (issue 16) one tap
// away, without going down Settings. It opens SettingsFileLibraryPage, whose two entries are those of Settings, so both
// places lead to the same pages. Hidden only where both actions would end on "no file picker" (settingsFileCardProvider).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_library.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_share_io.dart';

/// Opens the page of the card above the tabs, as the other cards of the Library open theirs
Future<void> openSettingsFileLibraryPage(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => const SettingsFileLibraryPage()));

/// The square card, built as the Drone one: the primary colour gradient, the restore icon of the Settings entry, the
/// label under it
class SettingsFileCollectionCard extends ConsumerWidget {
  const SettingsFileCollectionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(settingsFileCardProvider)) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final widthFactor = isTablet ? 0.25 : 0.5;
        final size = context.width * widthFactor - 20.0;
        return RemoteFocusable(
          key: const Key('settings_file_card'),
          onTap: () => unawaited(openSettingsFileLibraryPage(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: size,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    gradient: LinearGradient(
                      colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Center(
                    child: Icon(Icons.settings_backup_restore_rounded, size: size / 3, color: context.primaryColor),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.settings_file_title,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
