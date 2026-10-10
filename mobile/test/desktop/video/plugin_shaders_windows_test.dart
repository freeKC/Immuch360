// The passes of renderer C (packages/media_kit_video/windows/projection_shaders.h, IMMUCH360-NOTE.md patch 6) in
// the ANGLE of the Windows build, without a window: the sources are read from the header and put together as
// ProjectionRenderer does, all three programs must compile and link in OpenGL ES 3.0, and the equirectangular pass
// draws a synthetic frame (upper half red, lower half blue, the quarter ahead green) where the view looks: up is up,
// the first row of the output is the top of the view, the yaw turns to the right, a VR180 crop is black behind.
// Windows only, after a Windows build of the app (it holds libEGL.dll and libGLESv2.dll):
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/plugin_shaders_windows_test.dart
// IMMUCH360_BUILD_DIR may name another folder holding the two DLLs.

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The folder of the Windows build that holds ANGLE, null when there is none
String? _buildDir() {
  final given = Platform.environment['IMMUCH360_BUILD_DIR'];
  final candidates = [
    if (given != null && given.isNotEmpty) given,
    for (final mode in ['Debug', 'Profile', 'Release']) p.join('build', 'windows', 'x64', 'runner', mode),
  ];
  for (final dir in candidates) {
    if (File(p.join(dir, 'libEGL.dll')).existsSync() && File(p.join(dir, 'libGLESv2.dll')).existsSync()) {
      return p.absolute(dir);
    }
  }
  return null;
}

/// The GLSL constants of projection_shaders.h by name
Map<String, String> _shaderSources() {
  final header = File(p.join('packages', 'media_kit_video', 'windows', 'projection_shaders.h')).readAsStringSync();
  return {
    for (final match in RegExp(
      r'constexpr const char\* (k\w+) = R"glsl\((.*?)\)glsl";',
      dotAll: true,
    ).allMatches(header))
      match.group(1)!: match.group(2)!,
  };
}

/// The fragment program of [kind] (0 equirectangular, 1 fisheye pair, 2 EAC pair), in ProjectionRenderer::Program's
/// order
String _fragment(Map<String, String> sources, int kind) => [
  sources['kFragmentHeader']!,
  '#define PROJECTION_KIND $kind\n',
  sources['kFragmentCommon']!,
  if (kind == 0)
    sources['kFragmentEquirect']!
  else ...[
    sources['kFragmentStreams']!,
    kind == 1 ? sources['kFragmentFisheye']! : sources['kFragmentEac']!,
  ],
  sources['kFragmentMain']!,
].join();

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
const _glRenderer = 0x1F01;
const _glVertexShader = 0x8B31;
const _glFragmentShader = 0x8B30;
const _glCompileStatus = 0x8B81;
const _glLinkStatus = 0x8B82;
const _glTexture2d = 0x0DE1;
const _glTexture0 = 0x84C0;
const _glRgba = 0x1908;
const _glRgba8 = 0x8058;
const _glUnsignedByte = 0x1401;
const _glTextureMinFilter = 0x2801;
const _glTextureMagFilter = 0x2800;
const _glTextureWrapS = 0x2802;
const _glTextureWrapT = 0x2803;
const _glLinear = 0x2601;
const _glRepeat = 0x2901;
const _glClampToEdge = 0x812F;
const _glTriangles = 0x0004;

typedef _V = Void Function();

