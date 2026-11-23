// "Sharpen" on the graphics card: Real-ESRGAN x4plus through the sd-cli the app ships for the 360° panoramas
// (SdCppUpscaler of sdcpp_runner.dart, `-M upscale`, its own tiles of 128 px), as the probe of 23 November 2026 ran it:
// the photo reduced to half its size (each block of four pixels averaged), made four times larger, then brought back
// to the size of the photo. Never from a quarter of the size: the probe saw it destroy small text ("DECOWBER 25. 1010").
// x2plus cannot run in sd-cli (the review of the study), so it is not used.
//
// The half picture goes to sd-cli in pieces of at most 1024 x 1024 with 32 pixels of overlap, one run each, so that no
// output of sd-cli is larger than 4096 x 4096 whatever the photo (up to the 50 megapixels of the gate); each piece is
// brought back to twice its size as it comes, then the pieces are blended with their feather. A 12 MP photo takes four
// runs. Measured whole: 28.3 s for 3 MP, 110.5 s for 12 MP, 559 MiB of the card.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show decodePngPicture, encodePngPicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

/// The pieces of the half picture sd-cli upscales, and their overlap, in pixels of the half picture
const sharpenPiece = 1024;
const sharpenPieceOverlap = 32;

/// The size of the half picture of a photo of [width] x [height]
(int, int) sharpenHalfSize(int width, int height) => (math.max(1, width ~/ 2), math.max(1, height ~/ 2));

/// See the top of this file
class SdCppSharpenBackend implements EnhanceBackend {
  SdCppSharpenBackend({required this.upscaler});

  /// sd-cli and x4plus on the card of the job
  final UpscaleBackend upscaler;

  @override
  String get model => 'Real-ESRGAN x4plus';

  @override
  String get modelSha256 => upscaler.modelSha256;

  @override
  bool get fellBack => false;

  @override
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  }) async {
    final width = picture.width;
    final height = picture.height;
    final (halfWidth, halfHeight) = sharpenHalfSize(width, height);
    final rgba = picture.rgba;
    final half = await Isolate.run(
      () => resizeRgba(rgba, width, height, halfWidth, halfHeight),
      debugName: 'enhance-half',
    );
    final pieces = planTiles(halfWidth, halfHeight, tile: sharpenPiece, overlap: sharpenPieceOverlap);
    final grown = <Uint8List>[];
    for (final (index, piece) in pieces.indexed) {
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
      }
      final input = p.join(workFolder, 'piece_$index.png');
      final output = p.join(workFolder, 'piece_${index}_x4.png');
      final png = await Isolate.run(
        () => encodePngPicture(
          SbsDecoded(
            width: piece.width,
            height: piece.height,
            rgba: cropRgbaAt(half, halfWidth, piece.x, piece.y, piece.width, piece.height),
          ),
        ),
        debugName: 'enhance-piece',
      );
      await File(input).writeAsBytes(png, flush: true);
      await upscaler.upscale(
        UpscaleRequest(inputPath: input, outputPath: output, workFolder: workFolder, scale: 4),
        cancel: cancel,
      );
      final (pieceWidth, pieceHeight) = (piece.width, piece.height);
      try {
        grown.add(await Isolate.run(() => pieceTwice(output, pieceWidth, pieceHeight), debugName: 'enhance-x2'));
      } on FormatException catch (error) {
        throw BackendException(ImmersiveErrorCode.outputRejected, error.message);
      }
      File(output).deleteSync();
      onStep(index + 1, pieces.length);
    }
    return Isolate.run(
      () => joinPieces(pieces, grown, halfWidth, halfHeight, width, height),
      debugName: 'enhance-join',
    );
  }
}

/// The x4 output of sd-cli at [path] for a piece of [width] x [height], brought to twice that size. Pure.
Uint8List pieceTwice(String path, int width, int height) {
  final decoded = decodePngPicture(File(path).readAsBytesSync());
  if (decoded.width != 4 * width || decoded.height != 4 * height) {
    throw FormatException('sd-cli gave ${decoded.width} x ${decoded.height}, not ${4 * width} x ${4 * height}');
  }
  return resizeRgba(decoded.rgba, decoded.width, decoded.height, 2 * width, 2 * height);
}

/// The pieces of a half picture of [halfWidth] x [halfHeight], each at twice its size in [grown], blended into the
/// picture of twice the half size, then brought to [width] x [height] (an odd side loses or gains a pixel). Pure.
Uint8List joinPieces(
  List<EnhanceTile> pieces,
  List<Uint8List> grown,
  int halfWidth,
  int halfHeight,
  int width,
  int height,
) {
  final blender = TileBlender(2 * halfWidth, 2 * halfHeight);
  for (final (index, piece) in pieces.indexed) {
    blender.add(
      (x: 2 * piece.x, y: 2 * piece.y, width: 2 * piece.width, height: 2 * piece.height),
      grown[index],
      overlap: 2 * sharpenPieceOverlap,
    );
  }
  final joined = blender.toRgba();
  return resizeRgba(joined, 2 * halfWidth, 2 * halfHeight, width, height);
}
