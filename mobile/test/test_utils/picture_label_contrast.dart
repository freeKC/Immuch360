// The contrast a label over a picture really gives, read from the widgets drawn (no golden image): the colour of its
// text, and the black under it (the scrim of a PictureLabel, the pill of a PictureBadge) composed over a pixel of a
// white, a black or a busy picture.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/images/picture_label.widget.dart';

/// The WCAG threshold for small text
const smallTextContrast = 4.5;

/// The pixels a picture shows behind a label: a white sky, a black night, and a busy photo (snow, a yellow wall, a blue
/// sky, a skin, grass, a red coat, a grey cloud)
const busyPicture = [
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFFF5F5F0),
  Color(0xFFFFEB3B),
  Color(0xFF87CEEB),
  Color(0xFFF1C27D),
  Color(0xFF7CFC00),
  Color(0xFFE53935),
  Color(0xFFD3D3D3),
];

/// A PNG of [width] x [height] pixels of [color] alone
Future<Uint8List> solidPng(Color color, {int width = 16, int height = 16}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// The lightest black under the text of [label] (a PictureLabel or a PictureBadge, or a widget holding one): the top of
/// the scrim behind the text, or the pill
Color shadeUnder(WidgetTester tester, Finder label) {
  final scrim = find.descendant(of: label, matching: find.byKey(PictureLabel.scrimKey), matchRoot: true);
  final pill = find.descendant(of: label, matching: find.byKey(PictureBadge.pillKey), matchRoot: true);
  final box = scrim.evaluate().isNotEmpty ? scrim : pill;
  expect(box, findsOneWidget, reason: 'a scrim or a pill under the label');
  final decoration = tester.widget<DecoratedBox>(box).decoration as BoxDecoration;
  final gradient = decoration.gradient;
  final colors = gradient == null ? [decoration.color!] : gradient.colors;
  return colors.reduce((a, b) => a.a <= b.a ? a : b);
}

/// The colours of the text drawn in [label], as painted (the style each Text resolved with its DefaultTextStyle)
List<Color> textColorsIn(WidgetTester tester, Finder label) {
  final paragraphs = find.descendant(of: label, matching: find.byType(RichText));
  expect(paragraphs, findsWidgets, reason: 'some text in the label');
  return [
    for (final element in paragraphs.evaluate())
      (element.renderObject! as RenderParagraph).text.style?.color ?? const Color(0xFF000000),
  ];
}

/// The lowest contrast of the text of [label] over each pixel of [picture] under its black
double lowestContrast(WidgetTester tester, Finder label, {List<Color> picture = busyPicture}) {
  final shade = shadeUnder(tester, label);
  var lowest = double.infinity;
  for (final text in textColorsIn(tester, label)) {
    for (final pixel in picture) {
      final contrast = contrastRatio(text, Color.alphaBlend(shade, pixel));
      if (contrast < lowest) {
        lowest = contrast;
      }
    }
  }
  return lowest;
}
