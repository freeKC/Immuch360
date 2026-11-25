// "Compare" of an enhanced photo (release 51): the original and the enhanced photo one over the other, the original on
// the left of a divider and the enhanced photo on its right, the divider moved by its slider, by a drag on the picture
// or by the keys Left and Right (5 percent a press). Both have the same size, so the same pixels meet at the divider.
// "100 %" shows the pixels one to one (the gain is seen at full size), "Fit" the whole picture. The wheel, a trackpad,
// a double click and the keys + - 0 1 zoom as in the viewers (lib/desktop/window/desktop_photo_zoom.dart, release
// 53); zoomed in, a drag moves the picture rather than the divider, and Escape shows it whole first. Escape then closes
// it as any dialog: the other keys go on to the shell (lot feat-desktop-escape-51).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Opens the comparison of [enhancedPath] with [originalPath]
Future<void> showEnhanceCompare(BuildContext context, {required String originalPath, required String enhancedPath}) =>
    showDialog<void>(
      context: context,
      builder: (context) => EnhanceCompareDialog(originalPath: originalPath, enhancedPath: enhancedPath),
    );

/// See the top of this file
class EnhanceCompareDialog extends StatefulWidget {
  const EnhanceCompareDialog({super.key, required this.originalPath, required this.enhancedPath});

  final String originalPath;
  final String enhancedPath;

  @override
  State<EnhanceCompareDialog> createState() => _EnhanceCompareDialogState();
}

class _EnhanceCompareDialogState extends State<EnhanceCompareDialog> {
  /// Where the divider is, 0 (all enhanced) to 1 (all original)
  var _divider = 0.5;
  final _focus = FocusNode(debugLabel: 'enhance-compare');
  final _zoom = DesktopZoomController();
  var _zoomed = false;

  /// The pixels of the pictures (both have the same), once the original is decoded
  Size? _pixels;
  ImageStream? _pixelStream;
  late final _pixelListener = ImageStreamListener(_onPixels, onError: (_, _) {});

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The same provider as the picture shown: no second decode
    _pixelStream ??= FileImage(File(widget.originalPath)).resolve(createLocalImageConfiguration(context))
      ..addListener(_pixelListener);
  }

  void _onPixels(ImageInfo info, bool _) {
    final pixels = Size(info.image.width.toDouble(), info.image.height.toDouble());
    info.dispose();
    if (mounted && pixels != _pixels) {
      setState(() => _pixels = pixels);
    }
  }

  void _onZoom() {
    final zoomed = desktopZoomed(_zoom);
    if (zoomed != _zoomed && mounted) {
      setState(() => _zoomed = zoomed);
    }
  }

  @override
  void dispose() {
    _pixelStream?.removeListener(_pixelListener);
    _zoom.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggleSize() {
    final animate = !desktopReducedMotion(context);
    _zoomed ? desktopZoomFit(_zoom, animate: animate) : desktopZoomOneToOne(_zoom, animate: animate);
  }

  void _move(double by) => setState(() => _divider = (_divider + by).clamp(0.0, 1.0));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _move(-0.05);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _move(0.05);
      return KeyEventResult.handled;
    }
    // The zoom keys; the arrows stay the divider's
    final zoomKey = desktopZoomKeyOf(event);
    if (zoomKey != null &&
        !isDesktopZoomArrow(zoomKey) &&
        desktopZoomApplyKey(_zoom, zoomKey, animate: !desktopReducedMotion(context))) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final size = MediaQuery.sizeOf(context);
    final pictures = DesktopZoomView(
      controller: _zoom,
      pixelSize: _pixels,
      child: _Wipe(
        original: File(widget.originalPath),
        enhanced: File(widget.enhancedPath),
        divider: _divider,
        // Zoomed in, a drag moves the picture
        onDrag: _zoomed ? null : (fraction) => setState(() => _divider = fraction.clamp(0.0, 1.0)),
      ),
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        key: const Key('ai_enhance_compare'),
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: size.width * 0.9,
          height: size.height * 0.9,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(t.ai_enhance_compare_title, style: context.textTheme.titleMedium)),
                    TextButton(
                      key: const Key('ai_enhance_compare_size'),
                      // Once the pixels are known; nothing for a picture whose pixels are smaller than the window
                      onPressed: _zoomed || _pixels != null ? _toggleSize : null,
                      child: Text(_zoomed ? t.ai_enhance_fit : t.ai_enhance_actual_size),
                    ),
                    IconButton(
                      key: const Key('ai_enhance_compare_close'),
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close),
                      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    ),
                  ],
                ),
              ),
              Expanded(child: ClipRect(child: pictures)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Text(t.ai_enhance_before),
                    Expanded(
                      child: Slider(
                        key: const Key('ai_enhance_compare_slider'),
                        value: 1 - _divider,
                        onChanged: (value) => setState(() => _divider = 1 - value),
                      ),
                    ),
                    Text(t.ai_enhance_after),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${t.ai_enhance_compare_keys} ${t.desktop_zoom_hint}',
                  style: context.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two pictures, the original clipped to the left of the divider over the enhanced one
class _Wipe extends StatelessWidget {
  const _Wipe({required this.original, required this.enhanced, required this.divider, required this.onDrag});

  final File original;
  final File enhanced;
  final double divider;

  /// Null while the picture is zoomed in: the drag moves it then
  final ValueChanged<double>? onDrag;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : null;
        Widget picture(File file, Key key) =>
            Image.file(file, key: key, fit: BoxFit.contain, filterQuality: FilterQuality.none, gaplessPlayback: true);
        final content = Stack(
          fit: width == null ? StackFit.loose : StackFit.expand,
          children: [
            picture(enhanced, const Key('ai_enhance_compare_after')),
            ClipRect(clipper: _LeftOf(divider), child: picture(original, const Key('ai_enhance_compare_before'))),
            Positioned.fill(
              child: Align(
                alignment: Alignment(divider * 2 - 1, 0),
                child: Container(width: 2, color: colors.primary),
              ),
            ),
          ],
        );
        return GestureDetector(
          key: const Key('ai_enhance_compare_area'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: width == null || onDrag == null
              ? null
              : (details) => onDrag!(details.localPosition.dx / width),
          onTapDown: width == null || onDrag == null ? null : (details) => onDrag!(details.localPosition.dx / width),
          child: content,
        );
      },
    );
  }
}

/// The part of a box left of [fraction] of its width
class _LeftOf extends CustomClipper<Rect> {
  const _LeftOf(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftOf oldClipper) => oldClipper.fraction != fraction;
}
