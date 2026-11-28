import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/utils/timezone.dart';

/// The date of [asset] over its time, in white, as the viewer shows them: in the middle of its top bar, and on a TV at
/// the bottom left of a photo, aligned on the left ([alignLeft]) with [shadows] to stand out over the photo (see
/// ViewerBottomBar). The date and time the photo was taken when its EXIF tells them, else its creation date. [oneLine]
/// puts them on one line, under the file name of a computer's viewer.
class ViewerDateTime extends ConsumerWidget {
  const ViewerDateTime({super.key, required this.asset, this.alignLeft = false, this.shadows, this.oneLine = false});

  final BaseAsset asset;
  final bool alignLeft;
  final List<Shadow>? shadows;
  final bool oneLine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exifInfo = ref.watch(assetExifProvider(asset)).valueOrNull;
    final alwaysUse24HourFormat = MediaQuery.alwaysUse24HourFormatOf(context);

    final (dateTime, _) = resolveAssetDateTime(asset, exifInfo);

    final dateFormatted = dateTime.formatDate();
    final timeFormatted = dateTime.formatTime(alwaysUse24HourFormat: alwaysUse24HourFormat);

    if (oneLine) {
      return Text(
        '$dateFormatted · $timeFormatted',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.labelMedium?.copyWith(color: Colors.white70, shadows: shadows),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignLeft ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          dateFormatted,
          style: context.textTheme.labelLarge?.copyWith(color: Colors.white, shadows: shadows),
        ),
        Text(
          timeFormatted,
          style: context.textTheme.labelMedium?.copyWith(color: Colors.white70, shadows: shadows),
        ),
      ],
    );
  }
}
