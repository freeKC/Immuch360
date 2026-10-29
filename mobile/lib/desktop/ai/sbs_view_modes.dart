// A flat photo of two eyes side by side in the viewer of a computer (design-final 2026-10-26, section 5, point 5): ours,
// made from a 2D photo, or one of another tool, told by stereo_photo_probe.dart. A computer has no headset, so the
// viewer shows the left eye by default, the photo the user knows; the other modes show the relief without one: both
// eyes side by side, each eye in turn every 140 ms (wiggle), or red and cyan for glasses. Everything is drawn by a
// painter with colour matrices, no shader: the common pubspec gets no new shader for the phones to carry.
//
// The XMP of our files decides the honesty label: "Relief estimated by AI" beside the mode button; a file of a newer
// format is shown flat with its reason. A half width eye is shown twice as wide as it is stored, and a file whose right
// eye comes first (crossed eyes) is put back in order, so every mode shows the left eye on the left.
//
// A file of another tool whose eyes would be half width is told by its name alone, in a frame an ordinary photo has:
// "IMG_1234_LR.jpg" may well be one (stereo_photo_probe.dart). The viewer shows it as stored until the user picks a
// mode for it in the menu, so that such a photo is never shown cut in half and stretched by surprise.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';

/// How the viewer of a computer shows a photo of two eyes side by side
enum SbsViewMode {
  /// The left eye alone, the photo as the user knows it
  leftEye,

  /// Both eyes, the left one on the left
  sideBySide,

  /// Each eye in turn, every [sbsWiggleInterval]
  wiggle,

  /// The red of the left eye with the green and blue of the right one, for red and cyan glasses
  anaglyph,
}

/// The name of [mode] in the menu of the viewer
String sbsViewModeLabel(SbsViewMode mode, Translations t) => switch (mode) {
  SbsViewMode.leftEye => t.ai_immersive_view_left,
  SbsViewMode.sideBySide => t.ai_immersive_view_side_by_side,
  SbsViewMode.wiggle => t.ai_immersive_view_wiggle,
  SbsViewMode.anaglyph => t.ai_immersive_view_anaglyph,
};

/// How long each eye stays on screen in [SbsViewMode.wiggle]
const sbsWiggleInterval = Duration(milliseconds: 140);

/// The mode the viewer shows the photos of two eyes in, kept while the app runs; the left eye at first
final sbsViewModeProvider = StateProvider<SbsViewMode>((ref) => SbsViewMode.leftEye);

/// The photos told by their name alone (see [sbsShownAtOnce]) the user picked a mode for in this session, by
/// flatStereoKey
final sbsChosenPhotosProvider = StateProvider<Set<String>>((ref) => const {});

/// Whether the viewer shows [photo] in its mode as soon as it opens: ours, whose XMP says what it is, and two full
/// width eyes, whose frame no ordinary photo has; a file of another tool with half width eyes waits for a choice
bool sbsShownAtOnce(FlatStereoPhoto photo) => photo.isOurs || photo.eyes == StereoEyes.full;

/// The part of a frame of [frame] pixels that holds the left eye, or the right one when [left] is false, for a file
/// whose eyes come in [order]
Rect sbsEyeRect(Size frame, {required bool left, EyeOrder order = EyeOrder.leftRight}) {
  final half = frame.width / 2;
  final onLeftHalf = left == (order == EyeOrder.leftRight);
  return Rect.fromLTWH(onLeftHalf ? 0 : half, 0, half, frame.height);
}

/// The size a frame of [frame] pixels holding [eyes] is shown at in [mode]: one eye as it is meant to be seen (a half
/// width eye twice as wide as stored), or two of them side by side
Size sbsShownSize(Size frame, StereoEyes eyes, SbsViewMode mode) {
  final eyeWidth = eyes == StereoEyes.full ? frame.width / 2 : frame.width;
  return Size(mode == SbsViewMode.sideBySide ? eyeWidth * 2 : eyeWidth, frame.height);
}

