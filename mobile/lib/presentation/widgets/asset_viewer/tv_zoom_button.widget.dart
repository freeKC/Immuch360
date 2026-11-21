import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_photo_zoom.dart';

/// Zoom in, in the bottom bar of a TV, on the right of Rotate: most remotes have no zoom key, and none a pinch. Each
/// press zooms the photo on screen by one step (TvPhotoZoomIntent, which the asset viewer takes); then the arrows move
/// the photo and Back shows it whole (see tv_photo_zoom.dart). Like Rotate, never where OK from the photo lands, so that
/// a double OK still shows and hides the controls.
class TvZoomInButton extends StatelessWidget {
  const TvZoomInButton({super.key});

  @override
  Widget build(BuildContext context) {
    // Round and as small as the OCR toggle: the row of a TV keeps its buttons on the right of the screen, so that Right
    // from the OCR toggle reaches Rotate rather than the photo under them
    return Padding(
      padding: const EdgeInsets.only(right: 32, bottom: 8),
      // A node of its own for TalkBack, never merged with the date and time on the left of the row
      child: Semantics(
        container: true,
        button: true,
        label: context.t.tv_zoom_in,
        excludeSemantics: true,
        child: Material(
          key: const Key('tv_zoom_in_button'),
          color: Colors.black.withValues(alpha: 0.4),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Actions.maybeInvoke(context, const TvPhotoZoomIntent(zoomIn: true)),
            child: const Padding(
              padding: EdgeInsets.all(10.0),
              child: Icon(Icons.zoom_in_rounded, size: 22, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [node] is the focus of a [TvZoomInButton], where OK from the photo never lands (see AssetViewer)
bool isTvZoomFocus(FocusNode node) => node.context?.findAncestorWidgetOfExactType<TvZoomInButton>() != null;
