// Where the 360° player stabilises the raw videos with the motion track of their camera (issue 14): the Android player
// of the phones, tablets and TVs (lot c) and the iOS player of the iPhones and iPads (lot d1); not yet the immersive
// viewer of the Meta Quest nor the computers, whose setting and switch stay hidden.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';

void main() {
  group('videoStabilizationSupportedOn', () {
    test('the iPhones and iPads stabilise in their Metal stitch', () {
      expect(videoStabilizationSupportedOn(isIOS: true, isAndroid: false, isHorizonOs: null), isTrue);
      expect(videoStabilizationSupportedOn(isIOS: true, isAndroid: false, isHorizonOs: false), isTrue);
    });

    test('the Android phones, tablets and TVs stabilise, once the device is known not to be a Quest', () {
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: true, isHorizonOs: false), isTrue);
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: true, isHorizonOs: null), isFalse);
    });

    test('not the Meta Quest yet, nor the computers', () {
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: true, isHorizonOs: true), isFalse);
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: false, isHorizonOs: null), isFalse);
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: false, isHorizonOs: false), isFalse);
    });
  });
}
