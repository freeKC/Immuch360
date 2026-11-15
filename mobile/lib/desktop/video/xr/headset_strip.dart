// The status strip of the headset view (pc-vr-v1-plan.md, section 3.2): a band of 1024 x 160 pixels the plugin shows
// as an opaque quad under the video (0.9 x 0.14 m), drawn here with a Canvas and TextPainter in the app's fonts and
// language, no widget tree. Line 1: the title and the state; line 2: the position and duration, and while paused the
// hint for the controllers in hand; line 3: the text subtitle line, else what the headset must know (graphics memory
// nearly full, no controller bound). The lines follow the reading direction of the app's language (right to left for
// Arabic, Persian, Hebrew and Urdu), and the hint is never cut: it shrinks, wraps or scales down to keep its last words.
//
// It is drawn only when its text changes, at most 4 times a second, and sent as raw RGBA bytes; showing or hiding it
// sends no image. It shows while the video is paused, loading, ended or failed, for 4 s after any controller action or
// state change, in the dark room that waits for a video, and while a subtitle line shows.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/desktop/video/spherical_controls.dart' show formatPlayerTime;
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:intl/intl.dart' show Bidi;

const headsetStripWidth = 1024;
const headsetStripHeight = 160;

/// How long the strip stays after a controller action or a change of state
const headsetStripFlash = Duration(seconds: 4);

/// The shortest time between two images of the strip
const headsetStripInterval = Duration(milliseconds: 250);

/// Which hint the strip gives while paused, from the controllers' profile
enum HeadsetHint { stick, trackpad, simple, none }

/// The hint of [profile] (the interaction profile of a hand, as the plugin reports it); [HeadsetHint.none] when no
/// profile is bound, the window then being the only remote. The plugin's binding table (xr_input.cc) gives the simple
/// controller and the Vive wands their own gestures; every other profile has a stick.
HeadsetHint headsetHintOf(String profile, {required bool controllers}) {
  if (!controllers || profile.isEmpty) {
    return HeadsetHint.none;
  }
  return switch (profile) {
    '/interaction_profiles/khr/simple_controller' => HeadsetHint.simple,
    '/interaction_profiles/htc/vive_controller' => HeadsetHint.trackpad,
    _ => HeadsetHint.stick,
  };
}

/// The texts of the strip
@immutable
class HeadsetStripContent {
  const HeadsetStripContent({this.title = '', this.state = '', this.time = '', this.hint = '', this.line3 = ''});

  final String title;
  final String state;
  final String time;
  final String hint;
  final String line3;

  @override
  bool operator ==(Object other) =>
      other is HeadsetStripContent &&
      other.title == title &&
      other.state == state &&
      other.time == time &&
      other.hint == hint &&
      other.line3 == line3;

  @override
  int get hashCode => Object.hash(title, state, time, hint, line3);

  @override
  String toString() => 'HeadsetStripContent($title | $state | $time | $hint | $line3)';
}

/// The texts of the strip for what the view shows now. [idle]: no player, the dark room waiting for a video.
HeadsetStripContent headsetStripContentOf(
  Translations t, {
  required bool idle,
  String title = '',
  HeadsetPlayback playback = const HeadsetPlayback(),
  HeadsetHint hint = HeadsetHint.none,
  bool memoryTight = false,
  String subtitle = '',
}) {
  final notice = memoryTight
      ? t.headset_strip_memory
      : hint == HeadsetHint.none
      ? t.headset_strip_no_controller
      : '';
  if (idle) {
    return HeadsetStripContent(title: t.headset_strip_pick_video, line3: notice);
  }
  final state = switch (playback.status) {
    HeadsetPlaybackStatus.playing => t.headset_strip_playing,
    HeadsetPlaybackStatus.paused => t.headset_strip_paused,
    HeadsetPlaybackStatus.buffering => t.headset_strip_buffering,
    HeadsetPlaybackStatus.ended => t.headset_strip_ended,
    HeadsetPlaybackStatus.failed => '',
  };
  final paused = playback.status == HeadsetPlaybackStatus.paused || playback.status == HeadsetPlaybackStatus.ended;
  return HeadsetStripContent(
    title: title,
    state: state,
    time: '${formatPlayerTime(playback.position)} / ${formatPlayerTime(playback.duration)}',
    hint: paused
        ? switch (hint) {
            HeadsetHint.stick => t.headset_strip_hint_stick,
            HeadsetHint.trackpad => t.headset_strip_hint_trackpad,
            HeadsetHint.simple => t.headset_strip_hint_simple,
            HeadsetHint.none => '',
          }
        : '',
    line3: subtitle.isNotEmpty ? subtitle : notice,
  );
}

/// Whether the strip shows, see the top of this file. [sinceFlash]: the time since the last controller action or
/// change of state, null for none yet.
bool headsetStripVisible({
  required bool idle,
  required HeadsetPlaybackStatus status,
  String subtitle = '',
  Duration? sinceFlash,
}) =>
    idle ||
    status != HeadsetPlaybackStatus.playing ||
    subtitle.isNotEmpty ||
    (sinceFlash != null && sinceFlash < headsetStripFlash);

