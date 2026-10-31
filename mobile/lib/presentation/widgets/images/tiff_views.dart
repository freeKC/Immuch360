// What the viewers show of a TIFF decoded in Dart on a device without TIFF decoder (see photoDecodePath): while it
// is read and decoded, and in its place when it does not decode

import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// What a viewer shows while a TIFF is read and decoded on the device: a spinner that fills as the file comes when
/// its size is known ([progress]), and the line "Decoding the TIFF on this device"
class TiffDecodingView extends StatelessWidget {
  const TiffDecodingView({super.key, this.progress, this.color});

  final ImageChunkEvent? progress;

  /// For the text and the spinner (white over the black of the viewers), the theme's otherwise
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    final total = progress?.expectedTotalBytes;
    final value = progress == null || total == null || total <= 0
        ? null
        : (progress.cumulativeBytesLoaded / total).clamp(0.0, 1.0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(value: value, color: color),
            const SizedBox(height: 16),
            Text(
              context.t.tiff_decoding,
              key: const Key('tiff_decoding'),
              textAlign: TextAlign.center,
              style: DefaultTextStyle.of(context).style.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// In place of a TIFF that did not decode on the device: "This device cannot decode this TIFF"
class TiffUndecodedView extends StatelessWidget {
  const TiffUndecodedView({super.key, this.color});

  /// For the text and the icon (white over the black of the viewers), the theme's otherwise
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              context.t.tiff_cannot_decode,
              key: const Key('tiff_cannot_decode'),
              textAlign: TextAlign.center,
              style: DefaultTextStyle.of(context).style.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
