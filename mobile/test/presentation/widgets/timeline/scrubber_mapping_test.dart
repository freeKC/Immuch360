// The scrubber: the year and month under the finger ("Oct 2024", the year alone on the years), and the slow mode of a
// finger held still on the thumb, some 16 dp of finger a month, only for a library that does not fit already.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';

void main() {
  group('the label', () {
    test('the month and the year, the year alone on the years', () {
      final date = DateTime(2024, 10, 17);
      expect(scrubberLabelFormat(years: false).format(date), 'Oct 2024');
      expect(scrubberLabelFormat(years: true).format(date), '2024');
    });
  });

  group('the slow factor', () {
    test('some 16 dp of finger a month', () {
      // 240 months on a scrubber of 600 dp: 2.5 dp a month, 6.4 times slower gives 16
      expect(scrubberSlowFactor(monthCount: 240, scrubberHeight: 600), closeTo(6.4, 1e-9));
      expect(scrubberSlowFactor(monthCount: 100, scrubberHeight: 400), closeTo(4, 1e-9));
    });

    test('at most 16 times, never faster than the thumb', () {
      expect(scrubberSlowFactor(monthCount: 1200, scrubberHeight: 500), kScrubberMaxSlowFactor);
      expect(scrubberSlowFactor(monthCount: 10, scrubberHeight: 600), 1);
      expect(scrubberSlowFactor(monthCount: 0, scrubberHeight: 600), 1);
      expect(scrubberSlowFactor(monthCount: 50, scrubberHeight: 0), 1);
    });

    test('no slow mode under 2 times: the library fits already', () {
      expect(scrubberHasSlowMode(scrubberSlowFactor(monthCount: 60, scrubberHeight: 600)), isFalse, reason: '1.6');
      expect(scrubberHasSlowMode(scrubberSlowFactor(monthCount: 75, scrubberHeight: 600)), isTrue, reason: '2.0');
      expect(scrubberHasSlowMode(6.4), isTrue);
    });
  });

  group('the slow position', () {
    test('the move of the finger divided by the factor, from where the mode began', () {
      expect(
        scrubberSlowPosition(anchor: 300, anchorFinger: 500, finger: 600, factor: 4, scrubberHeight: 600),
        closeTo(325, 1e-9),
      );
      expect(
        scrubberSlowPosition(anchor: 300, anchorFinger: 500, finger: 420, factor: 8, scrubberHeight: 600),
        closeTo(290, 1e-9),
      );
    });

    test('kept on the scrubber', () {
      expect(scrubberSlowPosition(anchor: 590, anchorFinger: 0, finger: 400, factor: 2, scrubberHeight: 600), 600);
      expect(scrubberSlowPosition(anchor: 5, anchorFinger: 400, finger: 0, factor: 2, scrubberHeight: 600), 0);
    });

    test('a factor under 1 counts as 1', () {
      expect(scrubberSlowPosition(anchor: 100, anchorFinger: 0, finger: 50, factor: 0, scrubberHeight: 600), 150);
    });
  });
}
