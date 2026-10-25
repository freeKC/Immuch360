// The obstacle ring of the DJI live video (p2/design-obstacle-ring-2026-10-25.md, 2 and 4): a translucent glow at the
// picture's edge on the obstacle's side, like a shooter's damage indicator, or evenly all around while the side is not
// shown. Nothing at all while nothing is close: no block, no label, no glyph. Front on the top edge, right on the right
// edge, back on the bottom, left on the left, each edge holding 90 degrees; an arc about 90 degrees wide, fading toward
// the centre, faint amber at "Glow from", strong red at "Strong glow from". The native side decides the arcs
// (ObstacleAlert, ObstacleRing) and ticks; this only draws them, the same on the phone, a TV and the Quest's window.
// Information only: nothing here reaches the remote or the drone, and nothing here takes a touch.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

/// The red of a strong glow: one of the two colours of the live screen, with amber
const djiLiveRed = Color(0xFFE53935);

/// The ring comes in this fast when the first arc appears, and leaves this slowly when the last goes
const djiObstacleFadeIn = Duration(milliseconds: 150);
const djiObstacleFadeOut = Duration(milliseconds: 400);

/// An arc weighs nothing this far from its centre: about 90 degrees wide
const djiObstacleWindowHalfDeg = 60.0;

/// Pieces per edge: the glow is soft, 24 are smooth
const djiObstacleRingPieces = 24;

/// The four edges of the picture, clockwise from the top: the front, the right, the back, the left
enum DjiObstacleEdge { top, right, bottom, left }

/// The side a screen reader names, by the quarter of the nearest arc: ahead is -45 to 45 degrees
enum DjiObstacleQuarter { ahead, right, behind, left }

DjiObstacleQuarter djiObstacleQuarter(double bearingDeg) {
  final bearing = djiObstacleNormalize(bearingDeg);
  if (bearing.abs() <= 45) {
    return DjiObstacleQuarter.ahead;
  }
  if (bearing > 45 && bearing <= 135) {
    return DjiObstacleQuarter.right;
  }
  if (bearing.abs() > 135) {
    return DjiObstacleQuarter.behind;
  }
  return DjiObstacleQuarter.left;
}

/// -180 (excluded) to 180
double djiObstacleNormalize(double degrees) {
  var value = degrees % 360;
  if (value > 180) {
    value -= 360;
  }
  if (value <= -180) {
    value += 360;
  }
  return value;
}

/// The ring shows: arcs to draw, the ring on or its data stopped
bool djiObstacleRingShows(DjiObstacleDecision? decision) =>
    decision != null && decision.arcs.isNotEmpty && (decision.on || decision.stopped);

/// The full depth of the glow: 12 % of the picture's shorter side on a phone or in a window (24 to 56 dp), 10 % of its
/// height on a TV (at least 48 dp, so that overscan never eats it); never more than half the picture
double djiObstacleRingDepth(Size size, {bool tv = false}) {
  final depth = tv ? math.max(48.0, size.height * 0.10) : (size.shortestSide * 0.12).clamp(24.0, 56.0);
  return math.min(depth, size.shortestSide / 2);
}

/// The weight of an arc [offsetDeg] from its centre: 1 there, 0.5 at 30 degrees, about 0.15 at 45, 0 from 60
double djiObstacleWindow(double offsetDeg) {
  final offset = offsetDeg.abs();
  return offset >= djiObstacleWindowHalfDeg ? 0 : 0.5 * (1 + math.cos(math.pi * offset / djiObstacleWindowHalfDeg));
}

/// How deep a glow of [strength] goes: 60 % of the full depth when faint, all of it when strong
double djiObstacleDepthOf(double strength, double fullDepth) => fullDepth * (0.6 + 0.4 * strength.clamp(0.0, 1.0));

/// The point of the border of a box of [size] that [bearingDeg] points at, the box taken as a square
Offset djiObstacleBorderPoint(double bearingDeg, Size size) {
  final radians = bearingDeg * math.pi / 180;
  final dx = math.sin(radians);
  final dy = -math.cos(radians);
  final scale = 1 / math.max(dx.abs(), dy.abs());
  return Offset(size.width / 2 * (1 + dx * scale), size.height / 2 * (1 + dy * scale));
}

/// The bearing of a point of the box, through the square: the inverse of [djiObstacleBorderPoint] on the border
double djiObstacleBearingOf(Offset point, Size size) {
  final u = (point.dx - size.width / 2) / (size.width / 2);
  final v = (point.dy - size.height / 2) / (size.height / 2);
  return math.atan2(u, -v) * 180 / math.pi;
}

/// One piece of the glow along an edge: a trapezoid from the picture's edge inward, mitred at 45 degrees at the
/// corners like a picture frame, with a gradient from the edge (at [alpha]) to [depth] inward (nothing)
class DjiObstacleRingStrip {
  const DjiObstacleRingStrip({
    required this.edge,
    required this.corners,
    required this.alpha,
    required this.colour,
    required this.depth,
    required this.edgePoint,
    required this.inward,
  });

