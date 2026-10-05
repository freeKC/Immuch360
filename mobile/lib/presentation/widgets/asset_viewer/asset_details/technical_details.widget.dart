import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

const _kSeparator = '  •  ';

class TechnicalDetails extends ConsumerWidget {
  final BaseAsset asset;
  final ExifInfo? exifInfo;

  const TechnicalDetails({super.key, required this.asset, this.exifInfo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exifInfo = this.exifInfo;
    final cameraTitle = _getCameraInfoTitle(exifInfo);
    final lensTitle = exifInfo?.lens != null && exifInfo!.lens!.isNotEmpty ? exifInfo.lens : null;
    final lensSubtitle = _getLensInfoSubtitle(exifInfo);

    return Column(
      children: [
        SheetTile(
          title: context.t.details,
          titleStyle: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceSecondary),
        ),
        _buildFileInfoTile(context, ref, asset, exifInfo),
        // Only a HEIF photo may hold a stereo pair: no other photo is read for one
        if (asset.isImage && isHeifName(asset.name)) _SpatialPhotoTile(asset: asset),
        if (asset.isVideo) _VideoDecodeTiles(asset: asset),
        if (cameraTitle != null) ...[
          const SizedBox(height: 16),
          SheetTile(
            title: cameraTitle,
            titleStyle: context.textTheme.labelLarge,
            leading: Icon(Icons.camera_alt_outlined, size: 24, color: context.textTheme.labelLarge?.color),
            subtitle: _getCameraInfoSubtitle(exifInfo),
            subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
          ),
        ],
        if (lensTitle != null) ...[
          const SizedBox(height: 16),
          SheetTile(
            title: lensTitle,
            titleStyle: context.textTheme.labelLarge,
            leading: Icon(Icons.camera_outlined, size: 24, color: context.textTheme.labelLarge?.color),
            subtitle: lensSubtitle,
            subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
          ),
        ] else if (lensSubtitle != null) ...[
          const SizedBox(height: 16),
          SheetTile(
            title: lensSubtitle,
            titleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
            leading: Icon(Icons.camera_outlined, size: 24, color: context.textTheme.labelLarge?.color),
          ),
        ],
      ],
    );
  }

  Widget _buildFileInfoTile(BuildContext context, WidgetRef ref, BaseAsset asset, ExifInfo? exifInfo) {
    final icon = Icon(
      asset.isImage ? Icons.image_outlined : Icons.videocam_outlined,
      size: 24,
      color: context.textTheme.labelLarge?.color,
    );
    final subtitle = _getFileInfo(asset, exifInfo);
    final subtitleStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary);

    if (asset is LocalAsset) {
      final assetMediaRepository = ref.read(assetMediaRepositoryProvider);
      return FutureBuilder<String?>(
        future: assetMediaRepository.getOriginalFilename(asset.id),
        builder: (context, snapshot) {
          return SheetTile(
            title: snapshot.data ?? asset.name,
            titleStyle: context.textTheme.labelLarge,
            leading: icon,
            subtitle: subtitle,
            subtitleStyle: subtitleStyle,
          );
        },
      );
    }

    return SheetTile(
      title: asset.name,
      titleStyle: context.textTheme.labelLarge,
      leading: icon,
      subtitle: subtitle,
      subtitleStyle: subtitleStyle,
    );
  }

  static String _getFileInfo(BaseAsset asset, ExifInfo? exifInfo) {
    final height = asset.height;
    final width = asset.width;
    final resolution = (width != null && height != null) ? "$width x $height" : null;
    final fileSize = exifInfo?.fileSize != null ? formatBytes(exifInfo!.fileSize!) : null;

    return switch ((fileSize, resolution)) {
      (null, null) => '',
      (final String fileSize, null) => fileSize,
      (null, final String resolution) => resolution,
      (final String fileSize, final String resolution) => '$fileSize$_kSeparator$resolution',
    };
  }

  static String? _getCameraInfoTitle(ExifInfo? exifInfo) {
    if (exifInfo == null) {
      return null;
    }
    return switch ((exifInfo.make, exifInfo.model)) {
      (null, null) => null,
      (final String make, null) => make,
      (null, final String model) => model,
      (final String make, final String model) => '$make $model',
    };
  }

  static String? _getCameraInfoSubtitle(ExifInfo? exifInfo) {
    if (exifInfo == null) {
      return null;
    }
    final exposureTime = exifInfo.exposureTime.isNotEmpty ? exifInfo.exposureTime : null;
    final iso = exifInfo.iso != null ? 'ISO ${exifInfo.iso}' : null;
    return [exposureTime, iso].where((spec) => spec != null && spec.isNotEmpty).join(_kSeparator);
  }

  static String? _getLensInfoSubtitle(ExifInfo? exifInfo) {
    if (exifInfo == null) {
      return null;
    }
    final fNumber = exifInfo.fNumber.isNotEmpty ? 'ƒ/${exifInfo.fNumber}' : null;
    final focalLength = exifInfo.focalLength.isNotEmpty ? '${exifInfo.focalLength} mm' : null;
    if (fNumber == null && focalLength == null) {
      return null;
    }
    return [fNumber, focalLength].where((spec) => spec != null && spec.isNotEmpty).join(_kSeparator);
  }
}

