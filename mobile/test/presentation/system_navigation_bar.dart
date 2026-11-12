// A phone whose system navigation bar covers the bottom of the screen, as the three button bar of an Android phone
// drawn edge to edge (a Galaxy S24 of 10 November 2026: 180 of its 3120 pixels), for the tests that keep the last row
// of a sheet or a page above it

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The height of the bar, in logical pixels
const navigationBarHeight = 48.0;

/// A screen of [size] physical pixels with the bar at its bottom: the padding and the view padding of the view, which
/// the app's MediaQuery and every route read
void screenWithNavigationBar(WidgetTester tester, {Size size = const Size(1080, 2400), double ratio = 2.7}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = ratio
    ..padding = FakeViewPadding(bottom: navigationBarHeight * ratio)
    ..viewPadding = FakeViewPadding(bottom: navigationBarHeight * ratio);
  addTearDown(tester.view.reset);
}

/// The keyboard up: the bar stays in the view padding, the padding gives it up, as the engine reports it
void showKeyboard(WidgetTester tester, double height) {
  final ratio = tester.view.devicePixelRatio;
  tester.view
    ..viewInsets = FakeViewPadding(bottom: height * ratio)
    ..padding = FakeViewPadding.zero;
}

/// The bottom edge of the screen, in logical pixels
double screenBottom(WidgetTester tester) => tester.view.physicalSize.height / tester.view.devicePixelRatio;

/// [finder] ends above the bar
void expectAboveNavigationBar(WidgetTester tester, Finder finder) {
  expect(
    tester.getRect(finder).bottom,
    lessThanOrEqualTo(screenBottom(tester) - navigationBarHeight),
    reason: 'under the navigation bar',
  );
}

/// Scrolls [scrollable] to its end, once it is sure the list is longer than the screen
Future<void> scrollToEnd(WidgetTester tester, Finder scrollable) async {
  final position = tester.state<ScrollableState>(scrollable).position;
  expect(position.maxScrollExtent, greaterThan(0), reason: 'the list must be longer than the screen');
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}
