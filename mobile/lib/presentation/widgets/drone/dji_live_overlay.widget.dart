// What the DJI live video draws beside the picture (p2/design-final-2026-10-24.md, 3.3): on the left Back, Send to a
// headset and Advanced, the headsets watching under them, and the flight numbers at the bottom of the band; on the
// right the state of the picture as measured here and the state of the drone. Each value the gate lets through has a
// fixed place, a fixed height and tabular figures: a changing digit never moves its neighbours, a value that stops
// coming leaves its place empty, and when a band is too short the values leave it in their order of priority, never
// scrolling or shrinking. Each value listens to its own field of the ten a second frame, so nothing else is redrawn.
// Nothing in the picture itself takes a touch, and nothing here looks like a flight control: no sticks, no take off,
// landing, return or record button, no camera control.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_stage.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

/// The width of a column drawn over the picture on a screen with no band beside it
const djiLiveEdgeWidth = 72.0;

/// The amber of the drone's battery under [djiLiveBatteryLow]: one of the two colours of the live screen, with red
const djiLiveAmber = Color(0xFFFFB300);

/// The heights of a cell: a small label on up to two lines over a large number, a line of its own, and a flight number
/// of the left band
const djiLiveCellHeight = 64.0;
const djiLiveLineHeight = 26.0;
const djiLiveFlightCellHeight = 46.0;

/// The gradient under a column drawn over the picture, from 60 % black at the edge to transparent
BoxDecoration djiLiveEdgeShade({required bool left}) => BoxDecoration(
  gradient: LinearGradient(
    begin: left ? Alignment.centerLeft : Alignment.centerRight,
    end: left ? Alignment.centerRight : Alignment.centerLeft,
    colors: const [Color(0x99000000), Color(0x00000000)],
  ),
);

/// The cells of the right band that take one line: a short label beside the number, or the number alone
bool djiLiveOneLine(DjiLiveField field) => switch (field) {
  DjiLiveField.remoteBattery || DjiLiveField.satellites || DjiLiveField.heading || DjiLiveField.landing => true,
  _ => false,
};

/// The height a cell of [field] takes in [band]
double djiLiveCellExtent(DjiLiveField field, DjiLiveBand band) {
  if (band == DjiLiveBand.left) {
    return djiLiveFlightCellHeight;
  }
  return djiLiveOneLine(field) ? djiLiveLineHeight : djiLiveCellHeight;
}

/// The fields of [fields] that fit in [height], in their order: when they do not all fit, the one with the highest drop
/// number leaves first, and a field whose drop is 0 never leaves (p2/design-final-2026-10-24.md, 3.3 item 4)
List<DjiLiveField> djiLiveFieldsThatFit(
  List<DjiLiveField> fields,
  double height,
  DjiLiveBand band, {
  Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
}) {
  final kept = [...fields];
  double total() => kept.fold(0.0, (sum, field) => sum + djiLiveCellExtent(field, band));
  while (total() > height) {
    final leaving = kept
        .where((field) => (gates[field]?.drop ?? 0) > 0)
        .fold<DjiLiveField?>(
          null,
          (worst, field) => worst == null || (gates[field]?.drop ?? 0) > (gates[worst]?.drop ?? 0) ? field : worst,
        );
    if (leaving == null) {
      break;
    }
    kept.remove(leaving);
  }
  return kept;
}

/// The left column: three buttons, white on black, 48 dp targets, the headsets watching under them, and the flight
/// numbers at the bottom
class DjiLiveButtons extends StatelessWidget {
  const DjiLiveButtons({
    super.key,
    required this.onBack,
    required this.onAdvanced,
    this.onSend,
    this.headsets = 0,
    this.gates = djiLiveGates,
  });

  final VoidCallback onBack;
  final VoidCallback onAdvanced;

  /// Null where this device does not send (a headset, or a device that receives)
  final VoidCallback? onSend;

  /// The headsets watching now, from the relay
  final int headsets;
  final Map<DjiLiveField, DjiLiveGate> gates;

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
        // The flight numbers at the bottom, where a DJI Fly pilot looks for them
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DjiLiveBandCells(band: DjiLiveBand.left, gates: gates, alignment: Alignment.bottomLeft),
          ),
        ),
      ],
    );
  }
}

/// The right column: the state of the picture, a capture being played, then the state of the drone. A value whose
/// group stopped coming leaves its place empty. The obstacle ring is drawn over the picture, never here.
class DjiLiveReadout extends StatelessWidget {
  const DjiLiveReadout({
    super.key,
    required this.picture,
    this.staleSeconds,
    this.captureName,
    this.onStopCapture,
    this.gates = djiLiveGates,
  });

