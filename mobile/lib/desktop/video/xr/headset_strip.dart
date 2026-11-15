// The status strip of the headset view (pc-vr-v1-plan.md, section 3.2): a band of 1024 x 160 pixels the plugin shows
// as an opaque quad under the video (0.9 x 0.14 m), drawn here with a Canvas and TextPainter in the app's fonts and
// language, no widget tree. Line 1: the title and the state; line 2: the position and duration, and while paused the
// hint for the controllers in hand; line 3: the text subtitle line, else what the headset must know (graphics memory
// nearly full, no controller bound).
//
// It is drawn only when its text changes, at most 4 times a second, and sent as raw RGBA bytes; showing or hiding it
// sends no image. It shows while the video is paused, loading, ended or failed, for 4 s after any controller action or
// state change, in the dark room that waits for a video, and while a subtitle line shows.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/desktop/video/spherical_controls.dart' show formatPlayerTime;
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/generated/translations.g.dart';

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

/// Draws [content] into the RGBA bytes of a 1024 x 160 image, the first row on top
Future<Uint8List> renderHeadsetStrip(HeadsetStripContent content, {String? fontFamily}) async {
  const width = headsetStripWidth;
  const height = headsetStripHeight;
  const margin = 24.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  // Opaque: the runtime composes the quad without its alpha
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFF15171C));

  TextPainter painter(String text, double size, {Color color = const Color(0xFFF2F2F2), FontWeight? weight}) =>
      TextPainter(
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
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      );

  // Line 1: the state on the right, the title in what is left
  final state = painter(content.state, 34, color: const Color(0xFF9FD3FF), weight: FontWeight.w600)..layout();
  final titleWidth = width - 2 * margin - (content.state.isEmpty ? 0 : state.width + margin);
  final title = painter(content.title, 34, weight: FontWeight.w600)..layout(maxWidth: titleWidth < 0 ? 0 : titleWidth);
  title.paint(canvas, const Offset(margin, 10));
  state.paint(canvas, Offset(width - margin - state.width, 10));

  // Line 2: the time, then the hint in what is left
  final time = painter(content.time, 28)..layout();
  time.paint(canvas, const Offset(margin, 60));
  if (content.hint.isNotEmpty) {
    final hintWidth = width - 3 * margin - time.width;
    final hint = painter(content.hint, 20, color: const Color(0xFFC8C8C8))
      ..layout(maxWidth: hintWidth < 0 ? 0 : hintWidth);
    hint.paint(canvas, Offset(2 * margin + time.width, 60 + (time.height - hint.height) / 2));
  }

  // Line 3: the subtitle line, or what the headset must know
  if (content.line3.isNotEmpty) {
    final line = painter(content.line3, 30, color: const Color(0xFFFFF3B0))..layout(maxWidth: width - 2 * margin);
    line.paint(canvas, const Offset(margin, 106));
  }

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
