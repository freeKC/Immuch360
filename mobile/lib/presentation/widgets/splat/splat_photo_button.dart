// "Explore the splat scene" on a splat photo of the timeline (plan of 3 November 2026, sections 3.1 and 4): the scene
// kept on the Immich server inside a photo, opened by the viewer of this device. The computers, the Android phones and
// tablets and the Meta Quest 3 and 3S of the builds that offer the splats get the button in the top bar of the photo,
// gated on the packet alone (SplatPhotoXmp.head goes to the gate the .spz of a share gets) so that a scene this device
// cannot show is greyed with the reason before a byte of it is downloaded. A copy that lost its scene, a photo of a
// newer version or a damaged packet greys it too. Every device gets the details row; the TVs, iOS and the Quest builds
// of the Meta Horizon Store say there where to explore the scene, and once, for 4 seconds, as the photo opens.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_tail.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_button.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/splat/splat_photo.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// The key of "Explore the splat scene" on a splat photo
const exploreSplatPhotoButtonKey = Key('splat_photo_explore');

/// The key of the details row of a splat photo
const splatPhotoDetailsKey = Key('splat_photo_details');

/// How long the line saying where to explore a scene stays, on the devices that cannot
const splatPhotoNoticeDuration = Duration(seconds: 4);

/// Opens the scene of the splat photo [asset], told by [xmp], with the [request] the gate of this device gave. Tests
/// replace it.
typedef SplatPhotoOpener =
    Future<void> Function(
      BuildContext context,
      WidgetRef ref,
      BaseAsset asset,
      SplatPhotoXmp xmp,
      GaussianSplatRequest request,
    );

/// See [SplatPhotoOpener]: nothing until the scene can be taken out of its photo
final splatPhotoOpenerProvider = Provider<SplatPhotoOpener>((ref) => (context, ref, asset, xmp, request) async {});

/// What a splat photo's [problem] says, as the greyed button and the details row say it
String splatPhotoProblemText(Translations t, SplatPhotoProblem problem) => switch (problem) {
  SplatPhotoProblem.lost => t.splat_photo_lost,
  SplatPhotoProblem.newer => t.splat_photo_newer,
  SplatPhotoProblem.missing || SplatPhotoProblem.notSpz || SplatPhotoProblem.wrongSum => t.splat_photo_damaged,
};

/// The size of the file of [asset] as the server synced it, or its copy on the device: what tells a copy that lost its
/// scene with no download
int? splatPhotoFileSizeOf(WidgetRef ref, BaseAsset asset) {
  // An edit of Immich gives the asset the size of its edited copy: the original keeps the scene
  final size = ref.watch(assetExifProvider(asset).select((exif) => exif.valueOrNull?.fileSize));
  return asset.isEdited ? null : size;
}

/// "Explore the splat scene" in the top bar of the splat photo [asset] whose packet is [xmp] (see the top of this file)
class SplatPhotoButton extends ConsumerWidget {
  const SplatPhotoButton({super.key, required this.asset, required this.xmp});

  final BaseAsset asset;
  final SplatPhotoXmp xmp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final problem = splatPhotoProblemOf(xmp, fileLength: splatPhotoFileSizeOf(ref, asset));
    if (problem != null) {
      return IconButton(
        key: exploreSplatPhotoButtonKey,
        icon: const Icon(Icons.view_in_ar_rounded),
        tooltip: splatPhotoProblemText(t, problem),
        onPressed: null,
      );
    }
    // Nothing until this device is known, so that a scene it cannot show is never offered first
    final verdict = splatVerdictOf(ref, xmp.head!, name: xmp.splatName!, fileBytes: xmp.splatLength!);
    if (verdict == null) {
      return const SizedBox.shrink();
    }
    final request = verdict.request;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return IconButton(
      key: exploreSplatPhotoButtonKey,
      icon: const Icon(Icons.view_in_ar_rounded),
      tooltip: request == null
          ? splatRefusalText(
              t,
              verdict,
              locale,
              onHeadset: ref.watch(splatDeviceClassProvider) == SplatDeviceClass.quest,
            )
          : t.splat_explore,
      onPressed: request == null
          ? null
          : () => unawaited(ref.read(splatPhotoOpenerProvider)(context, ref, asset, xmp, request)),
    );
  }
}

