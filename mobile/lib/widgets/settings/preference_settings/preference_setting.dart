import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/haptic_setting.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/share_setting.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/theme_setting.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/tv_layout_setting.dart';
import 'package:immich_ui/immich_ui.dart';

class PreferenceSetting extends StatelessWidget {
  const PreferenceSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final preferenceSettings = [
      const ThemeSetting(),
      const HapticSetting(),
      const ShareSetting(),
      // Android only: Android TV, and the phones and tablets driven by a keyboard or a game pad
      if (defaultTargetPlatform == TargetPlatform.android) const TvLayoutSetting(),
    ];

    return SettingsSubPageScaffold(settings: preferenceSettings, showDivider: true);
  }
}