/// The codec of a video with its profile, its coded frame size and its frame rate, its bit rate and its picture (bit
/// depth, HDR transfer, colour primaries), as its file declares them (the server tells none of it), and whether this
/// device decodes it: what decides between the original and the transcoded stream (see chooseVideoSource). Nothing
/// until the file was read, and nothing of what it does not tell.
class _VideoDecodeTiles extends ConsumerWidget {
  const _VideoDecodeTiles({required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(videoDecodeDetailsProvider(asset)).valueOrNull;
    final probe = details?.probe;
    final codec = videoCodecSummary(probe);
    if (codec == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final verdict = details?.verdict;
    final bitRate = details?.bitRate;
    final picture = videoPictureSummary(probe, t);
    final dynamicRange = probe?.dynamicRange;
    final hdr =
        probe?.dolbyVision == true || dynamicRange == VideoDynamicRange.hlg || dynamicRange == VideoDynamicRange.pq;
    final missingProfile = verdict?.missingProfile;
    final multiview = probe?.multiview;
    final titleStyle = context.textTheme.labelLarge;
    final subtitleStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary);
    return Column(
      children: [
        // The same probe tells an Apple spatial video, whose base layer plays: one eye
        if (multiview != null) _AppleSpatialTile(info: AppleSpatialInfo.video(multiview)),
        const SizedBox(height: 16),
        SheetTile(
          title: t.technical_details_codec,
          titleStyle: titleStyle,
          leading: Icon(Icons.movie_outlined, size: 24, color: titleStyle?.color),
          subtitle: codec,
          subtitleStyle: subtitleStyle,
        ),
        if (bitRate != null) ...[
          const SizedBox(height: 16),
          SheetTile(
            title: t.technical_details_bit_rate,
            titleStyle: titleStyle,
            leading: Icon(Icons.speed_outlined, size: 24, color: titleStyle?.color),
            subtitle: [
              formatBitRate(bitRate.bitsPerSecond, t, locale: context.locale.toLanguageTag()),
              if (bitRate.source == VideoBitRateSource.mediaData) t.technical_details_bit_rate_whole_file,
              if (bitRate.source == VideoBitRateSource.fileSize) t.technical_details_bit_rate_estimated,
            ].join(_kSeparator),
            subtitleStyle: subtitleStyle,
          ),
        ],
        if (picture != null) ...[
          const SizedBox(height: 16),
          SheetTile(
            title: t.technical_details_picture,
            titleStyle: titleStyle,
            leading: Icon(hdr ? Icons.hdr_on_outlined : Icons.palette_outlined, size: 24, color: titleStyle?.color),
            subtitle: picture,
            subtitleStyle: subtitleStyle,
          ),
        ],
        if (verdict != null) ...[
          const SizedBox(height: 16),
          SheetTile(
            title: context.t.technical_details_decodes,
            titleStyle: titleStyle,
            leading: Icon(
              verdict.supported ? Icons.check_circle_outline : Icons.block_outlined,
              size: 24,
              color: titleStyle?.color,
            ),
            subtitle: [
              verdict.supported ? context.t.yes : context.t.no,
              if (missingProfile != null) t.technical_details_missing_profile(profile: missingProfile),
              if (verdict.supported)
                verdict.hardware ? context.t.video_decoders_hardware : context.t.video_decoders_software,
              if (verdict.maxWidth > 0 && verdict.maxHeight > 0)
                context.t.video_decoders_max(width: '${verdict.maxWidth}', height: '${verdict.maxHeight}'),
            ].join(_kSeparator),
            subtitleStyle: subtitleStyle,
          ),
        ],
      ],
    );
  }
}

/// An Apple spatial photo of [asset], a HEIF photo: what its file says of its two eyes, nothing until it was read, nor
/// for a photo holding no pair (see AppleSpatialService)
class _SpatialPhotoTile extends ConsumerWidget {
  const _SpatialPhotoTile({required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appleSpatialInfoProvider(asset)).valueOrNull;
    return info == null ? const SizedBox.shrink() : _AppleSpatialTile(info: info);
  }
}

/// The row of an Apple spatial photo or video: "Apple spatial photo, two views of 3072 x 3072" or "Apple spatial video
/// (MV-HEVC), shown in 2D", then what the file tells (see [appleSpatialDetails])
class _AppleSpatialTile extends StatelessWidget {
  const _AppleSpatialTile({required this.info});

  final AppleSpatialInfo info;

  @override
  Widget build(BuildContext context) {
    final details = appleSpatialDetails(info, context.t);
    final titleStyle = context.textTheme.labelLarge;
    return Column(
      children: [
        const SizedBox(height: 16),
        SheetTile(
          key: const Key('apple_spatial_details'),
          title: details.title,
          titleStyle: titleStyle,
          leading: Icon(Icons.view_in_ar_outlined, size: 24, color: titleStyle?.color),
          subtitle: details.subtitle,
          subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
        ),
      ],
    );
  }
}

/// The codec of the video track [probe] describes, with the name of its profile and its codecs string, its coded frame
/// size and its frame rate when known ("HEVC Main 10 (hvc1.2.4.L153)  •  5760 x 2880  •  29.97 fps"); null when the
/// probe found no video track
@visibleForTesting
String? videoCodecSummary(SphericalProbe? probe) {
  final codec = probe?.codec;
  if (probe == null || codec == null) {
    return null;
  }
  final codecs = probe.codecs;
  final profile = videoProfileName(codecs);
  final name = profile == null ? videoCodecName(codec) : '${videoCodecName(codec)} $profile';
  final width = probe.codedWidth;
  final height = probe.codedHeight;
  final frameRate = probe.frameRate;
  return [
    codecs == null ? name : '$name ($codecs)',
    if (width != null && height != null) '$width x $height',
    if (frameRate != null) '${formatFrameRate(frameRate)} fps',
  ].join(_kSeparator);
}
