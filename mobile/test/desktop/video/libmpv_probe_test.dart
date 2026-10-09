// The libmpv of the Windows build, checked without a window (plan 2.4, V-READY): it loads, a player plays mpv's
// reference pattern, and mpv renders in an OpenGL ES 3.0 context of the ANGLE that comes with
// media_kit_libs_windows_video, which is what the patch of the vendored media_kit_video asks for
// (packages/media_kit_video/IMMUCH360-NOTE.md). Windows only, after a Windows build of the app:
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/libmpv_probe_test.dart
// IMMUCH360_BUILD_DIR may name another folder holding libmpv-2.dll, libEGL.dll and libGLESv2.dll.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'mpv_measure_support.dart';

/// The folder of the Windows build that holds libmpv and ANGLE, null when there is none
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

// EGL and GLES constants (Khronos headers, ANGLE's eglext_angle.h)
const _eglPlatformAngle = 0x3202;
const _eglPlatformAngleType = 0x3203;
const _eglPlatformAngleTypeD3d11 = 0x3208;
const _eglNone = 0x3038;
const _eglRedSize = 0x3024;
const _eglGreenSize = 0x3023;
const _eglBlueSize = 0x3022;
const _eglAlphaSize = 0x3021;
const _eglRenderableType = 0x3040;
const _eglSurfaceType = 0x3033;
const _eglPbufferBit = 0x0001;
const _eglOpenglEs3Bit = 0x0040;
const _eglContextClientVersion = 0x3098;
const _eglWidth = 0x3057;
const _eglHeight = 0x3056;
const _glVendor = 0x1F00;
const _glRenderer = 0x1F01;
const _glVersion = 0x1F02;
const _glExtensions = 0x1F03;

// libmpv render API (render.h, render_gl.h)
const _mpvRenderParamInvalid = 0;
const _mpvRenderParamApiType = 1;
const _mpvRenderParamOpenglInitParams = 2;
const _mpvRenderParamOpenglFbo = 3;

final class _MpvRenderParam extends Struct {
  @Int32()
  external int type;
  external Pointer<Void> data;
}

final class _MpvOpenglInitParams extends Struct {
  external Pointer<NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)>> getProcAddress;
  external Pointer<Void> getProcAddressCtx;
  // Older libmpv headers had a third field (extra_exts); kept zero so that either layout reads a valid struct
  external Pointer<Void> reserved;
}

final class _MpvOpenglFbo extends Struct {
  @Int32()
  external int fbo;
  @Int32()
  external int w;
  @Int32()
  external int h;
  @Int32()
  external int internalFormat;
}

typedef _GetProcNative = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);

class _Egl {
  _Egl(DynamicLibrary egl, DynamicLibrary gles)
    : getProcAddress = egl.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>(
        'eglGetProcAddress',
      ),
      initialize = egl
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
            int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
          >('eglInitialize'),
      chooseConfig = egl
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, Int32, Pointer<Int32>),
            int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, int, Pointer<Int32>)
          >('eglChooseConfig'),
      createContext = egl
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>),
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>)
          >('eglCreateContext'),
      createPbufferSurface = egl
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>),
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>)
          >('eglCreatePbufferSurface'),
      makeCurrent = egl
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
          >('eglMakeCurrent'),
      destroySurface = egl
          .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>(
            'eglDestroySurface',
          ),
      destroyContext = egl
          .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>), int Function(Pointer<Void>, Pointer<Void>)>(
            'eglDestroyContext',
          ),
      terminate = egl.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('eglTerminate'),
      getError = egl.lookupFunction<Int32 Function(), int Function()>('eglGetError'),
      getString = gles.lookupFunction<Pointer<Utf8> Function(Uint32), Pointer<Utf8> Function(int)>('glGetString'),
      finish = gles.lookupFunction<Void Function(), void Function()>('glFinish');

  final Pointer<Void> Function(Pointer<Utf8>) getProcAddress;
  final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>) initialize;
  final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, int, Pointer<Int32>) chooseConfig;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>) createContext;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>) createPbufferSurface;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>) makeCurrent;
  final int Function(Pointer<Void>, Pointer<Void>) destroySurface;
  final int Function(Pointer<Void>, Pointer<Void>) destroyContext;
  final int Function(Pointer<Void>) terminate;
  final int Function() getError;
  final Pointer<Utf8> Function(int) getString;
  final void Function() finish;

  String string(int name) {
    final value = getString(name);
    return value == nullptr ? '' : value.toDartString();
  }
}

