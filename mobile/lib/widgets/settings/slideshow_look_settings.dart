// Settings, Advanced, on a Meta Quest: the background and the transition of the photos of a flat screen in the
// immersive viewer (issue 19, the choices promised on 19 November 2026). The two buttons of the panel in the headset
// change the same settings (ImmersiveEvents.slideshowLookChanged).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/headset_slideshow_look.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// The name of [background] in the settings and in the headset
String slideshowBackgroundName(Translations t, SlideshowBackground background) => switch (background) {
  SlideshowBackground.black => t.immersive_slideshow_background_black,
  SlideshowBackground.blurred => t.immersive_slideshow_background_blurred,
  SlideshowBackground.passthrough => t.immersive_slideshow_background_passthrough,
};

/// The name of [transition] in the settings and in the headset
String slideshowTransitionName(Translations t, SlideshowTransition transition) => switch (transition) {
  SlideshowTransition.none => t.immersive_slideshow_transition_none,
  SlideshowTransition.crossFade => t.immersive_slideshow_transition_cross_fade,
  SlideshowTransition.slide => t.immersive_slideshow_transition_slide,
};

class SlideshowLookSettings extends ConsumerWidget {
  const SlideshowLookSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appConfigProvider.select((config) => config.viewer.headsetLook));
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(title: t.immersive_slideshow_background_setting_title),
        _Subtitle(text: t.immersive_slideshow_background_setting_subtitle),
        SettingsRadioListTile<SlideshowBackground>(
          key: const Key('advanced_settings_slideshow_background'),
          groups: [
            for (final background in SlideshowBackground.values)
              SettingsRadioGroup(title: slideshowBackgroundName(t, background), value: background),
          ],
          groupBy: look.background,
          onRadioChanged: (value) {
            if (value != null && value != look.background) {
              unawaited(ref.read(settingsProvider).write(.viewerSlideshowBackground, value));
            }
          },
        ),
        _Heading(title: t.immersive_slideshow_transition_setting_title),
        _Subtitle(text: t.immersive_slideshow_transition_setting_subtitle),
        SettingsRadioListTile<SlideshowTransition>(
          key: const Key('advanced_settings_slideshow_transition'),
          groups: [
            for (final transition in SlideshowTransition.values)
              SettingsRadioGroup(title: slideshowTransitionName(t, transition), value: transition),
          ],
          groupBy: look.transition,
          onRadioChanged: (value) {
            if (value != null && value != look.transition) {
              unawaited(ref.read(settingsProvider).write(.viewerSlideshowTransition, value));
            }
          },
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 20, right: 20, top: 12),
    child: Text(title, style: context.textTheme.titleMedium),
  );
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Text(
      text,
      style: context.textTheme.bodyMedium!.copyWith(color: context.textTheme.bodyMedium!.color!.withAlpha(215)),
    ),
  );
}
