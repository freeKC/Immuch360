// The card a splat photo gets as its poster when no view can be drawn (plan of 3 November 2026, section 7): a scene of
// SPZ version 4 (no ZSTD in Dart), or a drawing that failed. A dark card with the "3D" glyph of the viewer's tiles,
// the scene's name and its gaussian count in the app's language, then the mark when its switch is on. Drawn with the
// app's own text engine (dart:ui) and fonts, so it runs where the save runs, in the app; encoded in an isolate.

import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:immich_mobile/domain/services/splat_photo/splat_poster_draw.dart';

/// The card of the scene [name] with the line [countLine] ("150,000 gaussians" in the app's language), as a JPEG of
/// [width] by [height], with the mark when [mark]
Future<Uint8List> drawSplatPosterCard({
  required String name,
  required String countLine,
  bool mark = true,
  int width = splatPosterWidth,
  int height = splatPosterHeight,
}) async {
  final w = width.toDouble();
  final h = height.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w, h),
    ui.Paint()
      ..shader = ui.Gradient.linear(ui.Offset.zero, ui.Offset(0, h), const [
        ui.Color(0xFF1E2430),
        ui.Color(0xFF0E1116),
      ]),
  );
  // The glyph, as the mark's path
  final side = h * 0.28;
  final glyph = ui.Path()..fillType = ui.PathFillType.nonZero;
  for (final contour in splatPathContours(splatMarkPath)) {
    glyph.moveTo(contour[0], contour[1]);
    for (var k = 2; k + 1 < contour.length; k += 2) {
      glyph.lineTo(contour[k], contour[k + 1]);
    }
    glyph.close();
  }
  canvas
    ..save()
    ..translate((w - side) / 2, h * 0.36 - side / 2)
    ..scale(side / 24)
    ..drawPath(glyph, ui.Paint()..color = const ui.Color(0xD9FFFFFF))
    ..restore();
  void line(String text, double size, double top, int color) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: ui.TextAlign.center,
              maxLines: 1,
              ellipsis: '…',
              fontFamily: 'GoogleSans',
              fontSize: size,
            ),
          )
          ..pushStyle(ui.TextStyle(color: ui.Color(color)))
          ..addText(text);
    final paragraph = builder.build()..layout(ui.ParagraphConstraints(width: w * 0.86));
    canvas.drawParagraph(paragraph, ui.Offset(w * 0.07, top));
  }

  line(name, h * 0.052, h * 0.6, 0xFFFFFFFF);
  line(countLine, h * 0.034, h * 0.69, 0xB3FFFFFF);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final pixels = rgba!.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
  return _encodeInIsolate(pixels, width, height, mark);
}

/// [rgba] encoded in an isolate whose closure holds nothing of the drawing
Future<Uint8List> _encodeInIsolate(Uint8List rgba, int width, int height, bool mark) =>
    Isolate.run(() => _encodeRgba(rgba, width, height, mark));

Uint8List _encodeRgba(Uint8List rgba, int width, int height, bool mark) {
  final rgb = Uint8List(3 * width * height);
  for (var k = 0; k < width * height; k++) {
    rgb[3 * k] = rgba[4 * k];
    rgb[3 * k + 1] = rgba[4 * k + 1];
    rgb[3 * k + 2] = rgba[4 * k + 2];
  }
  return encodeSplatPoster(rgb, width, height, mark: mark);
}