  final DjiLivePicture picture;

  /// How long no new picture came, for the stale chip
  final String? staleSeconds;

  /// The capture being played in place of the cable, with its stop
  final String? captureName;
  final VoidCallback? onStopCapture;
  final Map<DjiLiveField, DjiLiveGate> gates;

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
    final captureName = this.captureName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chip != null)
          Row(
            key: Key('dji_live_picture_${picture.name}'),
            children: [
              Icon(Icons.circle, size: 10, color: picture == DjiLivePicture.live ? Colors.white : Colors.white54),
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
          Text(t.dji_live_capture_playing(name: captureName), key: const Key('dji_live_capture'), style: small),
          TextButton(
            key: const Key('dji_live_capture_stop'),
            style: TextButton.styleFrom(foregroundColor: Colors.white, padding: EdgeInsets.zero),
            onPressed: onStopCapture,
            child: Text(t.dji_link_play_stop),
          ),
        ],
        const SizedBox(height: 4),
        Expanded(
          child: DjiLiveBandCells(band: DjiLiveBand.right, gates: gates, alignment: Alignment.topLeft),
        ),
      ],
    );
  }
}

/// The cells of one band, in their fixed places, the ones that do not fit left out in their order of priority
class DjiLiveBandCells extends StatelessWidget {
  const DjiLiveBandCells({
    super.key,
    required this.band,
    this.gates = djiLiveGates,
    this.alignment = Alignment.topLeft,
  });

  final DjiLiveBand band;
  final Map<DjiLiveField, DjiLiveGate> gates;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final fields = djiLiveBandFields(band, gates: gates);
    if (fields.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final shown = djiLiveFieldsThatFit(fields, constraints.maxHeight, band, gates: gates);
        return Align(
          alignment: alignment,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final field in shown) DjiLiveCell(field: field, band: band, gates: gates)],
          ),
        );
      },
    );
  }
}

/// One value over the picture: it listens to its own field only, keeps its height whether it shows or not, and draws
/// its digits with tabular figures, without any animation
class DjiLiveCell extends ConsumerWidget {
  const DjiLiveCell({super.key, required this.field, required this.band, this.gates = djiLiveGates});

  final DjiLiveField field;
  final DjiLiveBand band;
  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final (value, low) = ref.watch(
      djiLiveFrameProvider.select(
        (frame) => (
          djiLiveFieldValue(t, frame, field),
          field == DjiLiveField.droneBattery && djiLiveBatteryIsLow(frame),
        ),
      ),
    );
    final extent = djiLiveCellExtent(field, band);
    if (value == null) {
      // The place stays: nothing else moves when a value stops coming
      return SizedBox(key: Key('dji_live_cell_${field.name}'), height: extent);
    }
    final label = djiLiveFieldLabel(t, field, place: DjiLivePlace.overlay, gates: gates);
    final small = context.textTheme.labelSmall?.copyWith(color: Colors.white70);
    const figures = [FontFeature.tabularFigures()];
    final large = band == DjiLiveBand.left
        ? context.textTheme.titleLarge?.copyWith(fontSize: 20)
        : context.textTheme.titleLarge;
    final number = large?.copyWith(
      color: low ? djiLiveAmber : Colors.white,
      fontWeight: FontWeight.w600,
      fontFeatures: figures,
    );
    final line = context.textTheme.titleMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      fontFeatures: figures,
    );
    final semantics = [label, value, if (low) t.dji_live_battery_low].where((part) => part.isNotEmpty).join(' ');
    final Widget content;
    if (band == DjiLiveBand.right && djiLiveOneLine(field)) {
      content = Text(
        label.isEmpty ? value : '$label $value',
        maxLines: 1,
        overflow: TextOverflow.clip,
        softWrap: false,
        style: line,
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (label.isNotEmpty)
            Text(label, maxLines: band == DjiLiveBand.left ? 1 : 2, overflow: TextOverflow.clip, style: small),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (low) ...[
                const Icon(
                  Icons.battery_alert_rounded,
                  key: Key('dji_live_battery_low'),
                  size: 18,
                  color: djiLiveAmber,
                ),
                const SizedBox(width: 2),
              ],
              Flexible(
                child: Text(value, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: number),
              ),
            ],
          ),
        ],
      );
    }
    return RepaintBoundary(
      child: SizedBox(
        key: Key('dji_live_cell_${field.name}'),
        height: extent,
        child: Semantics(
          label: semantics,
          excludeSemantics: true,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: KeyedSubtree(key: Key('dji_live_value_${field.name}'), child: content),
          ),
        ),
      ),
    );
  }
}
