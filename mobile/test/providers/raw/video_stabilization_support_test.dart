// Where the 360° player stabilises the raw videos with the motion track of their camera (issue 14): the Android player
// of the phones, tablets and TVs (lot c), the iOS player of the iPhones and iPads (lot d1) and the immersive viewer of
// the Meta Quest (lot d3); not yet the computers, whose setting and switch stay hidden.

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

    test('the Meta Quest stabilises in its immersive viewer', () {
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: true, isHorizonOs: true), isTrue);
    });

    test('not the computers', () {
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: false, isHorizonOs: null), isFalse);
      expect(videoStabilizationSupportedOn(isIOS: false, isAndroid: false, isHorizonOs: false), isFalse);
    });
  });
}