Pointer<Int32> _attributes(Arena arena, List<int> values) {
  final list = arena<Int32>(values.length);
  for (var i = 0; i < values.length; i++) {
    list[i] = values[i];
  }
  return list;
}

void main() {
  final buildDir = Platform.isWindows ? _buildDir() : null;
  final skip = !Platform.isWindows
      ? 'libmpv of the Windows build: Windows only'
      : buildDir == null
      ? 'no Windows build with libmpv-2.dll (flutter build windows first, or set IMMUCH360_BUILD_DIR)'
      : false;

  setUpAll(() {
    if (buildDir == null) {
      return;
    }
    // ANGLE's libEGL loads libGLESv2 by name: the build folder must be searched for it
    final setDllDirectory = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    using((arena) => setDllDirectory(buildDir.toNativeUtf16(allocator: arena)));
    MediaKit.ensureInitialized(libmpv: p.join(buildDir, 'libmpv-2.dll'));
  });

  test('libmpv loads and a player plays the reference pattern', () async {
    final player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.v));
    final logs = MpvLogFilter(keepAll: Platform.environment['IMMUCH360_PROBE_VERBOSE'] == '1');
    final logSubscription = player.stream.log.listen(logs.add);
    final folder = await Directory.systemTemp.createTemp('immuch360_probe_');
    try {
      final native = player.platform! as NativePlayer;
      final version = await native.getProperty('mpv-version');
      final ffmpeg = await native.getProperty('ffmpeg-version');
      expect(version, startsWith('mpv'));
      // What the shipped build can open: the codecs and containers of the 360 cameras and of the reference video
      final decoders = await native.getProperty('decoder-list');
      final demuxers = (await native.getProperty('demuxer-lavf-list')).split(',').toSet();
      final hwdecs = await native.getProperty('hwdec-interop');
      // ignore: avoid_print
      print(
        'libmpv build: decoders ${[
          for (final codec in ['h264', 'hevc', 'vp9', 'av1', 'mjpeg', 'rawvideo', 'prores']) '$codec ${decoders.contains('"codec":"$codec"') || decoders.contains('codec: $codec') ? 'yes' : 'no'}',
        ].join(', ')}; '
        'lavf demuxers ${demuxers.length} (${[
          for (final format in ['mov', 'matroska', 'avi', 'yuv4mpegpipe', 'rawvideo', 'lavfi', 'rtsp', 'hls', 'mpegts']) '$format ${demuxers.contains(format) ? 'yes' : 'no'}',
        ].join(', ')}); '
        'hwdec-interop "$hwdecs"',
      );
      final reference = await openReference(player, folder, width: 1280, height: 720);
      await player.play();
      // The reference loops every second, so the position is sampled and its steps added up rather than subtracted
      var played = Duration.zero;
      var last = double.tryParse(await native.getProperty('time-pos')) ?? 0;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final now = double.tryParse(await native.getProperty('time-pos')) ?? last;
        if (now > last) {
          played += Duration(microseconds: ((now - last) * 1e6).round());
        }
        last = now;
      }
      final drops = await native.getProperty('frame-drop-count');
      // Printed for the report: versions of the shipped build, never a path
      // ignore: avoid_print
      print('libmpv probe: $version, FFmpeg $ffmpeg, reference $reference, played $played in 2 s, drops $drops');
      expect(played, greaterThan(const Duration(milliseconds: 1000)));
    } catch (_) {
      for (final line in logs.lines) {
        // ignore: avoid_print
        print('  mpv: $line');
      }
      rethrow;
    } finally {
      await logSubscription.cancel();
      await player.dispose();
      await folder.delete(recursive: true);
    }
  }, skip: skip);

  test('mpv renders in an OpenGL ES 3.0 context of the shipped ANGLE', () async {
    final egl = _Egl(
      DynamicLibrary.open(p.join(buildDir!, 'libEGL.dll')),
      DynamicLibrary.open(p.join(buildDir, 'libGLESv2.dll')),
    );
    final arena = Arena();
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.v, vo: 'libmpv'),
    );
    final logs = MpvLogFilter();
    final logSubscription = player.stream.log.listen(logs.add);
    final folder = await Directory.systemTemp.createTemp('immuch360_probe_');
    final getProcAddress = NativeCallable<_GetProcNative>.isolateLocal(
      (Pointer<Void> _, Pointer<Utf8> name) => egl.getProcAddress(name),
    );
    final mpv = DynamicLibrary.open(p.join(buildDir, 'libmpv-2.dll'));
    final renderCreate = mpv
        .lookupFunction<
          Int32 Function(Pointer<Pointer<Void>>, Pointer<Void>, Pointer<_MpvRenderParam>),
          int Function(Pointer<Pointer<Void>>, Pointer<Void>, Pointer<_MpvRenderParam>)
        >('mpv_render_context_create');
    final renderUpdate = mpv.lookupFunction<Uint64 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'mpv_render_context_update',
    );
    final render = mpv
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<_MpvRenderParam>),
          int Function(Pointer<Void>, Pointer<_MpvRenderParam>)
        >('mpv_render_context_render');
    final renderFree = mpv.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'mpv_render_context_free',
    );

    Pointer<Void> display = nullptr;
    Pointer<Void> context = nullptr;
    Pointer<Void> surface = nullptr;
    Pointer<Void> renderContext = nullptr;
    try {
      final getPlatformDisplay = egl
          .getProcAddress('eglGetPlatformDisplayEXT'.toNativeUtf8(allocator: arena))
          .cast<NativeFunction<Pointer<Void> Function(Int32, Pointer<Void>, Pointer<Int32>)>>()
          .asFunction<Pointer<Void> Function(int, Pointer<Void>, Pointer<Int32>)>();
      display = getPlatformDisplay(
        _eglPlatformAngle,
        nullptr,
        _attributes(arena, [_eglPlatformAngleType, _eglPlatformAngleTypeD3d11, _eglNone]),
      );
      expect(display, isNot(nullptr));
      expect(
        egl.initialize(display, nullptr, nullptr),
        1,
        reason: 'eglInitialize 0x${egl.getError().toRadixString(16)}',
      );

      // The attributes of the patched ANGLESurfaceManager, plus pbuffer since this probe has no shared texture
      final config = arena<Pointer<Void>>();
      final count = arena<Int32>();
      final configAttributes = _attributes(arena, [
        _eglRedSize, 8, _eglGreenSize, 8, _eglBlueSize, 8, _eglAlphaSize, 8, //
        _eglRenderableType, _eglOpenglEs3Bit, _eglSurfaceType, _eglPbufferBit, _eglNone,
      ]);
      expect(egl.chooseConfig(display, configAttributes, config, 1, count), 1);
      expect(count.value, greaterThan(0), reason: 'no ES 3.0 config on this display');
      context = egl.createContext(
        display,
        config.value,
        nullptr,
        _attributes(arena, [_eglContextClientVersion, 3, _eglNone]),
      );
      expect(context, isNot(nullptr), reason: 'eglCreateContext ES 3.0: 0x${egl.getError().toRadixString(16)}');
      const width = 1280;
      const height = 720;
      surface = egl.createPbufferSurface(
        display,
        config.value,
        _attributes(arena, [_eglWidth, width, _eglHeight, height, _eglNone]),
      );
      expect(surface, isNot(nullptr));
      expect(egl.makeCurrent(display, surface, surface, context), 1);

      final glVersion = egl.string(_glVersion);
      final extensions = egl.string(_glExtensions).split(' ').toSet();
      final essl3 = extensions.contains('GL_OES_EGL_image_external_essl3');
      // ignore: avoid_print
      print(
        'ANGLE: ${egl.string(_glVendor)} | ${egl.string(_glRenderer)} | $glVersion | '
        'GL_OES_EGL_image_external_essl3 ${essl3 ? 'present' : 'missing'} | '
        'EXT_color_buffer_half_float ${extensions.contains('GL_EXT_color_buffer_half_float') ? 'present' : 'missing'}',
      );
      expect(glVersion, startsWith('OpenGL ES 3.'));

      final handle = Pointer<Void>.fromAddress(await player.handle);
      final init = arena<_MpvOpenglInitParams>()
        ..ref.getProcAddress = getProcAddress.nativeFunction
        ..ref.getProcAddressCtx = nullptr
        ..ref.reserved = nullptr;
      final params = arena<_MpvRenderParam>(3);
      params[0]
        ..type = _mpvRenderParamApiType
        ..data = 'opengl'.toNativeUtf8(allocator: arena).cast();
      params[1]
        ..type = _mpvRenderParamOpenglInitParams
        ..data = init.cast();
      params[2]
        ..type = _mpvRenderParamInvalid
        ..data = nullptr;
      final renderContextOut = arena<Pointer<Void>>();
      expect(renderCreate(renderContextOut, handle, params), 0, reason: 'mpv_render_context_create');
      renderContext = renderContextOut.value;

      final reference = await openReference(player, folder, width: 1920, height: 1080);
      final fbo = arena<_MpvOpenglFbo>()
        ..ref.fbo = 0
        ..ref.w = width
        ..ref.h = height
        ..ref.internalFormat = 0;
      final renderParams = arena<_MpvRenderParam>(2);
      renderParams[0]
        ..type = _mpvRenderParamOpenglFbo
        ..data = fbo.cast();
      renderParams[1]
        ..type = _mpvRenderParamInvalid
        ..data = nullptr;
      var rendered = 0;
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 3)) {
        // The test isolate keeps its thread, but the context is made current again after each wait to be sure
        egl.makeCurrent(display, surface, surface, context);
        renderUpdate(renderContext);
        if (render(renderContext, renderParams) >= 0) {
          rendered++;
        }
        egl.finish();
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      // Lets the last log lines of mpv arrive
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final native = player.platform! as NativePlayer;
      final drops = await native.getProperty('frame-drop-count');
      final passes = await native.getProperty('vo-passes');
      // ignore: avoid_print
      print(
        'mpv in ES 3.0: reference $reference, $rendered render calls in 3 s, frame-drop-count $drops, '
        'dumb mode lines ${logs.markers['dumb mode']}, Disabling lines ${logs.markers['Disabling']}, '
        'vo-passes ${passes.isEmpty ? 'unavailable' : '${passes.length} characters'}',
      );
      for (final line in logs.lines.where(
        (line) => line.contains('GL_') || line.contains('GLSL') || line.contains('FBO') || line.contains('dumb'),
      )) {
        // ignore: avoid_print
        print('  mpv: $line');
      }
      expect(logs.firstWith('GL_VERSION'), contains('OpenGL ES 3'));
      // "dumb mode" is mpv's fast path when nothing asks for more than a plain conversion, as here: the spikes count
      // it only while a hook is loaded, where it would mean that the hook is skipped
      expect(rendered, greaterThan(30));
    } finally {
      if (renderContext != nullptr) {
        egl.makeCurrent(display, surface, surface, context);
        renderFree(renderContext);
      }
      await logSubscription.cancel();
      await player.dispose();
      getProcAddress.close();
      if (display != nullptr) {
        egl.makeCurrent(display, nullptr, nullptr, nullptr);
        if (surface != nullptr) {
          egl.destroySurface(display, surface);
        }
        if (context != nullptr) {
          egl.destroyContext(display, context);
        }
        egl.terminate(display);
      }
      arena.releaseAll();
      await folder.delete(recursive: true);
    }
  }, skip: skip);
}