/// The colour matrix of the left eye in red and cyan: its red only
const anaglyphLeftMatrix = <double>[
  1, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// The colour matrix of the right eye in red and cyan: its green and its blue only
const anaglyphRightMatrix = <double>[
  0, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// Draws a frame of two eyes side by side in a view mode, contained and centred in the size it is given
class SbsPhotoPainter extends CustomPainter {
  const SbsPhotoPainter({
    required this.image,
    required this.mode,
    required this.eyes,
    this.order = EyeOrder.leftRight,
    this.showRight = false,
  });

  final ui.Image image;
  final SbsViewMode mode;
  final StereoEyes eyes;
  final EyeOrder order;

  /// In [SbsViewMode.wiggle], whether the right eye is the one on screen now
  final bool showRight;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Size(image.width.toDouble(), image.height.toDouble());
    final shown = sbsShownSize(frame, eyes, mode);
    final fitted = applyBoxFit(BoxFit.contain, shown, size).destination;
    final area = Alignment.center.inscribe(fitted, Offset.zero & size);
    final left = sbsEyeRect(frame, left: true, order: order);
    final right = sbsEyeRect(frame, left: false, order: order);
    Paint paint() => Paint()..filterQuality = FilterQuality.medium;
    switch (mode) {
      case SbsViewMode.leftEye:
        canvas.drawImageRect(image, left, area, paint());
      case SbsViewMode.wiggle:
        canvas.drawImageRect(image, showRight ? right : left, area, paint());
      case SbsViewMode.sideBySide:
        final half = area.width / 2;
        canvas
          ..drawImageRect(image, left, Rect.fromLTWH(area.left, area.top, half, area.height), paint())
          ..drawImageRect(image, right, Rect.fromLTWH(area.left + half, area.top, half, area.height), paint());
      case SbsViewMode.anaglyph:
        // In a layer of its own, so that the right eye adds to the left one only
        canvas
          ..saveLayer(area, Paint())
          ..drawRect(area, Paint()..color = const Color(0xFF000000))
          ..drawImageRect(image, left, area, paint()..colorFilter = const ColorFilter.matrix(anaglyphLeftMatrix))
          ..drawImageRect(
            image,
            right,
            area,
            paint()
              ..colorFilter = const ColorFilter.matrix(anaglyphRightMatrix)
              ..blendMode = BlendMode.plus,
          )
          ..restore();
    }
  }

  @override
  bool shouldRepaint(SbsPhotoPainter oldDelegate) =>
      !identical(oldDelegate.image, image) ||
      oldDelegate.mode != mode ||
      oldDelegate.eyes != eyes ||
      oldDelegate.order != order ||
      oldDelegate.showRight != showRight;
}

/// [image], a photo of two eyes side by side as [photo] describes them, in [mode]. The picture of the previous
/// provider stays until the next one is decoded, as the viewer moves from the thumbnail to the full photo. A file that
/// cannot be read shows [errorBuilder], as the viewer does for any other photo.
class SbsPhotoView extends StatefulWidget {
  const SbsPhotoView({super.key, required this.image, required this.photo, required this.mode, this.errorBuilder});

  final ImageProvider image;
  final FlatStereoPhoto photo;
  final SbsViewMode mode;

  /// What shows when [image] cannot be read and no picture came before; black without it
  final WidgetBuilder? errorBuilder;

  @override
  State<SbsPhotoView> createState() => _SbsPhotoViewState();
}

class _SbsPhotoViewState extends State<SbsPhotoView> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);
  ImageInfo? _info;
  bool _failed = false;
  Timer? _wiggle;
  bool _showRight = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(SbsPhotoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolve();
    }
    if (widget.mode != oldWidget.mode) {
      _showRight = false;
      _updateWiggle();
    }
  }

  @override
  void initState() {
    super.initState();
    _updateWiggle();
  }

  @override
  void dispose() {
    _wiggle?.cancel();
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) {
      return;
    }
    _stream?.removeListener(_listener);
    _failed = false;
    _stream = stream..addListener(_listener);
  }

  void _onError(Object error, StackTrace? stackTrace) {
    if (mounted) {
      setState(() => _failed = true);
    }
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _info?.dispose();
      _info = info;
    });
  }

  void _updateWiggle() {
    _wiggle?.cancel();
    _wiggle = widget.mode == SbsViewMode.wiggle
        ? Timer.periodic(sbsWiggleInterval, (_) => setState(() => _showRight = !_showRight))
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) {
      return _failed ? widget.errorBuilder?.call(context) ?? const SizedBox.expand() : const SizedBox.expand();
    }
    return CustomPaint(
      key: const Key('sbs_photo_view'),
      painter: SbsPhotoPainter(
        image: info.image,
        mode: widget.mode,
        eyes: widget.photo.eyes,
        order: widget.photo.eyeOrder,
        showRight: _showRight,
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// The photo of two eyes side by side the viewer of a computer shows in its modes: [asset] when its file holds two eyes
/// this build shows (and, for one told by its name alone, once the user picked a mode for it), null for any other photo,
/// for a file of a newer format, and while its head is read
FlatStereoPhoto? desktopSbsPhotoOf(WidgetRef ref, BaseAsset asset) {
  if (!FlatStereoService.isCandidate(asset)) {
    return null;
  }
  final photo = ref.watch(flatStereoProvider(asset)).valueOrNull;
  if (photo == null || !photo.canShowIn3d) {
    return null;
  }
  final key = flatStereoKey(asset);
  return sbsShownAtOnce(photo) || ref.watch(sbsChosenPhotosProvider.select((chosen) => chosen.contains(key)))
      ? photo
      : null;
}

/// The size the viewer gives the photo of [asset] in [mode], null when its frame is not known
Size? desktopSbsShownSize(BaseAsset asset, FlatStereoPhoto photo, SbsViewMode mode) {
  final width = asset.width;
  final height = asset.height;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return sbsShownSize(Size(width.toDouble(), height.toDouble()), photo.eyes, mode);
}

const _labelShadows = [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6))];

