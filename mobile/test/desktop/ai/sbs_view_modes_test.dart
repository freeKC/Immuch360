// The view modes of a photo of two eyes side by side on a computer: the part of the frame each eye takes, the size
// each mode shows, the colours of each mode as painted, the wiggle every 140 ms, and the buttons of the top bar.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/sbs_view_modes.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';

import '../../unit/presentation/presentation_context.dart';
import 'library/version_fixtures.dart';

// The left eye, and the right one
const _left = Color(0xFFC86432);
const _right = Color(0xFF14B4F0);

/// A frame of two eyes of 8 x 8 pixels, each of one colour: [first] on the left half, [second] on the right one
Future<ui.Image> _frame({Color first = _left, Color second = _right}) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = first)
    ..drawRect(const Rect.fromLTWH(8, 0, 8, 8), Paint()..color = second);
  return recorder.endRecording().toImage(16, 8);
}

/// What [painter] draws in a box of [size], read back as RGBA
Future<(ByteData, int)> _paint(SbsPhotoPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return (bytes, image.width);
}

Color _pixel((ByteData, int) painted, int x, int y) {
  final (bytes, width) = painted;
  final at = (y * width + x) * 4;
  return Color.fromARGB(bytes.getUint8(at + 3), bytes.getUint8(at), bytes.getUint8(at + 1), bytes.getUint8(at + 2));
}

/// An image provider for a picture already made: no decoding, so a widget test sees it at once
class _ReadyImage extends ImageProvider<_ReadyImage> {
  const _ReadyImage(this.image);

  final ui.Image image;

  @override
  Future<_ReadyImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ReadyImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the frame of each eye', () {
    const frame = Size(200, 50);

    test('the left eye on the left half, unless the right one comes first', () {
      expect(sbsEyeRect(frame, left: true), const Rect.fromLTWH(0, 0, 100, 50));
      expect(sbsEyeRect(frame, left: false), const Rect.fromLTWH(100, 0, 100, 50));
      expect(sbsEyeRect(frame, left: true, order: EyeOrder.rightLeft), const Rect.fromLTWH(100, 0, 100, 50));
      expect(sbsEyeRect(frame, left: false, order: EyeOrder.rightLeft), const Rect.fromLTWH(0, 0, 100, 50));
    });

    test('one eye shows at its own width, a half width one twice as wide, two side by side', () {
      expect(sbsShownSize(frame, StereoEyes.full, SbsViewMode.leftEye), const Size(100, 50));
      expect(sbsShownSize(frame, StereoEyes.full, SbsViewMode.wiggle), const Size(100, 50));
      expect(sbsShownSize(frame, StereoEyes.full, SbsViewMode.anaglyph), const Size(100, 50));
      expect(sbsShownSize(frame, StereoEyes.full, SbsViewMode.sideBySide), const Size(200, 50));
      expect(sbsShownSize(frame, StereoEyes.half, SbsViewMode.leftEye), const Size(200, 50));
      expect(sbsShownSize(frame, StereoEyes.half, SbsViewMode.sideBySide), const Size(400, 50));
    });

