import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/pairing/qr_matrix.dart';

/// A QR code drawn module by module, black on a white tile with the quiet zone of the standard (4 modules), in the
/// dark theme too: a phone camera reads dark modules on light. [data] is never shown as text nor read out.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, required this.size, this.semanticLabel});

  final String data;

  /// The side of the white tile, quiet zone included
  final double size;
  final String? semanticLabel;

  // The panel rebuilds every second for its countdown: the last matrix is kept, not encoded again each time
  static ({String data, QrMatrix matrix})? _last;

  static QrMatrix _matrixOf(String data) {
    final last = _last;
    if (last != null && last.data == data) {
      return last.matrix;
    }
    final matrix = QrMatrix.encode(utf8.encode(data));
    _last = (data: data, matrix: matrix);
    return matrix;
  }

  @override
  Widget build(BuildContext context) {
    final matrix = _matrixOf(data);
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(8))),
            child: CustomPaint(painter: QrMatrixPainter(matrix)),
          ),
        ),
      ),
    );
  }
}

/// Paints [matrix] with a quiet zone of 4 modules, each module a whole number of logical pixels when there is room,
/// so that no seam shows between two dark modules
class QrMatrixPainter extends CustomPainter {
  QrMatrixPainter(this.matrix);

  final QrMatrix matrix;
  static const quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = matrix.size + 2 * quietZone;
    final exact = size.shortestSide / modules;
    final module = exact >= 2 ? exact.floorToDouble() : exact;
    // The room left by the rounding, shared on both sides
    final offset = (size.shortestSide - module * modules) / 2;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    final path = Path();
    for (var row = 0; row < matrix.size; row++) {
      for (var column = 0; column < matrix.size; column++) {
        if (matrix.isDark(row, column)) {
          path.addRect(
            Rect.fromLTWH(offset + (column + quietZone) * module, offset + (row + quietZone) * module, module, module),
          );
        }
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(QrMatrixPainter oldDelegate) => !identical(oldDelegate.matrix, matrix);
}
