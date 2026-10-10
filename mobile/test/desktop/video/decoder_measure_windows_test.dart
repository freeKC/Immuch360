// The decoder measure of decoder_measure.dart on a real libmpv player of the Windows build: the mpv properties the
// sampler reads exist in the shipped libmpv and give a measure of the codec, size, rate, decoder and drops of a clip.
// It plays through the frame grabber's kind of player, which decodes without a texture, so that no window is needed;
// that player copies hardware frames back to memory (auto-copy-safe), which the measure then names.
// Windows only, after a Windows build of the app, with clips of this computer (never in the repository) named by
// IMMUCH360_DECODE_CLIPS, separated by ";":
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/decoder_measure_windows_test.dart
// IMMUCH360_BUILD_DIR may name another folder holding libmpv-2.dll.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// The folder of the Windows build that holds libmpv, null when there is none
String? _buildDir() {
  final given = Platform.environment['IMMUCH360_BUILD_DIR'];
  final candidates = [
    if (given != null && given.isNotEmpty) given,
    for (final mode in ['Debug', 'Profile', 'Release']) p.join('build', 'windows', 'x64', 'runner', mode),
  ];
  for (final dir in candidates) {
    if (File(p.join(dir, 'libmpv-2.dll')).existsSync()) {
      return p.absolute(dir);
    }
  }
  return null;
}

void main() {
  final buildDir = Platform.isWindows ? _buildDir() : null;
  final clips = [
    for (final path in (Platform.environment['IMMUCH360_DECODE_CLIPS'] ?? '').split(';'))
      if (path.trim().isNotEmpty && File(path.trim()).existsSync()) path.trim(),
  ];
  final skip = !Platform.isWindows
      ? 'Windows only'
      : buildDir == null
      ? 'no Windows build with libmpv-2.dll'
      : clips.isEmpty
      ? 'no clip in IMMUCH360_DECODE_CLIPS'
      : null;

  setUpAll(() {
    if (skip != null) {
      return;
    }
    // ANGLE's libEGL loads libGLESv2 by name: the build folder must be searched for it
    final setDllDirectory = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    using((arena) => setDllDirectory(buildDir!.toNativeUtf16(allocator: arena)));
    MediaKit.ensureInitialized(libmpv: p.join(buildDir!, 'libmpv-2.dll'));
  });

  test('a playback is measured from the properties of the shipped libmpv', () async {
    for (final clip in clips) {
      final player = await DesktopPlayer.create(PlayerKind.thumbnail);
      final measured = Completer<DecodeMeasure>();
      final sampler = PlaybackDecodeSampler(
        player,
        player.mpvProperty,
        record: (measure) async => measured.complete(measure),
        gpu: () async => 'test',
        appShown: () => true,
      );
      try {
        await player.open(clip);
        await player.play();
        // What the player does each second, printed when no measure came, to tell a stall from a jump
        final states = <String>[];
        final watch = Timer.periodic(const Duration(seconds: 1), (_) async {
          final values = [
            for (final name in ['time-pos', 'paused-for-cache', 'demuxer-cache-duration', 'hwdec-current'])
              '$name=${await player.mpvProperty(name)}',
          ];
          states.add('playing=${player.playing.value} buffering=${player.buffering.value} ${values.join(' ')}');
        });
        final DecodeMeasure measure;
        try {
          measure = await measured.future.timeout(const Duration(seconds: 20));
        } on TimeoutException {
          // ignore: avoid_print
          print(states.join('\n'));
          rethrow;
        } finally {
          watch.cancel();
        }
        // Printed for the report: the clip's format, never its path
        // ignore: avoid_print
        print('${measure.describe()}, ${measure.shownRate.toStringAsFixed(1)} fps shown, ${measure.mpvVersion}');
        expect(measure.codec, isNotEmpty);
        expect(measure.width, greaterThan(0));
        expect(measure.frameRate, greaterThan(0));
        expect(measure.frames, inInclusiveRange(measure.frameRate * 4.5, measure.frameRate * 5.5));
        expect(measure.hwdec, isNotEmpty);
        expect(measure.mpvVersion, startsWith('mpv'));
      } finally {
        sampler.dispose();
        await player.dispose();
      }
    }
  }, skip: skip);
}
