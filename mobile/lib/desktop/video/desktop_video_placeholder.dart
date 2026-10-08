import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Stands where the native video player of the phones would be, until the desktop player exists: the poster or the
/// thumbnail stays visible behind it, with a line saying that playback comes later
class DesktopVideoPlaceholder extends StatelessWidget {
  const DesktopVideoPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.all(Radius.circular(12))),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined, color: Colors.white70),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                context.t.desktop_video_later,
                style: context.textTheme.bodyMedium?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