  final DjiObstacleEdge edge;

  /// On the edge from, on the edge to, inside to, inside from
  final List<Offset> corners;
  final double alpha;
  final Color colour;
  final double depth;

  /// The middle of the piece on the edge, and the direction toward the centre
  final Offset edgePoint;
  final Offset inward;
}

/// The glow of [arcs] over a picture of [size], cut in [pieces] per edge: at the middle of each piece the arc that
/// weighs most gives the alpha (its opacity times its window), the colour and the depth; where arcs meet the larger
/// wins, they never add up. An arc with no bearing is the even glow, the same on every piece. Pieces with nothing are
/// left out. The same rules as RingGeometry.segments on the native side, for the Quest's halo.
List<DjiObstacleRingStrip> djiObstacleRingStrips(
  Size size,
  List<DjiObstacleArc> arcs,
  double fullDepth, {
  int pieces = djiObstacleRingPieces,
}) {
  if (arcs.isEmpty || size.isEmpty || pieces <= 0) {
    return const [];
  }
  final w = size.width;
  final h = size.height;
  final d = math.min(fullDepth, size.shortestSide / 2);
  final strips = <DjiObstacleRingStrip>[];
  for (final edge in DjiObstacleEdge.values) {
    // The ends of the edge clockwise, the matching inner corners, and the way in
    final (Offset start, Offset end, Offset innerStart, Offset innerEnd, Offset inward) = switch (edge) {
      DjiObstacleEdge.top => (Offset.zero, Offset(w, 0), Offset(d, d), Offset(w - d, d), const Offset(0, 1)),
      DjiObstacleEdge.right => (
        Offset(w, 0),
        Offset(w, h),
        Offset(w - d, d),
        Offset(w - d, h - d),
        const Offset(-1, 0),
      ),
      DjiObstacleEdge.bottom => (
        Offset(w, h),
        Offset(0, h),
        Offset(w - d, h - d),
        Offset(d, h - d),
        const Offset(0, -1),
      ),
      DjiObstacleEdge.left => (Offset(0, h), Offset.zero, Offset(d, h - d), Offset(d, d), const Offset(1, 0)),
    };
    for (var index = 0; index < pieces; index++) {
      final from = index / pieces;
      final to = (index + 1) / pieces;
      final middle = Offset.lerp(start, end, (from + to) / 2)!;
      final bearing = djiObstacleBearingOf(middle, size);
      DjiObstacleArc? best;
      var bestAlpha = 0.0;
      for (final arc in arcs) {
        final centre = arc.centreDeg;
        final weight = centre == null ? 1.0 : djiObstacleWindow(djiObstacleNormalize(bearing - centre));
        final alpha = arc.opacity * weight;
        if (alpha > bestAlpha) {
          bestAlpha = alpha;
          best = arc;
        }
      }
      if (best == null) {
        continue;
      }
      strips.add(
        DjiObstacleRingStrip(
          edge: edge,
          corners: [
            Offset.lerp(start, end, from)!,
            Offset.lerp(start, end, to)!,
            Offset.lerp(innerStart, innerEnd, to)!,
            Offset.lerp(innerStart, innerEnd, from)!,
          ],
          alpha: bestAlpha,
          colour: Color(best.argb),
          depth: djiObstacleDepthOf(best.strength, d),
          edgePoint: middle,
          inward: inward,
        ),
      );
    }
  }
  return strips;
}

/// Where the distance goes: by the nearest arc, moved in from the edge by 0.8 of its depth; at the top centre with the
/// even glow
Offset djiObstacleNumberPoint(DjiObstacleArc nearest, Size size, double fullDepth) {
  final depth = djiObstacleDepthOf(nearest.strength, math.min(fullDepth, size.shortestSide / 2)) * 0.8;
  final centre = nearest.centreDeg;
  if (centre == null) {
    return Offset(size.width / 2, depth);
  }
  final point = djiObstacleBorderPoint(centre, size);
  final distances = [point.dy, size.width - point.dx, size.height - point.dy, point.dx];
  final nearestEdge = distances.indexOf(distances.reduce(math.min));
  return switch (nearestEdge) {
    0 => point + Offset(0, depth),
    1 => point - Offset(depth, 0),
    2 => point - Offset(0, depth),
    _ => point + Offset(depth, 0),
  };
}

/// What a screen reader hears while the ring shows: the distance, then the side of the nearest arc when the side is
/// shown; that the data stopped once it did
String djiObstacleRingLabel(Translations t, DjiObstacleDecision decision) {
  if (decision.stopped) {
    return t.dji_live_obstacle_stopped;
  }
  final nearest = decision.nearestM ?? (decision.arcs.isEmpty ? null : decision.arcs.first.distanceM);
  final within = nearest == null ? '' : t.dji_live_obstacle_within(distance: nearest.toStringAsFixed(1));
  final centre = decision.even || decision.arcs.isEmpty ? null : decision.arcs.first.centreDeg;
  if (centre == null) {
    return within;
  }
  final side = switch (djiObstacleQuarter(centre)) {
    DjiObstacleQuarter.ahead => t.dji_live_obstacle_ahead,
    DjiObstacleQuarter.right => t.dji_live_obstacle_right,
    DjiObstacleQuarter.behind => t.dji_live_obstacle_behind,
    DjiObstacleQuarter.left => t.dji_live_obstacle_left,
  };
  return within.isEmpty ? side : '$within. $side';
}

