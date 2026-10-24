// The obstacle alert of the DJI live video (p2/design-final-2026-10-24.md, 4.6): a red banner at the top of the
// picture, "Obstacle close: 1.8 m", with the side under it once our captures say which side, or "Not confirmed yet"
// while the alert is a test; a red glow along the picture's edge on the obstacle's side; a small top view of the drone
// in the right band while the alert listens, with a red arc on the obstacle's side. Never green, never a sign that the
// way is clear. The native side decides (ObstacleAlert) and beeps; this only draws what it decided. Information only:
// nothing here reaches the remote or the drone, and nothing here takes a touch.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

/// The red of the obstacle alert: one of the two colours of the live screen, with amber
const djiLiveRed = Color(0xFFE53935);

/// The width of the glow along the picture's edge
const djiObstacleGlowWidth = 16.0;

/// The size of the top view in the right band
const djiObstacleGlyphSize = 64.0;

/// The lines of the banner, null when it does not show: the distance or the plain words, then the side when it is
/// known, and "Not confirmed yet" while the gate keeps the alert as a test
(String, String?)? djiObstacleBannerLines(
  Translations t,
  DjiObstacleDecision decision, {
  Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
}) {
  if (decision.stopped) {
    return (t.dji_live_obstacle_stopped, null);
  }
  if (!decision.on) {
    return null;
  }
  final distance = decision.distanceM;
  final first = distance == null
      ? t.dji_live_obstacle_close_plain
      : t.dji_live_obstacle_close(distance: distance.toStringAsFixed(1));
  final side = switch (decision.side) {
    DjiObstacleSide.ahead => t.dji_live_obstacle_ahead,
    DjiObstacleSide.behind => t.dji_live_obstacle_behind,
    DjiObstacleSide.left => t.dji_live_obstacle_left,
    DjiObstacleSide.right => t.dji_live_obstacle_right,
    DjiObstacleSide.above => t.dji_live_obstacle_above,
    null => null,
  };
  final test = djiObstacleOffer(gates: gates) == DjiObstacleOffer.test;
  final unconfirmed = test ? t.dji_live_obstacle_unconfirmed : null;
  final second = [?side, ?unconfirmed].join('  ');
  return (first, second.isEmpty ? null : second);
}

/// The banner and the glow over the picture, from the alert of the last frame; nothing while the alert is off
class DjiObstacleLayer extends ConsumerWidget {
  const DjiObstacleLayer({super.key, this.glow = true, this.gates = djiLiveGates});

  /// The window of a headset draws no glow: its picture is small
  final bool glow;
  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decision = ref.watch(djiLiveFrameProvider.select((frame) => frame?.alert));
    if (decision == null || !(decision.on || decision.stopped)) {
      return const SizedBox.shrink();
    }
    final soundOff = !ref.watch(djiObstacleSettingsProvider.select((settings) => settings.soundOn));
    final side = decision.on && glow ? decision.side : null;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (side != null && side != DjiObstacleSide.above) DjiObstacleGlow(side: side),
          Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              widthFactor: 0.6,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DjiObstacleBanner(decision: decision, soundOff: soundOff, gates: gates),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The red banner: white bold words, the side or "not confirmed yet" under them, the muted icon when the sound is off
class DjiObstacleBanner extends StatelessWidget {
  const DjiObstacleBanner({
    super.key,
    required this.decision,
    this.soundOff = false,
    this.gates = djiLiveGates,
  });