/// The details row of a splat photo: "Splat scene, 150,000 gaussians, 3.4 MiB", then where to explore it from a device
/// that cannot, why it does not open here, and that an edit of Immich left the scene in the original. Nothing for any
/// other photo, nor until its head was read.
class SplatPhotoDetailsTile extends ConsumerWidget {
  const SplatPhotoDetailsTile({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final xmp = ref.watch(splatPhotoProvider(asset)).valueOrNull;
    if (xmp == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final problem = splatPhotoProblemOf(xmp, fileLength: splatPhotoFileSizeOf(ref, asset));
    final explore = ref.watch(splatPhotoExploreProvider);
    String? refusal;
    if (problem == null && explore == SplatPhotoExplore.here) {
      final verdict = splatVerdictOf(ref, xmp.head!, name: xmp.splatName!, fileBytes: xmp.splatLength!);
      if (verdict != null && verdict.request == null) {
        refusal = splatRefusalText(
          t,
          verdict,
          locale,
          onHeadset: ref.watch(splatDeviceClassProvider) == SplatDeviceClass.quest,
        );
      }
    }
    final lines = [
      if (problem != null) splatPhotoProblemText(t, problem),
      if (problem == null && explore == SplatPhotoExplore.elsewhere) t.splat_photo_open_elsewhere,
      if (problem == null && explore == SplatPhotoExplore.elsewhereStore) t.splat_photo_open_elsewhere_store,
      ?refusal,
      if (asset.isEdited) t.splat_photo_edited,
    ];
    final titleStyle = context.textTheme.labelLarge;
    return Column(
      children: [
        const SizedBox(height: 16),
        SheetTile(
          key: splatPhotoDetailsKey,
          title: splatPhotoDetailsLine(t, xmp, locale),
          titleStyle: titleStyle,
          leading: Icon(Icons.view_in_ar_outlined, size: 24, color: titleStyle?.color),
          subtitle: lines.isEmpty ? null : lines.join('\n'),
          subtitleStyle: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
        ),
      ],
    );
  }
}

/// "Splat scene, 150,000 gaussians, 3.4 MiB"
String splatPhotoDetailsLine(Translations t, SplatPhotoXmp xmp, String locale) => t.splat_photo_details(
  count: splatCountText(xmp.splatGaussians ?? 0, locale),
  size: formatBytes(xmp.splatLength ?? 0),
);

/// Says once, for [splatPhotoNoticeDuration], where to explore the scene of the splat photo [asset] on a device that
/// cannot (a TV, iOS, a Quest build of the Meta Horizon Store), as it opens. Shows nothing itself.
class SplatPhotoElsewhereNotice extends ConsumerStatefulWidget {
  const SplatPhotoElsewhereNotice({super.key, required this.asset});

  final BaseAsset asset;

  @override
  ConsumerState<SplatPhotoElsewhereNotice> createState() => _SplatPhotoElsewhereNoticeState();
}

class _SplatPhotoElsewhereNoticeState extends ConsumerState<SplatPhotoElsewhereNotice> {
  /// The photo the line was said for
  String? _said;

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final xmp = ref.watch(splatPhotoProvider(asset)).valueOrNull;
    final key = SplatPhotoService.keyOf(asset);
    if (xmp != null && _said != key) {
      final text = switch (ref.watch(splatPhotoExploreProvider)) {
        SplatPhotoExplore.elsewhere => context.t.splat_photo_open_elsewhere,
        SplatPhotoExplore.elsewhereStore => context.t.splat_photo_open_elsewhere_store,
        _ => null,
      };
      if (text != null) {
        _said = key;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(SnackBar(content: Text(text), duration: splatPhotoNoticeDuration));
          }
        });
      }
    }
    return const SizedBox.shrink();
  }
}

/// The "3D splat" badge of the tile of a photo named like a splat photo (no read: see splatPhotoBadgeProvider)
class SplatPhotoBadge extends ConsumerWidget {
  const SplatPhotoBadge({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(splatPhotoBadgeProvider(asset))) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const Key('splat_photo_badge'),
      padding: const EdgeInsets.only(right: 10.0, top: 6.0),
      child: Text(
        context.t.splat_badge,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          shadows: [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6), offset: Offset.zero)],
        ),
      ),
    );
  }
}
