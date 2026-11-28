// The two finger gestures of a computer's touchpad as each system sends them to Flutter (28 November 2026), for the
// tests of the pinch in every viewer of the desktop app. One pan and zoom sequence: a start at the pointer, reports of
// the pan and the scale since the start, an end.
//
// - Windows, a precision touchpad (DirectManipulation, flutter engine 3.47 direct_manipulation.cc): the pan is the
//   translation of the content DirectManipulation scales around a point, sent unchanged, so a pinch comes with a pan
//   of about that point times (1 - scale) ([windowsPinch]); real fingers start slowly, or at once ([fastWindowsPinch]).
// - macOS (FlutterViewController.mm): the scale of the magnify events, with the small pan of the fingers that drift
//   ([macPinch]).
// - Linux (GTK zoom gesture, fl_scrolling_manager.cc): the scale alone, no pan ([linuxPinch]).
// - Every system: a two finger scroll is a pan with a scale of exactly 1 ([scroll]).

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// One report: the pan and the scale since the start, logical pixels
typedef PanZoomStep = ({Offset pan, double scale});

/// The scale of real fingers going to [to]: barely moving for the first reports, then evenly
List<double> fingerScales(double to, {int steps = 30}) {
  const early = [1.0, 1.002, 1.006, 1.012];
  final from = early.last;
  return [
    ...early,
    for (var i = 1; i <= steps - early.length; i++) from * math.pow(to / from, i / (steps - early.length)).toDouble(),
  ];
}

/// A pinch to [to] on Windows, DirectManipulation scaling its content around [anchor] (window coordinates, logical),
/// the fingers' middle drifting by [drift] in all
List<PanZoomStep> windowsPinch(double to, Offset anchor, {Offset drift = Offset.zero}) {
  final scales = fingerScales(to);
  return [
    for (var i = 0; i < scales.length; i++)
      (pan: anchor * (1 - scales[i]) + drift * (i / (scales.length - 1)), scale: scales[i]),
  ];
}

/// The same with fast fingers: the first report already 4 % of zoom, with its pan of the anchor
List<PanZoomStep> fastWindowsPinch(double to, Offset anchor) {
  final scales = [1.04, for (var i = 1; i <= 10; i++) 1.04 * math.pow(to / 1.04, i / 10).toDouble()];
  return [for (final scale in scales) (pan: anchor * (1 - scale), scale: scale)];
}

/// A pinch to [to] on macOS: the fingers' middle drifts by [drift] in all
List<PanZoomStep> macPinch(double to, {Offset drift = const Offset(3, 6)}) {
  final scales = fingerScales(to);
  return [for (var i = 0; i < scales.length; i++) (pan: drift * (i / (scales.length - 1)), scale: scales[i])];
}

/// A pinch to [to] on Linux: the scale alone
List<PanZoomStep> linuxPinch(double to) => [for (final scale in fingerScales(to)) (pan: Offset.zero, scale: scale)];

/// Two fingers that scroll by [by] in all, in [steps] reports
List<PanZoomStep> scroll(Offset by, {int steps = 20}) => [
  for (var i = 1; i <= steps; i++) (pan: by * (i / steps), scale: 1.0),
];

var _pointer = 900;

/// Sends one sequence started at [at] (window coordinates), a frame between reports as the engines send them
Future<void> sendPanZoom(WidgetTester tester, Offset at, List<PanZoomStep> steps) async {
  final pad = TestPointer(_pointer++, PointerDeviceKind.trackpad);
  var time = Duration.zero;
  await tester.sendEventToBinding(pad.panZoomStart(at, timeStamp: time));
  for (final step in steps) {
    time += const Duration(milliseconds: 8);
    await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: step.pan, scale: step.scale, timeStamp: time));
    await tester.pump(const Duration(milliseconds: 8));
  }
  await tester.sendEventToBinding(pad.panZoomEnd(timeStamp: time + const Duration(milliseconds: 8)));
  await tester.pump();
}
