// The invitation to rate the app in Settings (lib/domain/services/rate_app.service.dart): two lasting entries, and the
// quiet line of the Quest store build while it waits for an answer.
//
// * Rate Immuch360, on every store build (Google Play, the App Store, the Meta Horizon Store): opens the page of the
//   app on its store, never the review API (Google and Apple ask that a button opens the store page instead), and the
//   invitation never asks again.
// * Something not working?, on every build: the GitHub issues of Immuch360, so that a problem reaches us. The same
//   entries to everyone, side by side: nothing asks first whether the user is happy (the stores forbid steering only
//   the happy users to a rating).
// * The line of the Quest store build, at the top of Settings after it showed at the end of a viewing: the sentence,
//   Rate, Something not working? and No thanks, three written buttons. Nothing takes the focus.
// * A page that did not open shows its address, to open on another device.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/open_url.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/rate_app.provider.dart';
import 'package:immich_mobile/utils/store_channel.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens the GitHub issues of Immuch360 (an address to copy in the remote control layout, which has no browser). A
/// page that did not open shows its address
Future<void> openRateAppProblemPage(BuildContext context, {required bool tvMode}) async {
  final url = Uri.parse(kImmuch360IssuesLink);
  final opened = await openUrl(context, url, mode: LaunchMode.externalApplication, tvMode: tvMode);
  // The remote control layout already showed the address
  if (!opened && !tvMode && context.mounted) {
    await showRateAppAddress(context, url);
  }
}

/// Rate Immuch360: the store page, or its address when it did not open on this device
Future<void> openRateAppStorePage(BuildContext context, WidgetRef ref, RateAppChannel channel) async {
  if (await rateAppFromSettings(ref)) {
    return;
  }
  final pages = rateAppStorePages(channel).where((url) => url.isScheme('https'));
  if (pages.isNotEmpty && context.mounted) {
    await showRateAppAddress(context, pages.last);
  }
}

/// A page that did not open: its address, to open elsewhere
Future<void> showRateAppAddress(BuildContext context, Uri url) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    key: const Key('rate_app_address'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t.rate_app_page_not_opened),
        const SizedBox(height: 12),
        SelectableText(url.toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
    actions: [TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(context.t.close))],
  ),
);

/// The lasting entries of Settings: Rate Immuch360 on a store build, Something not working? on every build. [cards]
/// for the list of the phones, list tiles for the two panes of the tablets, the TVs and the Quest
class RateAppSettingsEntries extends ConsumerWidget {
  const RateAppSettingsEntries({super.key, this.cards = true});

  final bool cards;

  static const rateKey = Key('settings_rate_app');
  static const problemKey = Key('settings_rate_app_problem');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(rateAppChannelProvider).valueOrNull ?? RateAppChannel.none;
    final store = channel.canAsk ? rateAppStoreName(channel) : null;
    final tvMode = ref.watch(tvModeProvider);
    final t = context.t;
    Widget entry({
      required Key key,
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) => cards
        ? SettingsCard(key: key, icon: icon, title: title, subtitle: subtitle, onTap: onTap)
        : ListTile(key: key, leading: Icon(icon), title: Text(title), subtitle: Text(subtitle), onTap: onTap);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (store != null)
          entry(
            key: rateKey,
            icon: Icons.star_outline_rounded,
            title: t.rate_app_settings_title,
            subtitle: t.rate_app_settings_subtitle(store: store),
            onTap: () => unawaited(openRateAppStorePage(context, ref, channel)),
          ),
        entry(
          key: problemKey,
          icon: Icons.bug_report_outlined,
          title: t.rate_app_problem,
          subtitle: t.rate_app_problem_subtitle,
          onTap: () => unawaited(openRateAppProblemPage(context, tvMode: tvMode)),
        ),
      ],
    );
  }
}

/// The quiet line of the Quest store build at the top of Settings, while it waits for an answer; nothing otherwise
class RateAppSettingsLine extends ConsumerWidget {
  const RateAppSettingsLine({super.key});

  static const lineKey = Key('rate_app_line');
  static const rateKey = Key('rate_app_line_rate');
  static const problemKey = Key('rate_app_line_problem');
  static const noThanksKey = Key('rate_app_line_no_thanks');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(rateAppServiceProvider).valueOrNull;
    if (service == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<bool>(
      valueListenable: service.line,
      builder: (context, waits, _) => waits
          ? RateAppLine(
              onRate: () => unawaited(service.answer(RateAppAnswer.rate)),
              onProblem: () => unawaited(openRateAppProblemPage(context, tvMode: ref.read(tvModeProvider))),
              onNoThanks: () => unawaited(service.answer(RateAppAnswer.noThanks)),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// See [RateAppSettingsLine]
class RateAppLine extends StatelessWidget {
  const RateAppLine({super.key, required this.onRate, required this.onProblem, required this.onNoThanks});

  final VoidCallback onRate;
  final VoidCallback onProblem;
  final VoidCallback onNoThanks;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      key: RateAppSettingsLine.lineKey,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: context.colorScheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(t.rate_app_horizon_invite, style: context.textTheme.bodyMedium),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(key: RateAppSettingsLine.rateKey, onPressed: onRate, child: Text(t.rate_app_rate)),
                        TextButton(
                          key: RateAppSettingsLine.problemKey,
                          onPressed: onProblem,
                          child: Text(t.rate_app_problem),
                        ),
                        // Written out: it ends the invitation for good, which a close icon would not say
                        TextButton(
                          key: RateAppSettingsLine.noThanksKey,
                          onPressed: onNoThanks,
                          child: Text(t.rate_app_no_thanks),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