/// The direction of the strip's words for [locale]: right to left for Arabic, Persian, Hebrew, Urdu and the other
/// languages written that way, as the app's own pages
TextDirection headsetStripDirectionOf(ui.Locale? locale) =>
    locale != null && Bidi.isRtlLanguage(locale.toLanguageTag()) ? TextDirection.rtl : TextDirection.ltr;

/// The size of the hint's letters when it fits, and the smallest size it shrinks to before it is scaled down whole
const headsetHintSize = 20.0;
const headsetHintSmallest = 12.0;

/// The band of line 2 the hint may fill, from under the title to above line 3
const _hintTop = 56.0;
const _hintBottom = 104.0;
const _margin = 24.0;

/// A text of the strip where it is drawn, [scale] below 1 for a hint too long for its place even at its smallest size
@immutable
class HeadsetStripText {
  const HeadsetStripText(this.painter, this.offset, {this.scale = 1});

  final TextPainter painter;
  final Offset offset;
  final double scale;

  double get width => painter.width * scale;
  double get height => painter.height * scale;
  Rect get rect => offset & Size(width, height);

  /// Whether the whole text is drawn: no line beyond the painter's maximum, no ellipsis
  bool get whole => !painter.didExceedMaxLines;

  void paint(Canvas canvas) {
    if (scale == 1) {
      painter.paint(canvas, offset);
      return;
    }
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..scale(scale);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }
}

/// Where the texts of the strip go
@immutable
class HeadsetStripLayout {
  const HeadsetStripLayout({required this.title, required this.state, required this.time, this.hint, this.line3});

  final HeadsetStripText title;
  final HeadsetStripText state;
  final HeadsetStripText time;
  final HeadsetStripText? hint;
  final HeadsetStripText? line3;

  /// The place left to the hint on line 2, beside the time
  double get hintRoom => headsetStripWidth - 3 * _margin - time.width;

  void paint(Canvas canvas) {
    for (final text in [title, state, time, hint, line3]) {
      text?.paint(canvas);
    }
  }
}

/// Lays [content] out on the strip, in the reading order of [direction]: the title at the start of line 1 and the
/// state at its end, the time at the start of line 2 and the hint after it, line 3 at the start. The hint is never cut:
/// it takes one or two lines and shrinks from [headsetHintSize] to [headsetHintSmallest] until it fits, and a hint
/// still too long is drawn whole, scaled down, so that its last words (how to leave the view) always show.
HeadsetStripLayout layoutHeadsetStrip(
  HeadsetStripContent content, {
  String? fontFamily,
  TextDirection direction = TextDirection.ltr,
}) {
  const width = headsetStripWidth;
  final rtl = direction == TextDirection.rtl;
  // The left edge of a text [extent] wide that starts [start] from the edge where the line begins
  double x(double start, double extent) => rtl ? width - start - extent : start;

  TextPainter painter(
    String text,
    double size, {
    Color color = const Color(0xFFF2F2F2),
    FontWeight? weight,
    int? maxLines = 1,
    TextDirection? textDirection,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: size,
        color: color,
        fontWeight: weight,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    ),
    textDirection: textDirection ?? direction,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
    textWidthBasis: TextWidthBasis.longestLine,
  );

  // Line 1: the state at the end, the title in what is left
  final state = painter(content.state, 34, color: const Color(0xFF9FD3FF), weight: FontWeight.w600)..layout();
  final titleRoom = width - 2 * _margin - (content.state.isEmpty ? 0 : state.width + _margin);
  final title = painter(content.title, 34, weight: FontWeight.w600)..layout(maxWidth: titleRoom < 0 ? 0 : titleRoom);

  // Line 2: the time (its figures always left to right), then the hint in what is left
  final time = painter(content.time, 28, textDirection: TextDirection.ltr)..layout();
  final timeText = HeadsetStripText(time, Offset(x(_margin, time.width), 60));
  HeadsetStripText? hint;
  if (content.hint.isNotEmpty) {
    final room = math.max(0.0, width - 3 * _margin - time.width);
    const band = _hintBottom - _hintTop;
    final timeMiddle = 60 + time.height / 2;
    HeadsetStripText place(TextPainter fitted, double scale) {
      final extent = fitted.width * scale;
      final height = fitted.height * scale;
      final top = (timeMiddle - height / 2).clamp(_hintTop, math.max(_hintTop, _hintBottom - height)).toDouble();
      return HeadsetStripText(fitted, Offset(x(2 * _margin + time.width, extent), top), scale: scale);
    }

    TextPainter hintPainter(double size, {int? maxLines = 2}) =>
        painter(content.hint, size, color: const Color(0xFFC8C8C8), maxLines: maxLines);

    for (var size = headsetHintSize; size >= headsetHintSmallest && hint == null; size--) {
      final fitted = hintPainter(size)..layout(maxWidth: room);
      if (!fitted.didExceedMaxLines && fitted.height <= band) {
        hint = place(fitted, 1);
      }
    }
    if (hint == null) {
      // Too long even at the smallest size: two lines laid out wider, then the whole scaled down to the room
      for (var scale = 0.95; scale > 0.3 && hint == null; scale -= 0.05) {
        final fitted = hintPainter(headsetHintSmallest)..layout(maxWidth: room / scale);
        if (!fitted.didExceedMaxLines && fitted.height * scale <= band && fitted.width * scale <= room) {
          hint = place(fitted, scale);
        }
      }
    }
    if (hint == null) {
      final fitted = hintPainter(headsetHintSmallest, maxLines: null)..layout();
      final scale = math.min(1.0, math.min(room / math.max(1.0, fitted.width), band / math.max(1.0, fitted.height)));
      hint = place(fitted, scale);
    }
  }

  // Line 3: the subtitle line, or what the headset must know
  HeadsetStripText? line3;
  if (content.line3.isNotEmpty) {
    final line = painter(content.line3, 30, color: const Color(0xFFFFF3B0))..layout(maxWidth: width - 2 * _margin);
    line3 = HeadsetStripText(line, Offset(x(_margin, line.width), 106));
  }

  return HeadsetStripLayout(
    title: HeadsetStripText(title, Offset(x(_margin, title.width), 10)),
    state: HeadsetStripText(state, Offset(x(width - _margin - state.width, state.width), 10)),
    time: timeText,
    hint: hint,
    line3: line3,
  );
}

