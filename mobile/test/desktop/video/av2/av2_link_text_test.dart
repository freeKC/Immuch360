// The link of an AV2 video is its decoder (plan of the AV2 videos, section 1.4): "Decoding: 18 of the 24 frames per
// second this video needs" in place of the rates of a network, from what NativeVideoLink and VideoLinkView carry.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_loading_line.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../ai/creator/english_texts.dart';

void main() {
  setUpAll(loadEnglishTexts);

  test('a decoder link: its ratio is the frames it decodes over those the video needs, null until measured', () {
    const link = NativeVideoLink(waiting: true, framesPerSecond: 18, neededFramesPerSecond: 24);
    expect(link.isDecoder, isTrue);
    expect(link.ratio, 0.75);
    expect(const NativeVideoLink(waiting: true, neededFramesPerSecond: 24).ratio, isNull);
    expect(const NativeVideoLink(waiting: true, bytesPerSecond: 500, neededBytesPerSecond: 1000).isDecoder, isFalse);
    expect(link, const NativeVideoLink(waiting: true, framesPerSecond: 18, neededFramesPerSecond: 24));
    expect(link == const NativeVideoLink(waiting: true, framesPerSecond: 19, neededFramesPerSecond: 24), isFalse);
  });

  test('the loading line says the frames of the decoder while the video waits', () {
    final t = StaticTranslations.instance;
    const view = VideoLinkView(
      waiting: true,
      framesPerSecond: 17.6,
      neededFramesPerSecond: 23.976,
      waitedFor: Duration(seconds: 3),
      startsIn: Duration(seconds: 12),
    );
    expect(view.ratio, closeTo(0.73, 0.01));
    expect(
      videoLoadingText(view, t, locale: 'en'),
      'Decoding: 18 of the 24 frames per second this video needs\nStarts in about 12 s',
    );
    expect(
      videoLoadingText(
        const VideoLinkView(waiting: true, bitsPerSecond: 1000000, neededBitsPerSecond: 3000000),
        t,
        locale: 'en',
      ),
      'Loading: 1 Mbit/s of the 3 Mbit/s this video needs',
      reason: 'a network as before',
    );
    expect(videoLoadingText(const VideoLinkView(waiting: true, neededFramesPerSecond: 24), t, locale: 'en'), isNull);
  });

  test('a language intl has no numbers for (mi, kab, kxm, lmo, swg) gets the digits of English', () {
    final t = StaticTranslations.instance;
    const view = VideoLinkView(waiting: true, framesPerSecond: 1200, neededFramesPerSecond: 2400);
    for (final locale in ['mi', 'kab', 'kxm', 'lmo', 'swg']) {
      expect(
        videoLoadingText(view, t, locale: locale),
        'Decoding: 1,200 of the 2,400 frames per second this video needs',
        reason: locale,
      );
    }
  });
}
