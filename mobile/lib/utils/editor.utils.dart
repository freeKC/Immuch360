import 'dart:math';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/utils/matrix.utils.dart';
import 'package:openapi/api.dart' hide AssetEditAction;

Rect convertCropParametersToRect(CropParameters parameters, int originalWidth, int originalHeight) {
  return Rect.fromLTWH(
    parameters.x.toDouble() / originalWidth,
    parameters.y.toDouble() / originalHeight,
    parameters.width.toDouble() / originalWidth,
    parameters.height.toDouble() / originalHeight,
  );
}

CropParameters convertRectToCropParameters(Rect rect, int originalWidth, int originalHeight) {
  final x = (rect.left * originalWidth).truncate();
  final y = (rect.top * originalHeight).truncate();
  final width = (rect.width * originalWidth).truncate();
  final height = (rect.height * originalHeight).truncate();

  return CropParameters(
    x: max(x, 0).clamp(0, originalWidth),
    y: max(y, 0).clamp(0, originalHeight),
    width: max(width, 0).clamp(0, originalWidth - x),
    height: max(height, 0).clamp(0, originalHeight - y),
  );
}

AffineMatrix buildAffineFromEdits(List<AssetEdit> edits) {
  return AffineMatrix.compose(
    edits.map<AffineMatrix>((edit) {
      return switch (edit) {
        RotateEdit(:final parameters) => AffineMatrix.rotate(parameters.angle * pi / 180),
        MirrorEdit(:final parameters) =>
          parameters.axis == MirrorAxis.horizontal ? AffineMatrix.flipY() : AffineMatrix.flipX(),
        CropEdit() => AffineMatrix.identity(),
      };
    }).toList(),
  );
}

bool isCloseToZero(double value, [double epsilon = 1e-15]) {
  return value.abs() < epsilon;
}

typedef NormalizedTransform = ({int rotation, bool mirrorHorizontal, bool mirrorVertical});

NormalizedTransform normalizeTransformEdits(List<AssetEdit> edits) {
  final matrix = buildAffineFromEdits(edits);

  final double a = matrix.a;
  final double b = matrix.b;
  final double c = matrix.c;
  final double d = matrix.d;

  final degrees = ((isCloseToZero(a) ? asin(c) : acos(a)) * 180) / pi;

  // We only allow 90 degree increments
  final quarterTurns = (degrees / 90).round() % 4;

  return (rotation: quarterTurns * 90, mirrorHorizontal: false, mirrorVertical: isCloseToZero(a) ? b == c : a == -d);
}

/// How many quarter turns clockwise [edits] turn the picture, 0 to 3, the mirror aside (see [normalizeTransformEdits])
int quarterTurnsOfEdits(List<AssetEdit> edits) => normalizeTransformEdits(edits).rotation ~/ 90;

/// [edits] once the picture they make is turned by [turns] quarter turns clockwise (negative turns go counter
/// clockwise): what the editor saves after as many presses on "rotate clockwise", in the editor's order, the crop first
/// and untouched, then the mirror, then the rotation. An empty list means no edit at all, which removes them.
///
/// The server applies the edits in their order, so turning the result is appending a rotation; the mirror and the
/// rotations then fold into one mirror and one rotation, as the editor reads them (see [normalizeTransformEdits]). The
/// crop keeps its parameters as stored: it never goes through a rectangle, so it does not drift by a pixel.
List<AssetEdit> composeQuarterTurns(List<AssetEdit> edits, int turns) {
  final crop = edits.whereType<CropEdit>().firstOrNull;
  final transform = normalizeTransformEdits(edits);
  final rotation = ((transform.rotation + 90 * turns) % 360 + 360) % 360;
  return [
    ?crop,
    if (transform.mirrorVertical) MirrorEdit(MirrorParameters(axis: MirrorAxis.vertical)),
    if (rotation != 0) RotateEdit(RotateParameters(angle: rotation)),
  ];
}
