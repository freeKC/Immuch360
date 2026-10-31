import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/video_details.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';

/// What the link of a video brings against what the video needs, while the video waits for it: "Loading: 1.2 Mbit/s
/// of the 3 Mbit/s this video needs", and "Starts in about 12 s" while the player waits for more than it has (see
/// VideoLinkView). Nothing while nothing is measured, and nothing once the link stopped sending (the failure panel or
/// the page says so).
class VideoLoadingLine extends StatelessWidget {
  const VideoLoadingLine({super.key, required this.link, this.color = Colors.white});

  final ValueListenable<VideoLinkView?> link;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoLinkView?>(
      valueListenable: link,
      builder: (context, view, _) {
        final text = videoLoadingText(view, context.t, locale: context.locale.toLanguageTag());
        if (text == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          key: const Key('video_loading_line'),
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, shadows: const [Shadow(blurRadius: 4)]),
          ),
        );
      },
    );
  }
}

/// The text of [VideoLoadingLine] for [view], null for none
String? videoLoadingText(VideoLinkView? view, Translations t, {required String locale}) {
  if (view == null || view.dead || !view.showsRates) {
    return null;
  }
  final rates = t.video_loading_rate(
    got: formatBitRate(view.bitsPerSecond!, t, locale: locale),
    need: formatBitRate(view.neededBitsPerSecond!, t, locale: locale),
  );
  final startsIn = view.startsIn;
  if (startsIn == null) {
    return rates;
  }
  return '$rates\n${t.video_loading_starts_in(seconds: '${(startsIn.inMilliseconds / 1000).ceil()}')}';
}
