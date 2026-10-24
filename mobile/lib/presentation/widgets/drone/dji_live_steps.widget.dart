// The step cards of the DJI live video (p2/design-ux-phone-2026-10-24.md, 3.4): while no picture shows, the middle of
// the screen is one card under three dots, Remote, Drone, Picture: a title, one line, at most one button, and after a
// while a "Nothing yet?" hint. The offer to open the screen when the remote is plugged in sits on the plug step only.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_stage.dart';

/// The three dots, filled up to [filled]
class DjiLiveDots extends StatelessWidget {
  const DjiLiveDots({super.key, required this.filled});

  final int filled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final labels = [t.dji_live_step_remote, t.dji_live_step_drone, t.dji_live_step_picture];
    final style = context.textTheme.labelMedium?.copyWith(color: Colors.white70);
    return Wrap(
      key: const Key('dji_live_dots'),
      alignment: WrapAlignment.center,
      spacing: 20,
      runSpacing: 4,
      children: [
        for (final (index, label) in labels.indexed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                index < filled ? Icons.circle : Icons.circle_outlined,
                key: Key('dji_live_dot_${index}_${index < filled ? 'on' : 'off'}'),
                size: 12,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(label, style: style),
            ],
          ),
      ],
    );
  }
}

/// What the card of a stage says: a title, one line, the extra lines under it
class DjiLiveCardText {
  const DjiLiveCardText(this.title, this.line, [this.extra = const []]);

  final String title;
  final String line;
  final List<String> extra;
}

/// The words of the card of [stage]; null for the stages without a card (the picture, a capture, the first check)
DjiLiveCardText? djiLiveCardText(
  Translations t,
  DjiLiveStage stage, {
  required int seconds,
  bool djiFly = false,
  bool untried = false,
  bool remoteAnswers = false,
  bool aircraftPresent = true,
}) {
  final slow = djiLiveSlow(stage, seconds);
  final untriedLine = [if (untried) t.dji_live_untried];
  return switch (stage) {
    DjiLiveStage.checking || DjiLiveStage.live || DjiLiveStage.capture => null,
    DjiLiveStage.noUsb => DjiLiveCardText(t.dji_live_no_usb_title, t.dji_live_no_usb),
    DjiLiveStage.plug => DjiLiveCardText(t.dji_live_plug_title, t.dji_live_plug, [
      if (djiFly) t.dji_live_dji_fly,
      if (slow) ...[t.dji_live_slow_title, t.dji_live_slow_cable],
    ]),
    DjiLiveStage.chooser => DjiLiveCardText(t.dji_live_remote_found, t.dji_live_chooser, untriedLine),
    DjiLiveStage.allow => DjiLiveCardText(t.dji_live_allow_title, t.dji_live_allow, untriedLine),
    DjiLiveStage.refused => DjiLiveCardText(t.dji_live_refused_title, t.dji_live_refused),
    DjiLiveStage.busy => DjiLiveCardText(t.dji_live_busy_title, t.dji_live_busy),
    DjiLiveStage.remote => DjiLiveCardText(t.dji_live_remote_title, t.dji_live_remote, [
      ...untriedLine,
      if (slow) ...[t.dji_live_slow_title, remoteAnswers ? t.dji_live_slow_drone : t.dji_live_slow_silent],
    ]),
    DjiLiveStage.drone => DjiLiveCardText(t.dji_live_drone_title, t.dji_live_drone, [
      ...untriedLine,
      if (slow) ...[t.dji_live_slow_title, t.dji_live_slow_picture],
    ]),
    DjiLiveStage.noPicture => DjiLiveCardText(
      t.dji_live_no_picture_title,
      aircraftPresent ? t.dji_live_no_picture : t.dji_live_drone_silent,
    ),
    DjiLiveStage.unplugged => DjiLiveCardText(t.dji_live_unplugged_title, t.dji_live_unplugged),
    DjiLiveStage.lost => DjiLiveCardText(t.dji_live_lost_title, t.dji_live_lost),
    DjiLiveStage.unread => DjiLiveCardText(t.dji_live_unread, t.dji_live_untried),
  };
}

/// The card in the middle of the black picture area: the dots, the words, the one button of the stage, and the offer
class DjiLiveStepCard extends StatelessWidget {
  const DjiLiveStepCard({
    super.key,
    required this.stage,
    required this.text,
    this.onRetry,
    this.offer = false,
    this.onOfferYes,
    this.onOfferNo,
  });

  final DjiLiveStage stage;
  final DjiLiveCardText text;

  /// "Ask again" on a refused permission, "Try again" on a lost link
  final VoidCallback? onRetry;

  /// The offer to open this screen when the remote is plugged in
  final bool offer;
  final VoidCallback? onOfferYes;
  final VoidCallback? onOfferNo;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final white = context.textTheme.bodyMedium?.copyWith(color: Colors.white);
    final retry = switch (stage) {
      DjiLiveStage.refused => t.dji_live_ask_again,
      DjiLiveStage.lost => t.dji_live_try_again,
      _ => null,
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          key: Key('dji_live_card_${stage.name}'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stage != DjiLiveStage.noUsb && stage != DjiLiveStage.noPicture) ...[
              Center(child: DjiLiveDots(filled: djiLiveDots(stage))),
              const SizedBox(height: 16),
            ],
            Text(
              text.title,
              key: const Key('dji_live_card_title'),
              style: context.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(text.line, key: const Key('dji_live_card_line'), style: white),
            for (final extra in text.extra)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(extra, style: white?.copyWith(color: Colors.white70)),
              ),
            if (retry != null && onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton(key: const Key('dji_live_retry'), onPressed: onRetry, child: Text(retry)),
            ],
            if (offer) ...[
              const SizedBox(height: 16),
              Card(
                key: const Key('dji_live_offer'),
                color: Colors.white10,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.dji_live_offer_title, style: white?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(t.dji_live_offer, style: white?.copyWith(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            key: const Key('dji_live_offer_yes'),
                            onPressed: onOfferYes,
                            child: Text(t.dji_live_offer_yes),
                          ),
                          TextButton(
                            key: const Key('dji_live_offer_no'),
                            onPressed: onOfferNo,
                            child: Text(t.dji_live_offer_no),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
