// The errors of the native players in the words of the app (PlaybackErrors.kt sends the token): read back here, so
// that the text of Media3 never reaches the screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/native_playback_error.dart';

void main() {
  test('reads the kind, the codec and the frame of the token of the flat player', () {
    final error = NativePlaybackError.parse('immuch360-playback-error:noFrame:video/avc:5760:2880');

    expect(error?.kind, NativePlaybackErrorKind.noFrame);
    expect(error?.codec, 'H.264');
    expect(error?.width, 5760);
    expect(error?.height, 2880);
  });

  test('reads every kind, a codec and a frame that are unknown', () {
    expect(NativePlaybackError.parse('immuch360-playback-error:decoder:video/hevc:7680:3840')?.codec, 'HEVC');
    expect(NativePlaybackError.parse('immuch360-playback-error:stalled::0:0')?.kind, NativePlaybackErrorKind.stalled);
    final stopped = NativePlaybackError.parse('immuch360-playback-error:stopped::0:0');
    expect(stopped?.kind, NativePlaybackErrorKind.stopped);
    expect(stopped?.codec, isNull);
    expect(stopped?.width, 0);
  });

  test('takes any other text for what it is, and a token of a kind it does not know for nothing', () {
    expect(NativePlaybackError.parse('Player stuck playing with no progress for 10000 ms'), isNull);
    expect(NativePlaybackError.parse('Decoder init failed: c2.android.avc.decoder'), isNull);
    expect(NativePlaybackError.parse(null), isNull);
    expect(NativePlaybackError.parse('immuch360-playback-error:later:video/avc:1:1'), isNull);
  });

  test('knows the text of the stuck checks of Media3, should one come through another player', () {
    expect(isMedia3StuckText('Player stuck playing with no progress for 10000 ms'), isTrue);
    expect(isMedia3StuckText('Player stuck buffering and not loading for 600000 ms'), isTrue);
    expect(isMedia3StuckText('Source error'), isFalse);
  });
}