/// The buttons of the top bar of the viewer for a photo of two eyes side by side: "Relief estimated by AI" when its
/// XMP says so, and the menu of the view modes; for a file of a newer format, why it is shown flat. Nothing for any
/// other photo.
class DesktopSbsViewButton extends ConsumerWidget {
  const DesktopSbsViewButton({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!FlatStereoService.isCandidate(asset)) {
      return const SizedBox.shrink();
    }
    final photo = ref.watch(flatStereoProvider(asset)).valueOrNull;
    if (photo == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    if (!photo.canShowIn3d) {
      return Tooltip(
        key: const Key('desktop_sbs_newer_format'),
        message: t.ai_immersive_newer_version,
        child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.info_outline_rounded)),
      );
    }
    final key = flatStereoKey(asset);
    final shown = sbsShownAtOnce(photo) || ref.watch(sbsChosenPhotosProvider.select((chosen) => chosen.contains(key)));
    // Nothing is checked while the photo is shown as stored
    final mode = shown ? ref.watch(sbsViewModeProvider) : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (photo.isEstimatedRelief)
          Tooltip(
            key: const Key('desktop_sbs_relief_estimated'),
            message: t.ai_immersive_relief_estimated_details,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                t.ai_immersive_relief_estimated,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: _labelShadows,
                ),
              ),
            ),
          ),
        PopupMenuButton<SbsViewMode>(
          key: const Key('desktop_sbs_view_mode'),
          icon: const Icon(Icons.view_in_ar_rounded),
          tooltip: mode == null ? t.ai_immersive_3d_photo : sbsViewModeLabel(mode, t),
          initialValue: mode,
          onSelected: (chosen) {
            ref.read(sbsViewModeProvider.notifier).state = chosen;
            if (!shown) {
              ref.read(sbsChosenPhotosProvider.notifier).update((chosenPhotos) => {...chosenPhotos, key});
            }
          },
          itemBuilder: (context) => [
            for (final item in SbsViewMode.values)
              CheckedPopupMenuItem(value: item, checked: item == mode, child: Text(sbsViewModeLabel(item, t))),
          ],
        ),
      ],
    );
  }
}
