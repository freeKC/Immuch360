// The obstacle indicator over the picture (p2/design-obstacle-ring-2026-10-25.md, 2.2 to 2.7 and 4), with synthetic
// decisions: no capture holds an obstacle at a known place and distance yet. By default a circle around the centre
// (FreeKC, 25 October, "comme dans Fortnite"), the frame at the edges as a setting: where the glow falls, how strong and
// how thick, that nothing at all is in the tree while nothing is close, its fades, its words for a screen reader and the
// distance by the glow. Nothing ran on a phone, a TV or the Quest: these are widget tests.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_obstacle.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/drone/dji_link_fakes.dart';

const _box = Size(1600, 900);

class _Frame extends DjiLiveFrameNotifier {
  _Frame(this.first);

  final DjiLiveFrame? first;

  @override
  DjiLiveFrame? build() => first;
}

/// The strongest piece of the glow
DjiObstacleRingStrip _strongest(List<DjiObstacleRingStrip> strips) => strips.reduce((a, b) => b.alpha > a.alpha ? b : a);

/// Where a piece sits along the top edge, 0 at the left corner and 1 at the right one
double _along(DjiObstacleRingStrip strip) => (strip.corners[0].dx + strip.corners[1].dx) / 2 / _box.width;

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The English texts, from a widget under the app's localisation
  Future<Translations> english(WidgetTester tester) async {
    late Translations t;
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) {
          t = context.t;
          return const SizedBox();
        },
      ),
    );
    return t;
  }

  group('the glow along the border', () {
    test('an arc ahead is strongest at the top centre and leaves the bottom edge empty', () {
      final arc = fakeArc(1.0, centreDeg: 0);
      final strips = djiObstacleRingStrips(_box, [arc], 50);
      final strongest = _strongest(strips);
      expect(strongest.edge, DjiObstacleEdge.top);
      expect(_along(strongest), closeTo(0.5, 1 / djiObstacleRingPieces));
      expect(strips.where((strip) => strip.edge == DjiObstacleEdge.bottom), isEmpty);
      expect(strips.every((strip) => strip.alpha <= arc.opacity + 1e-9), isTrue);
      // Red when strong
      expect(strongest.colour, const Color(0xFFE53935));
    });

    test('an arc at 30 degrees is on the top edge, tan(30) of the half width right of the centre', () {
      final strongest = _strongest(djiObstacleRingStrips(_box, [fakeArc(1.5, centreDeg: 30)], 50, pieces: 96));
      expect(strongest.edge, DjiObstacleEdge.top);
      expect(_along(strongest), closeTo(0.5 + math.tan(math.pi / 6) / 2, 1 / 96));
    });

    test('two arcs give two maxima, and where they meet the larger wins without adding up', () {
      final ahead = fakeArc(1.0, centreDeg: 0);
      final right = fakeArc(2.5, centreDeg: 90);
      final both = djiObstacleRingStrips(_box, [ahead, right], 50);
      final alone = {
        for (final strip in djiObstacleRingStrips(_box, [ahead], 50)) (strip.edge, strip.corners.first): strip.alpha,
      };
      for (final strip in both) {
        expect(strip.alpha, lessThanOrEqualTo(ahead.opacity + 1e-9));
        expect(strip.alpha, greaterThanOrEqualTo((alone[(strip.edge, strip.corners.first)] ?? 0) - 1e-9));
      }
      final rightCentre = both.firstWhere(
        (strip) => strip.edge == DjiObstacleEdge.right && (strip.edgePoint.dy - _box.height / 2).abs() < 20,
      );
      expect(rightCentre.colour, Color(right.argb));
      expect(rightCentre.alpha, closeTo(right.opacity, 0.01));
      expect(_strongest(both).edge, DjiObstacleEdge.top);
    });

    test('the even glow is the same on all four edges, corners included', () {
      final even = fakeArc(2.0);
      final strips = djiObstacleRingStrips(_box, [even], 50);
      expect(strips, hasLength(4 * djiObstacleRingPieces));
      for (final edge in DjiObstacleEdge.values) {
        expect(strips.where((strip) => strip.edge == edge), hasLength(djiObstacleRingPieces));
      }
      expect(strips.every((strip) => strip.alpha == even.opacity), isTrue);
      expect(djiObstacleRingStrips(_box, const [], 50), isEmpty);
    });

    test('the pieces are mitred at the corners, and the depth grows with the strength', () {
      final strips = djiObstacleRingStrips(_box, [fakeArc(2.0)], 50);
      final first = strips.firstWhere((strip) => strip.edge == DjiObstacleEdge.top);
      expect(first.corners.first, Offset.zero);
      expect(first.corners.last.dx, closeTo(50, 1e-9));
      expect(first.corners.last.dy, closeTo(50, 1e-9));
      expect(djiObstacleDepthOf(0, 50), closeTo(30, 1e-9));
      expect(djiObstacleDepthOf(1, 50), closeTo(50, 1e-9));
      expect(djiObstacleRingStrips(_box, [fakeArc(3.0)], 50).first.depth, closeTo(30, 1e-9));
      expect(djiObstacleRingStrips(_box, [fakeArc(0.8)], 50).first.depth, closeTo(50, 1e-9));
    });

    test('the depth: 12 % of the shorter side on a phone, 10 % of the height and at least 48 dp on a TV', () {
      expect(djiObstacleRingDepth(const Size(731, 411)), closeTo(49.32, 1e-9));
      expect(djiObstacleRingDepth(const Size(160, 90)), 24);
      expect(djiObstacleRingDepth(const Size(2000, 1125)), 56);
      expect(djiObstacleRingDepth(const Size(1920, 1080), tv: true), 108);
      expect(djiObstacleRingDepth(const Size(700, 394), tv: true), 48);
    });

    test('the border points and their bearings, through the square', () {
      for (final bearing in [0.0, 30.0, 45.0, 90.0, 135.0, 180.0, -90.0, -150.0]) {
        final point = djiObstacleBorderPoint(bearing, _box);
        final back = djiObstacleNormalize(djiObstacleBearingOf(point, _box));
        expect(back == -180 ? 180.0 : back, closeTo(bearing, 1e-9), reason: '$bearing');
      }
      expect(djiObstacleBorderPoint(45, _box).dx, closeTo(_box.width, 1e-9));
      expect(djiObstacleWindow(0), 1);
      expect(djiObstacleWindow(30), closeTo(0.5, 1e-9));
      expect(djiObstacleWindow(45), closeTo(0.146, 1e-3));
      expect(djiObstacleWindow(60), 0);
    });

    test('the distance goes by the nearest arc, and in the bottom left corner with the even glow', () {
      final depth = djiObstacleDepthOf(fakeArc(1.4).strength, 50) * 0.8;
      final even = djiObstacleNumberPoint(fakeArc(1.4), _box, 50);
      expect(even.dx, closeTo(depth, 1e-9));
      expect(even.dy, closeTo(_box.height - depth, 1e-9));
      final left = djiObstacleNumberPoint(fakeArc(1.4, centreDeg: -90), _box, 50);
      expect(left.dx, closeTo(depth, 1e-9));
      expect(left.dy, closeTo(_box.height / 2, 1e-9));
    });

    testWidgets('a screen reader hears the distance, the side by its quarter, and that the data stopped', (
      tester,
    ) async {
      final t = await english(tester);
      expect(djiObstacleRingLabel(t, fakeDecision(on: true, arcs: [fakeArc(1.44)])), 'Obstacle within 1.4 m');
      expect(
        djiObstacleRingLabel(t, fakeDecision(on: true, arcs: [fakeArc(1.44, centreDeg: 100)])),
        'Obstacle within 1.4 m. On the right',
      );
      expect(djiObstacleQuarter(-45), DjiObstacleQuarter.ahead);
      expect(djiObstacleQuarter(46), DjiObstacleQuarter.right);
      expect(djiObstacleQuarter(-170), DjiObstacleQuarter.behind);
      expect(djiObstacleQuarter(-90), DjiObstacleQuarter.left);
      expect(
        djiObstacleRingLabel(t, fakeDecision(stopped: true, arcs: [fakeArc(1.44)])),
        'Obstacle data stopped: look at the drone.',
      );
    });
  });

  group('the circle around the centre', () {
    const box = Size(640, 360);

    DjiObstacleCirclePiece strongest(List<DjiObstacleCirclePiece> pieces) =>
        pieces.reduce((a, b) => b.alpha > a.alpha ? b : a);
    double middle(DjiObstacleCirclePiece piece) => (piece.fromDeg + piece.toDeg) / 2;

    test('a quarter of the picture height, a thin ring, the front at the top of the circle', () {
      expect(djiObstacleCircleRadius(box), 90);
      expect(djiObstacleCircleThickness(box), closeTo(16.2, 1e-9));
      expect(djiObstacleCircleRadius(const Size(1920, 1080)), 270);
      const centre = Offset(320, 180);
      expect(djiObstacleCirclePoint(0, centre, 90).dx, closeTo(320, 1e-9));
      expect(djiObstacleCirclePoint(0, centre, 90).dy, closeTo(90, 1e-9));
      expect(djiObstacleCirclePoint(90, centre, 90).dx, closeTo(410, 1e-9));
      expect(djiObstacleCirclePoint(90, centre, 90).dy, closeTo(180, 1e-9));
      expect(djiObstacleCirclePoint(180, centre, 90).dy, closeTo(270, 1e-9));
      expect(djiObstacleCirclePoint(-90, centre, 90).dx, closeTo(230, 1e-9));
    });

    test('an arc ahead is strongest at the top of the circle, about 70 degrees wide, nothing behind', () {
      final arc = fakeArc(1.0, centreDeg: 0);
      final pieces = djiObstacleCirclePieces(box, [arc]);
      expect(middle(strongest(pieces)).abs(), lessThanOrEqualTo(360 / djiObstacleCirclePieceCount));
      expect(pieces.every((piece) => djiObstacleNormalize(middle(piece)).abs() < 45), isTrue);
      expect(pieces.every((piece) => piece.alpha <= arc.opacity + 1e-9), isTrue);
      expect(strongest(pieces).colour, const Color(0xFFE53935));
      // What shows above a tenth of its strength spans 60 to 90 degrees
      final span = pieces
          .where((piece) => piece.alpha >= arc.opacity * 0.1)
          .fold(0.0, (sum, piece) => sum + piece.toDeg - piece.fromDeg);
      expect(span, inInclusiveRange(60, 90));
      expect(djiObstacleCircleWindow(0), 1);
      expect(djiObstacleCircleWindow(22.5), closeTo(0.5, 1e-9));
      expect(djiObstacleCircleWindow(45), 0);
      // On the right: at three o'clock
      final right = strongest(djiObstacleCirclePieces(box, [fakeArc(1.0, centreDeg: 90)]));
      expect(middle(right), closeTo(90, 360 / djiObstacleCirclePieceCount));
    });

    test('where two arcs meet the larger wins, without adding up', () {
      final ahead = fakeArc(0.8, centreDeg: 0);
      final side = fakeArc(2.8, centreDeg: 30);
      for (final piece in djiObstacleCirclePieces(box, [ahead, side])) {
        final a = ahead.opacity * djiObstacleCircleWindow(djiObstacleNormalize(middle(piece)));
        final b = side.opacity * djiObstacleCircleWindow(djiObstacleNormalize(middle(piece) - 30));
        expect(piece.alpha, closeTo(math.max(a, b), 1e-9));
        expect(piece.colour, Color(a >= b ? ahead.argb : side.argb));
      }
    });

    test('the even glow, the side not shown, is the whole circle, faint', () {
      final even = fakeArc(2.0);
      final pieces = djiObstacleCirclePieces(box, [even]);
      expect(pieces, hasLength(djiObstacleCirclePieceCount));
      expect(pieces.every((piece) => piece.alpha == even.opacity), isTrue);
      expect(even.opacity, lessThanOrEqualTo(0.35));
      expect(djiObstacleCirclePieces(box, const []), isEmpty);
    });

    test('a strong arc is the full thickness, a faint one 60 % of it', () {
      final full = djiObstacleCircleThickness(box);
      expect(djiObstacleCirclePieces(box, [fakeArc(0.8)]).first.thickness, closeTo(full, 1e-9));
      expect(djiObstacleCirclePieces(box, [fakeArc(3.0)]).first.thickness, closeTo(full * 0.6, 1e-9));
    });

    test('the distance goes outside the circle by the nearest arc, low on the left with the even glow', () {
      final ahead = djiObstacleCircleNumberPoint(fakeArc(1.4, centreDeg: 0), box, 14);
      expect(ahead.dx, closeTo(320, 1e-9));
      expect(ahead.dy, closeTo(180 - (90 + 8.1 + 14), 1e-9));
      final even = djiObstacleCircleNumberPoint(fakeArc(1.4), box, 14);
      expect(even.dx, lessThan(320));
      expect(even.dy, greaterThan(180));
    });
  });

  group('the ring over a picture', () {
    late Map<StoreKey<bool>, bool> memory;

    setUp(() => memory = {});

    Future<ProviderContainer> pumpRing(
      WidgetTester tester,
      DjiLiveFrame? frame, {
      bool tv = false,
      bool numbersHidden = false,
    }) async {
      await tester.pumpTestWidget(
        context,
        Center(
          child: SizedBox(
            key: const Key('picture'),
            width: 640,
            height: 360,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  key: const Key('under'),
                  onTap: () => memory[StoreKey.djiLivePictureSeen] = true,
                  child: const ColoredBox(color: Colors.black),
                ),
                DjiObstacleRing(tv: tv, numbersHidden: numbersHidden),
              ],
            ),
          ),
        ),
        overrides: [
          djiLiveFrameProvider.overrideWith(() => _Frame(frame)),
          djiLiveMemoryProvider.overrideWithValue(
            DjiLiveMemory(read: (key) => memory[key] ?? false, write: (key, value) async => memory[key] = value),
          ),
        ],
      );
      return ProviderScope.containerOf(tester.element(find.byKey(const Key('picture'))));
    }

    testWidgets('no arc: nothing in the tree, and no words for a screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpRing(tester, fakeFrame(alert: fakeDecision(listening: true)));
      expect(find.byKey(const Key('dji_live_obstacle_ring')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Obstacle')), findsNothing);
      // Nor any of the old block
      for (final key in ['dji_live_obstacle_banner', 'dji_live_obstacle_glyph', 'dji_watch_tv_obstacle']) {
        expect(find.byKey(Key(key)), findsNothing, reason: key);
      }
      semantics.dispose();
    });

    testWidgets('an arc: the ring comes in over 150 ms, takes no touch, and leaves 400 ms after the last arc', (
      tester,
    ) async {
      final container = await pumpRing(tester, null);
      container.read(djiLiveFrameProvider.notifier).offer(fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.4)])));
      await tester.pump();
      final ring = find.byKey(const Key('dji_live_obstacle_ring'));
      expect(ring, findsOneWidget);
      double opacity() =>
          tester.widget<FadeTransition>(find.descendant(of: ring, matching: find.byType(FadeTransition))).opacity.value;
      expect(opacity(), 0);
      await tester.pump(const Duration(milliseconds: 75));
      expect(opacity(), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 75));
      expect(opacity(), 1);
      // A tap goes through to the picture
      await tester.tap(find.byKey(const Key('picture')));
      expect(memory[StoreKey.djiLivePictureSeen], isTrue);

      container.read(djiLiveFrameProvider.notifier).offer(fakeFrame(atMs: 2000, alert: fakeDecision(listening: true)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), 0);
      // An animation ends just past its duration: then the ring leaves the tree
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(ring, findsNothing);
    });

    testWidgets('stopped: the last arcs, white, then nothing once the native side ends it', (tester) async {
      final container = await pumpRing(tester, fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.0)])));
      await tester.pumpAndSettle();
      container
          .read(djiLiveFrameProvider.notifier)
          .offer(fakeFrame(atMs: 2000, alert: fakeDecision(stopped: true, arcs: [fakeArc(1.0)])));
      await tester.pump();
      final ring = find.byKey(const Key('dji_live_obstacle_ring'));
      expect(ring, findsOneWidget);
      final painter = tester
          .widget<CustomPaint>(find.descendant(of: ring, matching: find.byType(CustomPaint)).first)
          .painter;
      expect(painter, isNotNull);
      // No number and no words over the picture
      expect(find.byKey(const Key('dji_live_obstacle_distance')), findsNothing);
      container.read(djiLiveFrameProvider.notifier).offer(fakeFrame(atMs: 7000, alert: fakeDecision()));
      await tester.pumpAndSettle();
      expect(ring, findsNothing);
    });

    testWidgets('a circle around the centre by default; the frame at the edges as this device\'s setting', (
      tester,
    ) async {
      final frame = fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44, centreDeg: 0)]));
      await pumpRing(tester, frame);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_live_obstacle_circle')), findsOneWidget);
      expect(find.byKey(const Key('dji_live_obstacle_frame')), findsNothing);
      // Over the whole picture, the circle drawn around its centre
      expect(
        tester.getRect(find.byKey(const Key('dji_live_obstacle_circle'))),
        tester.getRect(find.byKey(const Key('picture'))),
      );

      memory[StoreKey.djiObstacleShapeFrame] = true;
      await pumpRing(tester, frame);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_live_obstacle_frame')), findsOneWidget);
      expect(find.byKey(const Key('dji_live_obstacle_circle')), findsNothing);
    });

    testWidgets('the distance by the glow: on by default, outside the circle by the arc, hidden by OK on a TV', (
      tester,
    ) async {
      final frame = fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44, centreDeg: -90)]));
      await pumpRing(tester, frame);
      await tester.pumpAndSettle();
      expect(find.text('1.4 m'), findsOneWidget);
      // Left of the circle, where the arc is, past its edge
      final picture = tester.getRect(find.byKey(const Key('picture')));
      final number = tester.getCenter(find.text('1.4 m'));
      expect(number.dx, lessThan(picture.center.dx - picture.height / 4));
      expect(number.dy, closeTo(picture.center.dy, picture.height / 8));
      expect(tester.widget<Text>(find.text('1.4 m')).style?.fontSize, 14);

      // With the frame, on the left edge
      memory[StoreKey.djiObstacleShapeFrame] = true;
      await pumpRing(tester, frame);
      await tester.pumpAndSettle();
      expect(tester.getCenter(find.text('1.4 m')).dx, lessThan(picture.left + picture.width / 4));
      memory[StoreKey.djiObstacleShapeFrame] = false;

      // Turned off on this device
      memory[StoreKey.djiObstacleNumbersOff] = true;
      await pumpRing(tester, frame);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_live_obstacle_distance')), findsNothing);
      memory[StoreKey.djiObstacleNumbersOff] = false;

      await pumpRing(tester, frame, tv: true);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('1.4 m')).style?.fontSize, 22);
      await pumpRing(tester, frame, tv: true, numbersHidden: true);
      await tester.pumpAndSettle();
      expect(find.text('1.4 m'), findsNothing);
      expect(find.byKey(const Key('dji_live_obstacle_ring')), findsOneWidget);
    });

    testWidgets('with the even glow the distance is low on the left, never at the top where ahead is', (
      tester,
    ) async {
      await pumpRing(tester, fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44)])));
      await tester.pumpAndSettle();
      final picture = tester.getRect(find.byKey(const Key('picture')));
      var number = tester.getCenter(find.text('1.4 m'));
      expect(number.dx, lessThan(picture.center.dx));
      expect(number.dy, greaterThan(picture.center.dy));
      // With the frame: in the bottom left corner
      memory[StoreKey.djiObstacleShapeFrame] = true;
      await pumpRing(tester, fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44)])));
      await tester.pumpAndSettle();
      number = tester.getCenter(find.text('1.4 m'));
      expect(number.dx, lessThan(picture.left + picture.width / 4));
      expect(number.dy, greaterThan(picture.top + picture.height * 3 / 4));
    });

    testWidgets('a screen reader hears the side only when it changes, not at every frame', (tester) async {
      final semantics = tester.ensureSemantics();
      final container = await pumpRing(
        tester,
        fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44, centreDeg: -90)])),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Obstacle within 1.4 m. On the left'), findsOneWidget);
      // Nearer on the same side, still faint: the same words
      container
          .read(djiLiveFrameProvider.notifier)
          .offer(fakeFrame(atMs: 2000, alert: fakeDecision(on: true, arcs: [fakeArc(1.3, centreDeg: -80)])));
      await tester.pump();
      expect(find.bySemanticsLabel('Obstacle within 1.4 m. On the left'), findsOneWidget);
      // Strong now: new words
      container
          .read(djiLiveFrameProvider.notifier)
          .offer(fakeFrame(atMs: 3000, alert: fakeDecision(on: true, arcs: [fakeArc(0.9, centreDeg: -80)])));
      await tester.pump();
      expect(find.bySemanticsLabel('Obstacle within 0.9 m. On the left'), findsOneWidget);
      semantics.dispose();
    });
  });
}