class _Gles {
  _Gles(DynamicLibrary gl)
    : createShader = gl.lookupFunction<Uint32 Function(Uint32), int Function(int)>('glCreateShader'),
      shaderSource = gl
          .lookupFunction<
            Void Function(Uint32, Int32, Pointer<Pointer<Utf8>>, Pointer<Int32>),
            void Function(int, int, Pointer<Pointer<Utf8>>, Pointer<Int32>)
          >('glShaderSource'),
      compileShader = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glCompileShader'),
      getShaderiv = gl
          .lookupFunction<Void Function(Uint32, Uint32, Pointer<Int32>), void Function(int, int, Pointer<Int32>)>(
            'glGetShaderiv',
          ),
      getShaderInfoLog = gl
          .lookupFunction<
            Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Utf8>),
            void Function(int, int, Pointer<Int32>, Pointer<Utf8>)
          >('glGetShaderInfoLog'),
      createProgram = gl.lookupFunction<Uint32 Function(), int Function()>('glCreateProgram'),
      attachShader = gl.lookupFunction<Void Function(Uint32, Uint32), void Function(int, int)>('glAttachShader'),
      linkProgram = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glLinkProgram'),
      getProgramiv = gl
          .lookupFunction<Void Function(Uint32, Uint32, Pointer<Int32>), void Function(int, int, Pointer<Int32>)>(
            'glGetProgramiv',
          ),
      getProgramInfoLog = gl
          .lookupFunction<
            Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Utf8>),
            void Function(int, int, Pointer<Int32>, Pointer<Utf8>)
          >('glGetProgramInfoLog'),
      useProgram = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glUseProgram'),
      getUniformLocation = gl.lookupFunction<Int32 Function(Uint32, Pointer<Utf8>), int Function(int, Pointer<Utf8>)>(
        'glGetUniformLocation',
      ),
      uniform1i = gl.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('glUniform1i'),
      uniform1f = gl.lookupFunction<Void Function(Int32, Float), void Function(int, double)>('glUniform1f'),
      uniform2f = gl.lookupFunction<Void Function(Int32, Float, Float), void Function(int, double, double)>(
        'glUniform2f',
      ),
      uniform4f = gl
          .lookupFunction<
            Void Function(Int32, Float, Float, Float, Float),
            void Function(int, double, double, double, double)
          >('glUniform4f'),
      uniformMatrix3fv = gl
          .lookupFunction<
            Void Function(Int32, Int32, Uint8, Pointer<Float>),
            void Function(int, int, int, Pointer<Float>)
          >('glUniformMatrix3fv'),
      genTextures = gl.lookupFunction<Void Function(Int32, Pointer<Uint32>), void Function(int, Pointer<Uint32>)>(
        'glGenTextures',
      ),
      bindTexture = gl.lookupFunction<Void Function(Uint32, Uint32), void Function(int, int)>('glBindTexture'),
      activeTexture = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glActiveTexture'),
      texImage2D = gl
          .lookupFunction<
            Void Function(Uint32, Int32, Int32, Int32, Int32, Int32, Uint32, Uint32, Pointer<Uint8>),
            void Function(int, int, int, int, int, int, int, int, Pointer<Uint8>)
          >('glTexImage2D'),
      texParameteri = gl.lookupFunction<Void Function(Uint32, Uint32, Int32), void Function(int, int, int)>(
        'glTexParameteri',
      ),
      genVertexArrays = gl.lookupFunction<Void Function(Int32, Pointer<Uint32>), void Function(int, Pointer<Uint32>)>(
        'glGenVertexArrays',
      ),
      bindVertexArray = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glBindVertexArray'),
      viewport = gl.lookupFunction<Void Function(Int32, Int32, Int32, Int32), void Function(int, int, int, int)>(
        'glViewport',
      ),
      drawArrays = gl.lookupFunction<Void Function(Uint32, Int32, Int32), void Function(int, int, int)>('glDrawArrays'),
      readPixels = gl
          .lookupFunction<
            Void Function(Int32, Int32, Int32, Int32, Uint32, Uint32, Pointer<Uint8>),
            void Function(int, int, int, int, int, int, Pointer<Uint8>)
          >('glReadPixels'),
      finish = gl.lookupFunction<_V, void Function()>('glFinish'),
      getError = gl.lookupFunction<Uint32 Function(), int Function()>('glGetError'),
      getString = gl.lookupFunction<Pointer<Utf8> Function(Uint32), Pointer<Utf8> Function(int)>('glGetString');

  final int Function(int) createShader;
  final void Function(int, int, Pointer<Pointer<Utf8>>, Pointer<Int32>) shaderSource;
  final void Function(int) compileShader;
  final void Function(int, int, Pointer<Int32>) getShaderiv;
  final void Function(int, int, Pointer<Int32>, Pointer<Utf8>) getShaderInfoLog;
  final int Function() createProgram;
  final void Function(int, int) attachShader;
  final void Function(int) linkProgram;
  final void Function(int, int, Pointer<Int32>) getProgramiv;
  final void Function(int, int, Pointer<Int32>, Pointer<Utf8>) getProgramInfoLog;
  final void Function(int) useProgram;
  final int Function(int, Pointer<Utf8>) getUniformLocation;
  final void Function(int, int) uniform1i;
  final void Function(int, double) uniform1f;
  final void Function(int, double, double) uniform2f;
  final void Function(int, double, double, double, double) uniform4f;
  final void Function(int, int, int, Pointer<Float>) uniformMatrix3fv;
  final void Function(int, Pointer<Uint32>) genTextures;
  final void Function(int, int) bindTexture;
  final void Function(int) activeTexture;
  final void Function(int, int, int, int, int, int, int, int, Pointer<Uint8>) texImage2D;
  final void Function(int, int, int) texParameteri;
  final void Function(int, Pointer<Uint32>) genVertexArrays;
  final void Function(int) bindVertexArray;
  final void Function(int, int, int, int) viewport;
  final void Function(int, int, int) drawArrays;
  final void Function(int, int, int, int, int, int, Pointer<Uint8>) readPixels;
  final void Function() finish;
  final int Function() getError;
  final Pointer<Utf8> Function(int) getString;

  /// Compiles [source]; the shader, or a [StateError] with the driver's log
  int compile(int type, String source) {
    return using((arena) {
      final shader = createShader(type);
      final text = arena<Pointer<Utf8>>()..value = source.toNativeUtf8(allocator: arena);
      shaderSource(shader, 1, text, nullptr);
      compileShader(shader);
      final status = arena<Int32>();
      getShaderiv(shader, _glCompileStatus, status);
      if (status.value != 1) {
        final log = arena<Uint8>(4096).cast<Utf8>();
        getShaderInfoLog(shader, 4095, nullptr, log);
        throw StateError('compile: ${log.toDartString()}');
      }
      return shader;
    });
  }

  int link(int vertex, int fragment) {
    return using((arena) {
      final program = createProgram();
      attachShader(program, vertex);
      attachShader(program, fragment);
      linkProgram(program);
      final status = arena<Int32>();
      getProgramiv(program, _glLinkStatus, status);
      if (status.value != 1) {
        final log = arena<Uint8>(4096).cast<Utf8>();
        getProgramInfoLog(program, 4095, nullptr, log);
        throw StateError('link: ${log.toDartString()}');
      }
      return program;
    });
  }

  int location(int program, String name) =>
      using((arena) => getUniformLocation(program, name.toNativeUtf8(allocator: arena)));
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
      ? 'the ANGLE of the Windows build: Windows only'
      : buildDir == null
      ? 'no Windows build with libEGL.dll (flutter build windows first, or set IMMUCH360_BUILD_DIR)'
      : false;

  late _Gles gl;
  final arena = Arena();
  const size = 256;

  setUpAll(() {
    if (buildDir == null) {
      return;
    }
    // ANGLE's libEGL loads libGLESv2 by name: the build folder must be searched for it
    final setDllDirectory = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    using((arena) => setDllDirectory(buildDir.toNativeUtf16(allocator: arena)));
    final egl = DynamicLibrary.open(p.join(buildDir, 'libEGL.dll'));
    gl = _Gles(DynamicLibrary.open(p.join(buildDir, 'libGLESv2.dll')));
    final getProcAddress = egl
        .lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>(
          'eglGetProcAddress',
        );
    final initialize = egl
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
        >('eglInitialize');
    final chooseConfig = egl
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, Int32, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Int32>, Pointer<Pointer<Void>>, int, Pointer<Int32>)
        >('eglChooseConfig');
    final createContext = egl
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Int32>)
        >('eglCreateContext');
    final createPbufferSurface = egl
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>)
        >('eglCreatePbufferSurface');
    final makeCurrent = egl
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
        >('eglMakeCurrent');
    final getPlatformDisplay = getProcAddress('eglGetPlatformDisplayEXT'.toNativeUtf8(allocator: arena))
        .cast<NativeFunction<Pointer<Void> Function(Int32, Pointer<Void>, Pointer<Int32>)>>()
        .asFunction<Pointer<Void> Function(int, Pointer<Void>, Pointer<Int32>)>();
    final display = getPlatformDisplay(
      _eglPlatformAngle,
      nullptr,
      _attributes(arena, [_eglPlatformAngleType, _eglPlatformAngleTypeD3d11, _eglNone]),
    );
    expect(initialize(display, nullptr, nullptr), 1);
    // The attributes of the patched ANGLESurfaceManager, plus pbuffer since this test has no shared texture
    final config = arena<Pointer<Void>>();
    final count = arena<Int32>();
    expect(
      chooseConfig(
        display,
        _attributes(arena, [
          _eglRedSize, 8, _eglGreenSize, 8, _eglBlueSize, 8, _eglAlphaSize, 8, //
          _eglRenderableType, _eglOpenglEs3Bit, _eglSurfaceType, _eglPbufferBit, _eglNone,
        ]),
        config,
        1,
        count,
      ),
      1,
    );
    expect(count.value, greaterThan(0));
    final context = createContext(
      display,
      config.value,
      nullptr,
      _attributes(arena, [_eglContextClientVersion, 3, _eglNone]),
    );
    expect(context, isNot(nullptr));
    final surface = createPbufferSurface(
      display,
      config.value,
      _attributes(arena, [_eglWidth, size, _eglHeight, size, _eglNone]),
    );
    expect(surface, isNot(nullptr));
    expect(makeCurrent(display, surface, surface, context), 1);
    // ignore: avoid_print
    print('ANGLE: ${gl.getString(_glRenderer).toDartString()}');
  });

  tearDownAll(arena.releaseAll);

  test('the three passes compile and link in OpenGL ES 3.0', () {
    final sources = _shaderSources();
    expect(sources.keys, containsAll(['kVertexSource', 'kFragmentCommon', 'kFragmentEquirect', 'kFragmentMain']));
    final vertex = gl.compile(_glVertexShader, sources['kVertexSource']!);
    for (final kind in [0, 1, 2]) {
      final program = gl.link(vertex, gl.compile(_glFragmentShader, _fragment(sources, kind)));
      expect(program, greaterThan(0), reason: 'projection $kind');
    }
  }, skip: skip);

  test('the equirectangular pass looks where the view looks', () {
    final sources = _shaderSources();
    final program = gl.link(
      gl.compile(_glVertexShader, sources['kVertexSource']!),
      gl.compile(_glFragmentShader, _fragment(sources, 0)),
    );
    // The frame as mpv draws it into the intermediate texture: its first row is the top of the picture. Upper half
    // red, lower half blue, the quarter of the longitudes ahead (u 0.375 to 0.625) green.
    const frameWidth = 1024;
    const frameHeight = 512;
    final pixels = arena<Uint8>(frameWidth * frameHeight * 4);
    for (var y = 0; y < frameHeight; y++) {
      for (var x = 0; x < frameWidth; x++) {
        final i = (y * frameWidth + x) * 4;
        final u = (x + 0.5) / frameWidth;
        pixels[i] = y < frameHeight / 2 ? 255 : 0;
        pixels[i + 1] = u > 0.375 && u < 0.625 ? 255 : 0;
        pixels[i + 2] = y < frameHeight / 2 ? 0 : 255;
        pixels[i + 3] = 255;
      }
    }
    final texture = arena<Uint32>();
    gl
      ..genTextures(1, texture)
      ..activeTexture(_glTexture0)
      ..bindTexture(_glTexture2d, texture.value)
      ..texImage2D(_glTexture2d, 0, _glRgba8, frameWidth, frameHeight, 0, _glRgba, _glUnsignedByte, pixels)
      ..texParameteri(_glTexture2d, _glTextureMinFilter, _glLinear)
      ..texParameteri(_glTexture2d, _glTextureMagFilter, _glLinear)
      ..texParameteri(_glTexture2d, _glTextureWrapS, _glRepeat)
      ..texParameteri(_glTexture2d, _glTextureWrapT, _glClampToEdge);
    final vertexArray = arena<Uint32>();
    gl
      ..genVertexArrays(1, vertexArray)
      ..bindVertexArray(vertexArray.value)
      ..useProgram(program)
      ..viewport(0, 0, size, size);

    final matrix = arena<Float>(9);
    // Draws the view and reads the pixel of the output at (x, row), row 0 being the first row of the output
    (int, int, int) draw({
      required double yaw,
      required double pitch,
      double fov = 60,
      List<double> crop = const [0, 0, 1, 1],
      int x = size ~/ 2,
      int row = size ~/ 2,
    }) {
      // ProjectionRenderer::SetUniforms: rows of Ry(yaw) * Rx(pitch), uploaded column major
      final cy = math.cos(yaw * math.pi / 180);
      final sy = math.sin(yaw * math.pi / 180);
      final cp = math.cos(pitch * math.pi / 180);
      final sp = math.sin(pitch * math.pi / 180);
      final rows = [cy, -sy * sp, sy * cp, 0.0, cp, sp, -sy, -cy * sp, cy * cp];
      for (var i = 0; i < 9; i++) {
        matrix[i] = rows[(i % 3) * 3 + i ~/ 3];
      }
      final tanHalf = math.tan(fov * math.pi / 360);
      gl
        ..uniform1i(gl.location(program, 'uSource'), 0)
        ..uniformMatrix3fv(gl.location(program, 'uViewToSphere'), 1, 0, matrix)
        ..uniform2f(gl.location(program, 'uTanHalfFov'), tanHalf, tanHalf)
        ..uniform1f(gl.location(program, 'uSharp'), 0)
        ..uniform2f(gl.location(program, 'uOutputSize'), size.toDouble(), size.toDouble())
        ..uniform1f(gl.location(program, 'uTexelsPerPixel'), 1)
        ..uniform4f(gl.location(program, 'uEye'), 0, 0, 1, 1)
        ..uniform4f(gl.location(program, 'uCrop'), crop[0], crop[1], crop[2], crop[3])
        ..drawArrays(_glTriangles, 0, 3)
        ..finish();
      final out = arena<Uint8>(4);
      // Row 0 of the output is OpenGL's y = 0 (the pbuffer media_kit fills is read by Flutter from its first row)
      gl.readPixels(x, row, 1, 1, _glRgba, _glUnsignedByte, out);
      expect(gl.getError(), 0);
      return (out[0], out[1], out[2]);
    }

    (int, int, int) colour(int r, int g, int b) => (r, g, b);
    final yellow = colour(255, 255, 0);
    final cyan = colour(0, 255, 255);
    final red = colour(255, 0, 0);
    final blue = colour(0, 0, 255);
    final black = colour(0, 0, 0);

    expect(draw(yaw: 0, pitch: 45), yellow, reason: 'ahead and up: the upper half, the green quarter');
    expect(draw(yaw: 0, pitch: -45), cyan, reason: 'ahead and down: the lower half, the green quarter');
    expect(draw(yaw: 180, pitch: 45), red, reason: 'behind and up: outside the green quarter');
    expect(draw(yaw: 90, pitch: -45), blue);
    // The yaw turns to the right: the green quarter (45 degrees on each side of ahead) leaves the centre of a view
    // turned 60 degrees, and the left edge of that 60 degree wide view (30 degrees to the left) is back in it
    expect(draw(yaw: 60, pitch: 10), red);
    expect(draw(yaw: 60, pitch: 10, x: 2), yellow, reason: 'the left edge looks 30 degrees to the left of the yaw');
    expect(draw(yaw: 60, pitch: 10, x: size - 3), red);
    // The first row of the output is the top of the view
    expect(draw(yaw: 180, pitch: 0, fov: 90, row: 2), red, reason: 'the top row looks up');
    expect(draw(yaw: 180, pitch: 0, fov: 90, row: size - 3), blue, reason: 'the last row looks down');
    // VR180: the front half only, black behind
    expect(draw(yaw: 0, pitch: 45, crop: const [0.25, 0, 0.5, 1]), isNot(black));
    expect(draw(yaw: 180, pitch: 45, crop: const [0.25, 0, 0.5, 1]), black);
  }, skip: skip);
}
