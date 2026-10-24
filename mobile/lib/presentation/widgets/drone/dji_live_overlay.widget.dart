// What the DJI live video draws beside the picture (p2/design-ux-phone-2026-10-24.md, 3.3): on the left Back, Send to a
// headset and Advanced, with the headsets watching under them; on the right the state of the picture as measured here
// and the values the gate lets through. They sit in the black bands beside the 16:9 picture, or at its edges over a
// dark gradient on a screen with no band. Nothing in the picture itself takes a touch, and nothing here looks like a
// flight control: no sticks, no take off, landing, return or record button, no camera control.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_stage.dart';

/// The width of a column drawn over the picture on a screen with no band beside it
const djiLiveEdgeWidth = 72.0;

/// The gradient under a column drawn over the picture, from 60 % black at the edge to transparent
BoxDecoration djiLiveEdgeShade({required bool left}) => BoxDecoration(
  gradient: LinearGradient(
    begin: left ? Alignment.centerLeft : Alignment.centerRight,
    end: left ? Alignment.centerRight : Alignment.centerLeft,
    colors: const [Color(0x99000000), Color(0x00000000)],
  ),
);

/// The left column: three buttons, white on black, 48 dp targets, and the headsets watching under them
class DjiLiveButtons extends StatelessWidget {
  const DjiLiveButtons({
    super.key,
    required this.onBack,
    required this.onAdvanced,
    this.onSend,
    this.headsets = 0,
  });

  final VoidCallback onBack;
  final VoidCallback onAdvanced;

  /// Null where this device does not send (a headset, or a device that receives)
  final VoidCallback? onSend;

  /// The headsets watching now, from the relay
  final int headsets;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      children: [
        IconButton(
          key: const Key('dji_live_back'),
          tooltip: t.dji_live_back,
          color: Colors.white,
          iconSize: 28,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: onBack,
        ),
        if (onSend != null) ...[
          const SizedBox(height: 8),
          IconButton(
            key: const Key('dji_live_send'),
            tooltip: t.dji_link_relay,
            color: Colors.white,
            iconSize: 28,
            icon: const Icon(Icons.view_in_ar_rounded),
            onPressed: onSend,
          ),
        ],
        const SizedBox(height: 8),
        IconButton(
          key: const Key('dji_live_advanced'),
          tooltip: t.dji_live_advanced,
          color: Colors.white,
          iconSize: 28,
          icon: const Icon(Icons.more_horiz_rounded),
          onPressed: onAdvanced,
        ),
        const Spacer(),
        if (headsets > 0)
          InkWell(
            key: const Key('dji_live_headsets'),
            onTap: onSend,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                t.dji_live_headset_chip(count: headsets),
                textAlign: TextAlign.center,
                style: context.textTheme.labelSmall?.copyWith(color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}

/// The right column: the state of the picture, a capture being played, and the values of the gate, each a small label
/// over a large number. A value whose group stopped coming is not there at all.
class DjiLiveReadout extends StatelessWidget {
  const DjiLiveReadout({
    super.key,
    required this.picture,
    required this.values,
    this.staleSeconds,
    this.captureName,
    this.onStopCapture,
  });

  final DjiLivePicture picture;

  /// How long no new picture came, for the stale chip
  final String? staleSeconds;
  final List<DjiLiveValue> values;

  /// The capture being played in place of the cable, with its stop
  final String? captureName;
  final VoidCallback? onStopCapture;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final chip = switch (picture) {
      DjiLivePicture.live => t.dji_live_picture_live,
      DjiLivePicture.weak => t.dji_live_picture_weak,
      DjiLivePicture.stale => t.dji_live_picture_stale(seconds: staleSeconds ?? '-'),
      DjiLivePicture.none => null,
    };
    final small = context.textTheme.labelSmall?.copyWith(color: Colors.white70);
    final large = context.textTheme.titleLarge?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final captureName = this.captureName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chip != null)
          Row(
            key: Key('dji_live_picture_${picture.name}'),
            children: [
              Icon(
                Icons.circle,
                size: 10,
                color: picture == DjiLivePicture.live ? Colors.white : Colors.white54,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  chip,
                  style: context.textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        if (captureName != null) ...[
          const SizedBox(height: 8),
          Text(
            t.dji_live_capture_playing(name: captureName),
            key: const Key('dji_live_capture'),
            style: small,
          ),
          TextButton(
            key: const Key('dji_live_capture_stop'),
            style: TextButton.styleFrom(foregroundColor: Colors.white, padding: EdgeInsets.zero),
            onPressed: onStopCapture,
            child: Text(t.dji_link_play_stop),
          ),
        ],
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              label: value.line,
              excludeSemantics: true,
              child: Column(
                key: Key('dji_live_value_${value.field.name}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value.label, style: small),
                  Text(value.value, style: large),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
