// "Play from a phone" on a big screen (a TV, the Quest window, a computer), in its settings: the switch, "Ask before
// a phone plays" (the Quest always asks), whether the screen listens, the phones linked with Remove, and "Link a
// phone", which shows the pairing panel in its link mode: the phone scans it from Connect a TV or computer, both
// show the check number, and the phone may then play films here. Without any Immich server too.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_panel.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_player.provider.dart';
import 'package:immich_ui/immich_ui.dart';

@RoutePage()
class PlayFromPhonePage extends ConsumerStatefulWidget {
  const PlayFromPhonePage({super.key});

  @override
  ConsumerState<PlayFromPhonePage> createState() => _PlayFromPhonePageState();
}

class _PlayFromPhonePageState extends ConsumerState<PlayFromPhonePage> {
  /// The pairing panel shows in place of the button
  bool _linking = false;

  Future<void> _remove(LinkedPeer phone) async {
    final t = context.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(t.play_from_phone_remove_confirm(phone: phone.name)),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(t.remove)),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(linkedPhonesProvider.notifier).remove(phone.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final enabled = ref.watch(playFromPhoneEnabledProvider);
    final ask = ref.watch(playFromPhoneAskProvider);
    final headset = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final phones = ref.watch(linkedPhonesProvider).valueOrNull ?? const <LinkedPeer>[];
    final view = ref.watch(screenPlayerProvider);
    final dates = DateFormat.yMMMd(context.locale.toLanguageTag());
    final status = !enabled
        ? null
        : phones.isEmpty
        ? t.play_from_phone_no_phone
        : view.listening
        ? t.play_from_phone_listening
        : switch (view.problem) {
            ScreenPlayerProblem.publicNetwork => t.pairing_screen_public_network,
            ScreenPlayerProblem.noNetwork || ScreenPlayerProblem.failed => t.play_from_phone_no_network,
            ScreenPlayerProblem.none => null,
          };
    return Scaffold(
      appBar: AppBar(title: Text(t.play_from_phone_title)),
      // Above a navigation bar at the bottom of the screen
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(ImmichSpacing.lg),
          children: [
            Text(t.play_from_phone_intro, style: theme.bodyLarge),
            const SizedBox(height: ImmichSpacing.md),
            SwitchListTile(
              key: const Key('play_from_phone_switch'),
              autofocus: true,
              contentPadding: EdgeInsets.zero,
              value: enabled,
              title: Text(t.play_from_phone_switch),
              subtitle: status == null ? null : Text(status, key: const Key('play_from_phone_status')),
              onChanged: (value) {
                ref.read(playFromPhoneEnabledProvider.notifier).state = value;
                unawaited(Store.put(StoreKey.playFromPhoneOff, !value));
              },
            ),
            if (headset)
              Padding(
                padding: const EdgeInsets.only(bottom: ImmichSpacing.sm),
                child: Text(t.play_from_phone_headset_asks, style: theme.bodySmall),
              )
            else
              SwitchListTile(
                key: const Key('play_from_phone_ask'),
                contentPadding: EdgeInsets.zero,
                value: ask,
                title: Text(t.play_from_phone_ask_switch),
                onChanged: (value) {
                  ref.read(playFromPhoneAskProvider.notifier).state = value;
                  unawaited(Store.put(StoreKey.playFromPhoneAsk, value));
                },
              ),
            const SizedBox(height: ImmichSpacing.md),
            Text(t.play_from_phone_linked_title, style: theme.titleMedium),
            const SizedBox(height: ImmichSpacing.sm),
            if (phones.isEmpty)
              Text(t.play_from_phone_linked_empty, style: theme.bodyMedium)
            else
              for (final phone in phones)
                ListTile(
                  key: ValueKey('play_from_phone_${phone.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.smartphone_rounded),
                  title: Text(phone.name),
                  subtitle: Text(t.play_from_phone_linked_since(date: dates.format(phone.linkedAt.toLocal()))),
                  trailing: TextButton(onPressed: () => unawaited(_remove(phone)), child: Text(t.remove)),
                ),
            const SizedBox(height: ImmichSpacing.lg),
            if (_linking)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(ImmichSpacing.md),
                  child: PairingPanel(
                    linkOnly: true,
                    onLinked: (_) {
                      if (mounted) {
                        setState(() => _linking = false);
                      }
                    },
                  ),
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('play_from_phone_link'),
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: Text(t.play_from_phone_link_button),
                  onPressed: () => setState(() => _linking = true),
                ),
              ),
            const SizedBox(height: ImmichSpacing.md),
            Text(t.play_from_phone_footer, style: theme.bodySmall),
          ],
        ),
      ),
    );
  }
}
