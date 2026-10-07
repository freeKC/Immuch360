import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// The remote control layout: Automatic turns it on on Android TV and Google TV only; On also serves a phone or a
/// tablet driven by a keyboard or a game pad. The whole app follows at once (tvModeProvider).
class TvLayoutSetting extends ConsumerWidget {
  const TvLayoutSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(appConfigProvider.select((config) => config.tvLayout));

    void onChanged(TvLayoutMode? value) {
      if (value != null && value != layout) {
        unawaited(ref.read(settingsProvider).write(SettingsKey.tvLayout, value));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroupTitle(title: context.t.tv_layout, icon: Icons.tv_outlined),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            context.t.tv_layout_description,
            style: context.textTheme.bodyMedium!.copyWith(color: context.textTheme.bodyMedium!.color!.withAlpha(215)),
          ),
        ),
        SettingsRadioListTile(
          groups: [
            SettingsRadioGroup(title: context.t.tv_layout_auto, value: TvLayoutMode.auto),
            SettingsRadioGroup(title: context.t.tv_layout_on, value: TvLayoutMode.on),
            SettingsRadioGroup(title: context.t.tv_layout_off, value: TvLayoutMode.off),
          ],
          groupBy: layout,
          onRadioChanged: onChanged,
        ),
      ],
    );
  }
}