    test('the size the viewer gives a photo, none without its frame', () {
      final asset = LocalAsset(
        id: 'f1',
        name: 'salon_3D_LRF_Full_SBS.jpg',
        type: AssetType.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        width: 8000,
        height: 3000,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );
      const photo = FlatStereoPhoto(eyes: StereoEyes.full);
      expect(desktopSbsShownSize(asset, photo, SbsViewMode.leftEye), const Size(4000, 3000));
      expect(
        desktopSbsShownSize(
          LocalAsset(
            id: 'f2',
            name: 'x_sbs.jpg',
            type: AssetType.image,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            playbackStyle: AssetPlaybackStyle.image,
            isEdited: false,
          ),
          photo,
          SbsViewMode.leftEye,
        ),
        isNull,
      );
    });
  });

  group('the colours painted', () {
    testWidgets('each mode shows the eye it should, the left one on the left, red and cyan mixed', (tester) async {
      await tester.runAsync(() async {
        final frame = await _frame();
        SbsPhotoPainter painter(SbsViewMode mode, {EyeOrder order = EyeOrder.leftRight, bool showRight = false}) =>
            SbsPhotoPainter(image: frame, mode: mode, eyes: StereoEyes.full, order: order, showRight: showRight);

        expect(_pixel(await _paint(painter(SbsViewMode.leftEye), const Size(8, 8)), 4, 4), _left);
        expect(_pixel(await _paint(painter(SbsViewMode.wiggle), const Size(8, 8)), 4, 4), _left);
        expect(_pixel(await _paint(painter(SbsViewMode.wiggle, showRight: true), const Size(8, 8)), 4, 4), _right);

        final sideBySide = await _paint(painter(SbsViewMode.sideBySide), const Size(16, 8));
        expect((_pixel(sideBySide, 3, 4), _pixel(sideBySide, 12, 4)), (_left, _right));

        // Crossed eyes: the right eye is stored first, every mode puts the left one back on the left
        final crossed = await _paint(painter(SbsViewMode.sideBySide, order: EyeOrder.rightLeft), const Size(16, 8));
        expect((_pixel(crossed, 3, 4), _pixel(crossed, 12, 4)), (_right, _left));
        expect(
          _pixel(await _paint(painter(SbsViewMode.leftEye, order: EyeOrder.rightLeft), const Size(8, 8)), 4, 4),
          _right,
        );

        // The red of the left eye, the green and the blue of the right one
        final anaglyph = await _paint(painter(SbsViewMode.anaglyph), const Size(8, 8));
        expect(_pixel(anaglyph, 4, 4), const Color(0xFFC8B4F0));
      });
    });

    testWidgets('one eye is contained and centred in a box of another shape', (tester) async {
      await tester.runAsync(() async {
        final frame = await _frame();
        final painted = await _paint(
          SbsPhotoPainter(image: frame, mode: SbsViewMode.leftEye, eyes: StereoEyes.full),
          const Size(16, 8),
        );
        // The square eye takes the middle 8 pixels: nothing is drawn on either side
        expect(_pixel(painted, 1, 4).a, 0);
        expect(_pixel(painted, 8, 4), _left);
        expect(_pixel(painted, 14, 4).a, 0);
      });
    });

    test('the matrices keep the red of one eye and the green and blue of the other', () {
      expect(anaglyphLeftMatrix.sublist(0, 5), [1, 0, 0, 0, 0]);
      expect(anaglyphLeftMatrix.sublist(5, 15).every((value) => value == 0), isTrue);
      expect(anaglyphRightMatrix.sublist(0, 5).every((value) => value == 0), isTrue);
      expect(anaglyphRightMatrix.sublist(5, 15), [0, 1, 0, 0, 0, 0, 0, 1, 0, 0]);
      expect(anaglyphLeftMatrix.sublist(15), [0, 0, 0, 1, 0]);
      expect(anaglyphRightMatrix.sublist(15), [0, 0, 0, 1, 0]);
    });
  });

  group('the wiggle', () {
    SbsPhotoPainter painterOf(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byKey(const Key('sbs_photo_view'))).painter! as SbsPhotoPainter;

    Widget view(ui.Image frame, SbsViewMode mode) => Directionality(
      textDirection: TextDirection.ltr,
      child: SbsPhotoView(
        image: _ReadyImage(frame),
        photo: const FlatStereoPhoto(eyes: StereoEyes.full),
        mode: mode,
      ),
    );

    testWidgets('shows each eye in turn every 140 ms, and stops in another mode', (tester) async {
      final frame = (await tester.runAsync(_frame))!;
      await tester.pumpWidget(view(frame, SbsViewMode.wiggle));
      await tester.pump();
      expect(painterOf(tester).showRight, isFalse);

      await tester.pump(const Duration(milliseconds: 139));
      expect(painterOf(tester).showRight, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(painterOf(tester).showRight, isTrue);
      await tester.pump(sbsWiggleInterval);
      expect(painterOf(tester).showRight, isFalse);
      await tester.pump(sbsWiggleInterval);
      expect(painterOf(tester).showRight, isTrue);

      await tester.pumpWidget(view(frame, SbsViewMode.leftEye));
      expect(painterOf(tester).showRight, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(painterOf(tester).showRight, isFalse);
      expect(painterOf(tester).mode, SbsViewMode.leftEye);
    });

    testWidgets('no timer is left once the view is gone', (tester) async {
      final frame = (await tester.runAsync(_frame))!;
      await tester.pumpWidget(view(frame, SbsViewMode.wiggle));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      // A periodic timer still running would fail the test here
    });
  });

  group('the buttons of the top bar', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });
    tearDown(() async => context.dispose());

    final asset = LocalAsset(
      id: 'f1',
      name: 'salon_3D_LRF_Full_SBS.jpg',
      type: AssetType.image,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      width: 16,
      height: 6,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );
    final ours = FlatStereoPhoto(eyes: StereoEyes.full, xmp: versionXmp(Uint8List(4)));

    Future<ProviderContainer> pumpButton(WidgetTester tester, BaseAsset asset, FlatStereoPhoto? photo) async {
      // A new tree each time: the overrides of a scope cannot change
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpTestWidget(
        context,
        ColoredBox(
          color: Colors.black,
          child: DesktopSbsViewButton(asset: asset),
        ),
        overrides: [flatStereoProvider(asset).overrideWith((ref) async => photo)],
      );
      return ProviderScope.containerOf(tester.element(find.byType(DesktopSbsViewButton)));
    }

    testWidgets('our photo says its relief was estimated by AI, and the menu changes the mode', (tester) async {
      final container = await pumpButton(tester, asset, ours);

      expect(find.text('Relief estimated by AI'), findsOneWidget);
      expect(container.read(sbsViewModeProvider), SbsViewMode.leftEye);
      await tester.tap(find.byKey(const Key('desktop_sbs_view_mode')));
      await tester.pumpAndSettle();
      for (final label in ['Left eye', 'Side by side', 'Wiggle', 'Red and cyan']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(
        find.ancestor(of: find.text('Red and cyan'), matching: find.byType(CheckedPopupMenuItem<SbsViewMode>)),
      );
      await tester.pumpAndSettle();
      expect(container.read(sbsViewModeProvider), SbsViewMode.anaglyph);
    });

    testWidgets('another tool\'s file has the menu without the label', (tester) async {
      await pumpButton(tester, asset, const FlatStereoPhoto(eyes: StereoEyes.half));
      expect(find.text('Relief estimated by AI'), findsNothing);
      expect(find.byKey(const Key('desktop_sbs_view_mode')), findsOneWidget);
    });

    test('ours and two full width eyes show in their mode at once, half width eyes told by a name wait', () {
      expect(sbsShownAtOnce(ours), isTrue);
      expect(sbsShownAtOnce(FlatStereoPhoto(eyes: StereoEyes.half, xmp: versionXmp(Uint8List(4)))), isTrue);
      expect(sbsShownAtOnce(const FlatStereoPhoto(eyes: StereoEyes.full)), isTrue);
      expect(sbsShownAtOnce(const FlatStereoPhoto(eyes: StereoEyes.half)), isFalse);
    });

    testWidgets('a photo told by its name alone, with half width eyes, stays as stored until a mode is picked', (
      tester,
    ) async {
      // An export of a photo editor may well be named so: one photo, not two eyes
      final named = LocalAsset(
        id: 'f9',
        name: 'IMG_1234_LR.jpg',
        type: AssetType.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        width: 4000,
        height: 3000,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpTestWidget(
        context,
        ColoredBox(
          color: Colors.black,
          child: Column(
            children: [
              DesktopSbsViewButton(asset: named),
              Consumer(
                builder: (context, ref, _) => Text(desktopSbsPhotoOf(ref, named) == null ? 'as stored' : 'in its mode'),
              ),
            ],
          ),
        ),
        overrides: [
          flatStereoProvider(named).overrideWith((ref) async => const FlatStereoPhoto(eyes: StereoEyes.half)),
        ],
      );

      expect(find.text('as stored'), findsOneWidget);
      final menu = tester.widget<PopupMenuButton<SbsViewMode>>(find.byKey(const Key('desktop_sbs_view_mode')));
      expect((menu.initialValue, menu.tooltip), (null, '3D photo'));

      await tester.tap(find.byKey(const Key('desktop_sbs_view_mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(of: find.text('Side by side'), matching: find.byType(CheckedPopupMenuItem<SbsViewMode>)),
      );
      await tester.pumpAndSettle();

      expect(find.text('in its mode'), findsOneWidget);
      final chosen = tester.widget<PopupMenuButton<SbsViewMode>>(find.byKey(const Key('desktop_sbs_view_mode')));
      expect((chosen.initialValue, chosen.tooltip), (SbsViewMode.sideBySide, 'Side by side'));
    });

    testWidgets('a file of a newer format says why it is flat, an ordinary photo shows nothing', (tester) async {
      final newer = FlatStereoPhoto(
        eyes: StereoEyes.full,
        xmp: StereoPhotoXmp.parse(
          versionXmp(Uint8List(4)).toXml().replaceFirst('FormatVersion="1"', 'FormatVersion="2"'),
        ),
      );
      await pumpButton(tester, asset, newer);
      expect(find.byKey(const Key('desktop_sbs_view_mode')), findsNothing);
      final tooltip = tester.widget<Tooltip>(find.byKey(const Key('desktop_sbs_newer_format')));
      expect(tooltip.message, 'Made by a newer version of Immuch360: shown flat');

      await pumpButton(tester, asset, null);
      expect(find.byKey(const Key('desktop_sbs_view_mode')), findsNothing);
      expect(find.byKey(const Key('desktop_sbs_newer_format')), findsNothing);
    });
  });
}