/// Draws [content] into the RGBA bytes of a 1024 x 160 image, the first row on top, see [layoutHeadsetStrip]
Future<Uint8List> renderHeadsetStrip(
  HeadsetStripContent content, {
  String? fontFamily,
  TextDirection direction = TextDirection.ltr,
}) async {
  const width = headsetStripWidth;
  const height = headsetStripHeight;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  // Opaque: the runtime composes the quad without its alpha
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFF15171C));
  layoutHeadsetStrip(content, fontFamily: fontFamily, direction: direction).paint(canvas);

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// Sends the strip to the headset: an image only when the text changed, at most one each [interval] (the newest text
/// waits for its turn), and the visibility alone, with no image, when only that changed
class HeadsetStripSender {
  HeadsetStripSender({
    required this.render,
    required this.send,
    DateTime Function()? now,
    this.interval = headsetStripInterval,
  }) : _now = now ?? DateTime.now;

  final Future<Uint8List> Function(HeadsetStripContent content) render;
  final Future<void> Function(Uint8List rgba, int width, int height, {required bool visible}) send;
  final Duration interval;
  final DateTime Function() _now;

  HeadsetStripContent? _sent;
  bool? _sentVisible;
  HeadsetStripContent? _wanted;
  bool _wantedVisible = false;
  DateTime? _renderedAt;
  Timer? _later;
  bool _busy = false;
  bool _disposed = false;

  /// Images sent, for the tests
  @visibleForTesting
  int images = 0;

  /// What the strip should show now
  void update(HeadsetStripContent content, {required bool visible}) {
    if (_disposed) {
      return;
    }
    _wanted = content;
    _wantedVisible = visible;
    unawaited(_pump());
  }

  /// A new view: the next update sends its image whatever was sent before
  void reset() {
    _later?.cancel();
    _later = null;
    _sent = null;
    _sentVisible = null;
    _renderedAt = null;
  }

  Future<void> _pump() async {
    if (_busy || _disposed) {
      return;
    }
    final wanted = _wanted;
    if (wanted == null) {
      return;
    }
    if (wanted != _sent) {
      final renderedAt = _renderedAt;
      final now = _now();
      if (renderedAt != null && now.difference(renderedAt) < interval) {
        _later ??= Timer(interval - now.difference(renderedAt), () {
          _later = null;
          unawaited(_pump());
        });
        return;
      }
      _busy = true;
      try {
        _renderedAt = now;
        final bytes = await render(wanted);
        if (_disposed) {
          return;
        }
        final visible = _wantedVisible;
        await send(bytes, headsetStripWidth, headsetStripHeight, visible: visible);
        images++;
        _sent = wanted;
        _sentVisible = visible;
      } catch (error) {
        headsetViewLog.fine('The strip was not sent: $error');
      } finally {
        _busy = false;
      }
      // What came while it was drawn
      if (_wanted != _sent || _wantedVisible != _sentVisible) {
        unawaited(_pump());
      }
      return;
    }
    if (_wantedVisible != _sentVisible) {
      final visible = _wantedVisible;
      _sentVisible = visible;
      try {
        await send(Uint8List(0), 0, 0, visible: visible);
      } catch (error) {
        headsetViewLog.fine('The strip was not shown or hidden: $error');
      }
    }
  }

  void dispose() {
    _disposed = true;
    _later?.cancel();
  }
}
