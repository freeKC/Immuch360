// The kiosk mode of the Meta Quest in the advanced settings (lot quest-kiosk, see KioskConfig): the switch, on by
// default like the other experimental switches; the media the app opens at its start, with Choose (the 360° list in a
// picking mode, see KioskMediaPickerPage) and Clear; the text of the end card. Shown on Horizon OS only. The need comes
// from the exhibition builds of ppawelstachh-sys/Immuch360 (branch immuch360).

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

/// Opens the picker of the kiosk media from [context] and gives what was picked, null when the user went back. Tests
/// replace it.
final kioskMediaPickerProvider = Provider<Future<KioskMedia?> Function(BuildContext context)>(
  (_) =>
      (context) => context.pushRoute<KioskMedia>(const KioskMediaPickerRoute()),
);

/// See the top of this file
class KioskSettings extends HookConsumerWidget {
  const KioskSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final kiosk = ref.watch(appConfigProvider).kiosk;
    final enabled = useState(kiosk.enabled);
    useValueChanged<bool, void>(
      enabled.value,
      (_, _) => unawaited(ref.read(settingsProvider).write(.kioskEnabled, enabled.value)),
    );
    final media = useState(kiosk.chosenMedia);
    final endText = useTextEditingController(text: kiosk.endText ?? '');

    Future<void> choose() async {
      final picked = await ref.read(kioskMediaPickerProvider)(context);
      if (picked == null) {
        return;
      }
      media.value = picked;
      await ref.read(settingsProvider).write(.kioskMedia, picked.encode());
    }

    Future<void> clear() async {
      media.value = null;
      await ref.read(settingsProvider).write(.kioskMedia, null);
    }

    final chosen = media.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSwitchListTile(
          key: const Key('advanced_settings_kiosk_enabled'),
          valueNotifier: enabled,
          title: t.kiosk_mode_title,
          subtitle: t.kiosk_mode_subtitle,
        ),
        ListTile(
          key: const Key('advanced_settings_kiosk_media'),
          enabled: enabled.value,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Icon(chosen != null && chosen.isVideo ? Icons.videocam_outlined : Icons.threesixty_rounded),
          title: Text(t.kiosk_mode_media, style: const TextStyle(fontWeight: FontWeight.w500)),
          subtitle: Text(chosen?.name ?? t.kiosk_mode_media_none),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chosen != null)
                TextButton(
                  key: const Key('advanced_settings_kiosk_clear'),
                  onPressed: enabled.value ? () => unawaited(clear()) : null,
                  child: Text(t.clear),
                ),
              TextButton(
                key: const Key('advanced_settings_kiosk_choose'),
                onPressed: enabled.value ? () => unawaited(choose()) : null,
                child: Text(t.choose),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: TextField(
            key: const Key('advanced_settings_kiosk_end_text'),
            controller: endText,
            enabled: enabled.value,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: t.kiosk_mode_end_text,
              hintText: t.kiosk_mode_end_text_default,
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
            // Empty: the default, translated in the language of the app at each start
            onChanged: (text) =>
                unawaited(ref.read(settingsProvider).write(.kioskEndText, text.trim().isEmpty ? null : text.trim())),
          ),
        ),
      ],
    );
  }
}
