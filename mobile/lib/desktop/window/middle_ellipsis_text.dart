// A file name on one line, cut in its middle when it does not fit ("VID_2026_11_…_paysage_16x9 (1).mp4"), so that its
// start and its end, the number and the extension that tell two files apart, stay; the whole name in its tooltip. The
// viewers of a computer show the name of the file this way (design of lot 54, after a user could not tell which video
// he was watching).

import 'package:flutter/material.dart';

/// The ellipsis put in the middle of a cut name
const middleEllipsis = '…';

/// [text] cut in its middle to fit [maxWidth] in [style]: as it is when it fits, else its start, an ellipsis and its
/// end, the end one character longer than the start when they differ. [measure] gives the width of a text.
String middleEllipsized(String text, double maxWidth, double Function(String text) measure) {
  if (text.isEmpty || measure(text) <= maxWidth) {
    return text;
  }
  final characters = text.characters.toList();
  String cut(int kept) {
    final start = kept ~/ 2;
    final end = kept - start;
    return '${characters.take(start).join()}$middleEllipsis${characters.skip(characters.length - end).join()}';
  }

  // The most characters kept whose cut fits, by halves
  var low = 0;
  var high = characters.length - 1;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (measure(cut(middle)) <= maxWidth) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return cut(low);
}

/// [text] on one line, cut in its middle when it is too long (see [middleEllipsized]); the whole of it in a tooltip when
/// it is cut, and for a screen reader
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        double measure(String value) {
          final painter = TextPainter(
            text: TextSpan(text: value, style: effective),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        final shown = constraints.hasBoundedWidth ? middleEllipsized(text, constraints.maxWidth, measure) : text;
        final line = Text(
          shown,
          style: style,
          textAlign: textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          semanticsLabel: text,
        );
        return shown == text ? line : Tooltip(message: text, child: line);
      },
    );
  }
}