/// The ring over the picture's box, from the decision of the last frame: nothing in the tree while nothing is close.
/// [tv] takes the TV's depth and number size; [numbersHidden] is OK on a TV, which hides the numbers, never the ring.
class DjiObstacleRing extends ConsumerStatefulWidget {
  const DjiObstacleRing({super.key, this.tv = false, this.numbersHidden = false});

  final bool tv;
  final bool numbersHidden;

  @override
  ConsumerState<DjiObstacleRing> createState() => _DjiObstacleRingState();
}

class _DjiObstacleRingState extends ConsumerState<DjiObstacleRing> with SingleTickerProviderStateMixin {
  late final AnimationController _fade;

  /// The last decision with arcs: drawn while the ring shows, and while it fades out
  DjiObstacleDecision? _shown;
  bool _showing = false;

  /// The screen reader's words change only with the side, the zone (faint or strong) or a stop, not at every frame
  (DjiObstacleQuarter?, bool, bool)? _labelKey;
  String? _label;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: djiObstacleFadeIn, reverseDuration: djiObstacleFadeOut)
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && !_showing && mounted) {
          setState(() => _shown = null);
        }
      });
    _follow(ref.read(djiLiveFrameProvider)?.alert);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _follow(DjiObstacleDecision? decision) {
    final showing = djiObstacleRingShows(decision);
    if (showing) {
      _shown = decision;
    }
    if (showing == _showing) {
      return;
    }
    _showing = showing;
    if (showing) {
      unawaited(_fade.forward());
    } else {
      unawaited(_fade.reverse());
    }
  }

  String _labelOf(DjiObstacleDecision decision) {
    final first = decision.arcs.first;
    final centre = first.centreDeg;
    final key = (
      decision.even || centre == null ? null : djiObstacleQuarter(centre),
      first.strength >= 1,
      decision.stopped,
    );
    final label = _label;
    if (key == _labelKey && label != null) {
      return label;
    }
    _labelKey = key;
    return _label = djiObstacleRingLabel(context.t, decision);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(djiLiveFrameProvider.select((frame) => frame?.alert), (_, next) {
      _follow(next);
      setState(() {});
    });
    final numbersOn = ref.watch(djiObstacleSettingsProvider.select((settings) => settings.numbersOn));
    final shown = _shown;
    if (shown == null) {
      _labelKey = null;
      _label = null;
      return const SizedBox.shrink();
    }
    final label = _showing ? _labelOf(shown) : null;
    final showNumber = numbersOn && !widget.numbersHidden && shown.on && !shown.stopped;
    return IgnorePointer(
      child: Semantics(
        key: const Key('dji_live_obstacle_ring'),
        liveRegion: label != null,
        label: label,
        excludeSemantics: true,
        child: FadeTransition(
          opacity: _fade,
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final depth = djiObstacleRingDepth(size, tv: widget.tv);
                final strips = djiObstacleRingStrips(size, shown.arcs, depth);
                final nearest = shown.arcs.first;
                final number = showNumber ? djiObstacleNumberPoint(nearest, size, depth) : null;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: _DjiObstacleRingPainter(strips)),
                    if (number != null && size.width > 0 && size.height > 0)
                      Align(
                        alignment: Alignment(number.dx / size.width * 2 - 1, number.dy / size.height * 2 - 1),
                        child: Text(
                          context.t.dji_live_obstacle_distance(
                            distance: (shown.nearestM ?? nearest.distanceM).toStringAsFixed(1),
                          ),
                          key: const Key('dji_live_obstacle_distance'),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: widget.tv ? 22 : 14,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            shadows: const [Shadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 1))],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DjiObstacleRingPainter extends CustomPainter {
  const _DjiObstacleRingPainter(this.strips);

  final List<DjiObstacleRingStrip> strips;

  /// The profile (1-x)^2 toward the centre, as gradient stops
  static const _stops = [0.0, 0.25, 0.5, 0.75, 1.0];
  static const _fall = [1.0, 0.5625, 0.25, 0.0625, 0.0];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = true;
    for (final strip in strips) {
      final path = Path()..addPolygon(strip.corners, true);
      paint.shader = ui.Gradient.linear(
        strip.edgePoint,
        strip.edgePoint + strip.inward * strip.depth,
        [for (final fall in _fall) strip.colour.withValues(alpha: strip.alpha * fall)],
        _stops,
      );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_DjiObstacleRingPainter oldDelegate) => !identical(oldDelegate.strips, strips);
}
