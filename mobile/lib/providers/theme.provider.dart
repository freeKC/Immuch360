import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/theme_data.dart';

// Provider for current selected theme
final immichThemeProvider = StateProvider<ImmichTheme>((ref) {
  final themeConfig = ref.watch(appConfigProvider.select((config) => config.theme));

  final ImmichTheme? dynamicTheme = DynamicTheme.theme;
  final currentTheme = (themeConfig.dynamicTheme && dynamicTheme != null)
      ? dynamicTheme
      : themeConfig.primaryColor.themeOfPreset;

  return themeConfig.colorfulInterface ? currentTheme : decolorizeSurfaces(theme: currentTheme);
});

/// The theme mode of the app: the setting, except that Automatic is dark on a TV. Many TVs report a light system
/// theme, and a white page is too bright across a room. Light and Dark stay as chosen. Decided by the device, known
/// before the first frame, not by the remote control layout: a tablet with the layout turned on is no TV screen.
final appThemeModeProvider = Provider.autoDispose<ThemeMode>((ref) {
  final mode = ref.watch(appConfigProvider.select((config) => config.theme.mode));
  return resolveThemeMode(mode, television: ref.watch(tvDeviceProvider).isTelevision);
});

/// The theme mode the app uses for the setting [mode]: Automatic (system) is dark on a [television]
ThemeMode resolveThemeMode(ThemeMode mode, {required bool television}) =>
    television && mode == ThemeMode.system ? ThemeMode.dark : mode;
