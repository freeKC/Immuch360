// A label written over a picture that comes later (the name of a file on a tile of a share, the title of a memory, the
// year of a cell of the timeline, a duration, a "3D" badge): readable on any picture, a white sky as a black night, in
// the light and the dark themes alike. A label along the bottom edge sits on a gradient scrim, transparent at its top
// and about 70 % black under the text; a short badge sits on a rounded pill of the same black; the text is white with a
// thin shadow. Never an opaque bar: the picture shows through. The contrast they give is computed (WCAG 2, see
// pictureLabelContrast), so that a test proves it on a white, a black and a busy picture without a golden image.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The colours of the labels over a picture
abstract final class PictureLabelShade {
  /// The opacity of the black of the scrim where the text begins: the lightest under any glyph
  static const textTop = 0.62;

  /// The opacity of the black at the bottom edge of the scrim
  static const bottom = 0.72;

  /// The opacity of the black of the pill of a badge
  static const badge = 0.6;

  static const text = Colors.white;

  /// A thin shadow, the edges of the glyphs on a picture as light as the text
  static const shadows = [Shadow(blurRadius: 2, offset: Offset(0, 1), color: Color(0x99000000))];

  /// The black of the scrim at [opacity]
  static Color black(double opacity) => Colors.black.withValues(alpha: opacity);
}

/// The WCAG 2 contrast ratio of two opaque colours, from 1 (the same) to 21 (white on black)
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The contrast of [text] over [picture] under a black of [shade] opacity: the colour the eye sees behind a glyph is the
/// black of the scrim composed over the pixel of the picture
double pictureLabelContrast(
  Color picture, {
  double shade = PictureLabelShade.textTop,
  Color text = PictureLabelShade.text,
}) => contrastRatio(text, Color.alphaBlend(PictureLabelShade.black(shade), picture));

/// A label along the bottom edge of a picture, for a child of a [Stack] that fills its tile: [child] on the scrim, its
/// text white with a thin shadow and its icons white. [fade] is the height over which the scrim comes from transparent;
/// [padding] places the text inside its dark part (a larger bottom leaves room for a row of icons under it).
class PictureLabel extends StatelessWidget {
  const PictureLabel({super.key, required this.child, this.padding = defaultPadding, this.fade = 16});

  final Widget child;
  final EdgeInsets padding;
  final double fade;

  static const defaultPadding = EdgeInsets.fromLTRB(6, 2, 6, 6);

  /// The part of the scrim behind the text, from [PictureLabelShade.textTop] to [PictureLabelShade.bottom]
  static const scrimKey = Key('picture_label_scrim');

  /// The part above it, from transparent to [PictureLabelShade.textTop]
  static const fadeKey = Key('picture_label_fade');

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: fade,
            child: DecoratedBox(
              key: fadeKey,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [PictureLabelShade.black(0), PictureLabelShade.black(PictureLabelShade.textTop)],
                ),
              ),
            ),
          ),
          DecoratedBox(
            key: scrimKey,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  PictureLabelShade.black(PictureLabelShade.textTop),
                  PictureLabelShade.black(PictureLabelShade.bottom),
                ],
              ),
            ),
            child: Padding(
              padding: padding,
              child: _OnPicture(child: child),
            ),
          ),
        ],
      ),
    );
  }
}

/// A short label over a picture (a duration, "3D", "AV2"): [child] on a rounded pill of black, its text white
class PictureBadge extends StatelessWidget {
  const PictureBadge({super.key, required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 5)});

  final Widget child;
  final EdgeInsets padding;

  static const pillKey = Key('picture_badge_pill');

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: pillKey,
      decoration: BoxDecoration(
        color: PictureLabelShade.black(PictureLabelShade.badge),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Padding(
        padding: padding,
        child: _OnPicture(child: child),
      ),
    );
  }
}

/// White text with a thin shadow, white icons: a style with a colour of its own (one of the text theme) wins, so a
/// label over a picture gives its text no colour, or [PictureLabelShade.text]
class _OnPicture extends StatelessWidget {
  const _OnPicture({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: const TextStyle(color: PictureLabelShade.text, shadows: PictureLabelShade.shadows),
      child: IconTheme.merge(
        data: const IconThemeData(color: PictureLabelShade.text),
        child: child,
      ),
    );
  }
}

/// [text] on one line, cut in the middle when it is too long, so that the end of a file name stays (its number, its
/// extension): "PXL_20261012…522.jpg" rather than "PXL_20261012_14…"
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static const ellipsis = '…';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shown = middleEllipsis(
          text,
          maxWidth: constraints.maxWidth,
          style: DefaultTextStyle.of(context).style.merge(style),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        );
        return Text(shown, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: style);
      },
    );
  }
}

/// [text] cut in the middle with an ellipsis so that it fits [maxWidth] on one line, [text] itself when it fits
String middleEllipsis(
  String text, {
  required double maxWidth,
  required TextStyle style,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (!maxWidth.isFinite) {
    return text;
  }
  bool fits(String candidate) {
    final painter = TextPainter(
      text: TextSpan(text: candidate, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final fit = painter.width <= maxWidth;
    painter.dispose();
    return fit;
  }

  if (fits(text)) {
    return text;
  }
  final chars = text.characters.toList();
  String cut(int kept) {
    final tail = kept ~/ 2;
    return '${chars.take(kept - tail).join()}${MiddleEllipsisText.ellipsis}${chars.skip(chars.length - tail).join()}';
  }

  // The most characters kept that still fit, found by halves
  var low = 0;
  var high = chars.length - 1;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (fits(cut(middle))) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return cut(low);
}