  final DjiObstacleDecision decision;
  final bool soundOff;
  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = djiObstacleBannerLines(t, decision, gates: gates);
    if (lines == null) {
      return const SizedBox.shrink();
    }
    final (first, second) = lines;
    final bold = context.textTheme.titleMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final small = context.textTheme.labelMedium?.copyWith(color: Colors.white);
    return Semantics(
      liveRegion: true,
      label: [first, ?second, if (soundOff && decision.on) t.dji_live_obstacle_sound_off].join('. '),
      excludeSemantics: true,
      child: DecoratedBox(
        key: const Key('dji_live_obstacle_banner'),
        decoration: const BoxDecoration(color: djiLiveRed, borderRadius: BorderRadius.all(Radius.circular(8))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(first, maxLines: 1, overflow: TextOverflow.ellipsis, style: bold),
                    if (second != null)
                      Text(
                        second,
                        key: const Key('dji_live_obstacle_second'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small,
                      ),
                  ],
                ),
              ),
              if (soundOff && decision.on)
                const Icon(
                  Icons.volume_off_rounded,
                  key: Key('dji_live_obstacle_muted'),
                  color: Colors.white,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A red gradient along the picture's edge toward the obstacle, in a top view with the nose up: ahead on the top edge,
/// behind on the bottom one, left and right on theirs
class DjiObstacleGlow extends StatelessWidget {
  const DjiObstacleGlow({super.key, required this.side});

  final DjiObstacleSide side;

  @override
  Widget build(BuildContext context) {
    final (alignment, begin, end, horizontal) = switch (side) {
      DjiObstacleSide.ahead || DjiObstacleSide.above => (
        Alignment.topCenter,
        Alignment.topCenter,
        Alignment.bottomCenter,
        true,
      ),
      DjiObstacleSide.behind => (Alignment.bottomCenter, Alignment.bottomCenter, Alignment.topCenter, true),
      DjiObstacleSide.left => (Alignment.centerLeft, Alignment.centerLeft, Alignment.centerRight, false),
      DjiObstacleSide.right => (Alignment.centerRight, Alignment.centerRight, Alignment.centerLeft, false),
    };
    return Align(
      alignment: alignment,
      child: SizedBox(
        key: Key('dji_live_obstacle_glow_${side.name}'),
        width: horizontal ? double.infinity : djiObstacleGlowWidth,
        height: horizontal ? djiObstacleGlowWidth : double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: begin, end: end, colors: const [djiLiveRed, Color(0x00E53935)]),
          ),
        ),
      ),
    );
  }
}

/// The top view at the bottom of the right band: a thin white drone, nose up, while the alert listens; a red arc on the
/// obstacle's side while it is on (a red mark above the drone for above). Nothing when the alert is not offered or its
/// data is not fresh, and never a "clear" sign.
class DjiObstacleGlyph extends ConsumerWidget {
  const DjiObstacleGlyph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decision = ref.watch(djiLiveFrameProvider.select((frame) => frame?.alert));
    if (decision == null || !decision.listening) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final side = decision.on ? decision.side : null;
    return Semantics(
      label: decision.on && side == null ? t.dji_live_obstacle_close_plain : t.dji_live_obstacle_listening,
      excludeSemantics: true,
      child: SizedBox.square(
        key: Key('dji_live_obstacle_glyph${decision.on ? '_on' : ''}'),
        dimension: djiObstacleGlyphSize,
        child: CustomPaint(painter: _GlyphPainter(on: decision.on, side: side)),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.on, required this.side});

  final bool on;
  final DjiObstacleSide? side;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final unit = size.shortestSide / 8;
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    // Four arms and four rotors, the nose up
    for (final angle in const [-math.pi / 4, math.pi / 4, 3 * math.pi / 4, -3 * math.pi / 4]) {
      final tip = centre + Offset(math.sin(angle), -math.cos(angle)) * unit * 1.6;
      canvas.drawLine(centre, tip, line);
      canvas.drawCircle(tip, unit * 0.7, line);
    }
    canvas.drawLine(centre, centre + Offset(0, -unit * 1.2), line);
    final ring = Rect.fromCircle(center: centre, radius: unit * 3.4);
    final arc = Paint()
      ..color = on ? djiLiveRed : Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = on ? 4 : 1;
    final side = this.side;
    if (side == null || side == DjiObstacleSide.above) {
      // No side known: the whole ring, red while the alert is on
      canvas.drawCircle(centre, unit * 3.4, arc);
      if (side == DjiObstacleSide.above) {
        canvas.drawCircle(centre, unit * 0.6, Paint()..color = djiLiveRed);
      }
      return;
    }
    final start = switch (side) {
      DjiObstacleSide.ahead => -math.pi * 3 / 4,
      DjiObstacleSide.right => -math.pi / 4,
      DjiObstacleSide.behind => math.pi / 4,
      DjiObstacleSide.left => math.pi * 3 / 4,
      DjiObstacleSide.above => 0.0,
    };
    canvas.drawArc(ring, start, math.pi / 2, false, arc);
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => oldDelegate.on != on || oldDelegate.side != side;
}
