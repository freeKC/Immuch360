// OpenGL ES 3.0 without a window for the tests of the plugin's passes: the ANGLE of the Windows build (its Direct3D 11
// device, Windows' Basic Render Driver on the hosted runners), or, to run the same tests on Linux while working on
// them, Mesa's surfaceless EGL (IMMUCH360_GLES=mesa; LIBGL_ALWAYS_SOFTWARE=1 for llvmpipe).
//   IMMUCH360_BUILD_DIR   another folder of the Windows build holding libEGL.dll and libGLESv2.dll

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// EGL and GLES constants (Khronos headers, ANGLE's eglext_angle.h, Mesa's eglext.h)
const _eglPlatformAngle = 0x3202;
const _eglPlatformAngleType = 0x3203;
const _eglPlatformAngleTypeD3d11 = 0x3208;
const _eglPlatformSurfacelessMesa = 0x31DD;
const _eglNone = 0x3038;
const _eglRedSize = 0x3024;
const _eglGreenSize = 0x3023;
const _eglBlueSize = 0x3022;
const _eglAlphaSize = 0x3021;
const _eglRenderableType = 0x3040;
const _eglSurfaceType = 0x3033;
const _eglPbufferBit = 0x0001;
const _eglOpenglEs3Bit = 0x0040;
const _eglOpenglEsApi = 0x30A0;
const _eglContextClientVersion = 0x3098;
const _eglWidth = 0x3057;
const _eglHeight = 0x3056;

const glRenderer = 0x1F01;
const glExtensions = 0x1F03;
const glVertexShader = 0x8B31;
const glFragmentShader = 0x8B30;
const glTexture2d = 0x0DE1;
const glTexture0 = 0x84C0;
const glRgba = 0x1908;
const glRgba8 = 0x8058;
const glRgba16f = 0x881A;
const glHalfFloat = 0x140B;
const glFloat = 0x1406;
const glUnsignedByte = 0x1401;
const glTextureMinFilter = 0x2801;
const glTextureMagFilter = 0x2800;
const glTextureWrapS = 0x2802;
const glTextureWrapT = 0x2803;
const glNearest = 0x2600;
const glLinear = 0x2601;
const glRepeat = 0x2901;
const glClampToEdge = 0x812F;
const glTriangles = 0x0004;
const glFramebuffer = 0x8D40;
const glColorAttachment0 = 0x8CE0;
const glFramebufferComplete = 0x8CD5;
const glColorBufferBit = 0x00004000;
const _glCompileStatus = 0x8B81;
const _glLinkStatus = 0x8B82;

/// Why the tests cannot run here, or null when they can: on Windows the ANGLE of a build, elsewhere Mesa when asked
String? glesSkipReason() {
  if (Platform.isWindows) {
    return _windowsBuildDir() == null
        ? 'no Windows build with libEGL.dll (flutter build windows first, or set IMMUCH360_BUILD_DIR)'
        : null;
  }
  return Platform.environment['IMMUCH360_GLES'] == 'mesa'
      ? null
      : 'the ANGLE of the Windows build: Windows only (IMMUCH360_GLES=mesa runs it on Mesa)';
}

String? _windowsBuildDir() {
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

Pointer<Int32> _attributes(Arena arena, List<int> values) {
  final list = arena<Int32>(values.length);
  for (var i = 0; i < values.length; i++) {
    list[i] = values[i];
  }
  return list;
}

/// The OpenGL ES 3.0 functions the tests call, with a context current on a pbuffer of [width] x [height]
class Gles {
  Gles._(DynamicLibrary gl)
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
      uniform2i = gl.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('glUniform2i'),
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
      uniformMatrix4fv = gl
          .lookupFunction<
            Void Function(Int32, Int32, Uint8, Pointer<Float>),
            void Function(int, int, int, Pointer<Float>)
          >('glUniformMatrix4fv'),
      genTextures = gl.lookupFunction<Void Function(Int32, Pointer<Uint32>), void Function(int, Pointer<Uint32>)>(
        'glGenTextures',
      ),
      bindTexture = gl.lookupFunction<Void Function(Uint32, Uint32), void Function(int, int)>('glBindTexture'),
      activeTexture = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glActiveTexture'),
      texImage2D = gl
          .lookupFunction<
            Void Function(Uint32, Int32, Int32, Int32, Int32, Int32, Uint32, Uint32, Pointer<Void>),
            void Function(int, int, int, int, int, int, int, int, Pointer<Void>)
          >('glTexImage2D'),
      texParameteri = gl.lookupFunction<Void Function(Uint32, Uint32, Int32), void Function(int, int, int)>(
        'glTexParameteri',
      ),
      genFramebuffers = gl.lookupFunction<Void Function(Int32, Pointer<Uint32>), void Function(int, Pointer<Uint32>)>(
        'glGenFramebuffers',
      ),
      bindFramebuffer = gl.lookupFunction<Void Function(Uint32, Uint32), void Function(int, int)>('glBindFramebuffer'),
      framebufferTexture2D = gl
          .lookupFunction<Void Function(Uint32, Uint32, Uint32, Uint32, Int32), void Function(int, int, int, int, int)>(
            'glFramebufferTexture2D',
          ),
      checkFramebufferStatus = gl.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'glCheckFramebufferStatus',
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
            Void Function(Int32, Int32, Int32, Int32, Uint32, Uint32, Pointer<Void>),
            void Function(int, int, int, int, int, int, Pointer<Void>)
          >('glReadPixels'),
      clearColor = gl
          .lookupFunction<Void Function(Float, Float, Float, Float), void Function(double, double, double, double)>(
            'glClearColor',
          ),
      clear = gl.lookupFunction<Void Function(Uint32), void Function(int)>('glClear'),
      finish = gl.lookupFunction<Void Function(), void Function()>('glFinish'),
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
  final void Function(int, int, int) uniform2i;
  final void Function(int, double, double, double, double) uniform4f;
  final void Function(int, int, int, Pointer<Float>) uniformMatrix3fv;
  final void Function(int, int, int, Pointer<Float>) uniformMatrix4fv;
  final void Function(int, Pointer<Uint32>) genTextures;
  final void Function(int, int) bindTexture;
  final void Function(int) activeTexture;
  final void Function(int, int, int, int, int, int, int, int, Pointer<Void>) texImage2D;
  final void Function(int, int, int) texParameteri;
  final void Function(int, Pointer<Uint32>) genFramebuffers;
  final void Function(int, int) bindFramebuffer;
  final void Function(int, int, int, int, int) framebufferTexture2D;
  final int Function(int) checkFramebufferStatus;
  final void Function(int, Pointer<Uint32>) genVertexArrays;
  final void Function(int) bindVertexArray;
  final void Function(int, int, int, int) viewport;
  final void Function(int, int, int) drawArrays;
  final void Function(int, int, int, int, int, int, Pointer<Void>) readPixels;
  final void Function(double, double, double, double) clearColor;
  final void Function(int) clear;
  final void Function() finish;
  final int Function() getError;
  final Pointer<Utf8> Function(int) getString;

  /// A context of OpenGL ES 3.0 current on a pbuffer of [width] x [height], the ANGLE of the Windows build (Direct
  /// 3D 11) or Mesa's surfaceless display; the memory of its calls in [arena]
  static Gles open(Arena arena, {int width = 64, int height = 64}) {
    final DynamicLibrary egl;
    final DynamicLibrary gles;
    final int platform;
    final List<int> platformAttributes;
    if (Platform.isWindows) {
      final buildDir = _windowsBuildDir()!;
      // ANGLE's libEGL loads libGLESv2 by name: the build folder must be searched for it
      final setDllDirectory = DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
      setDllDirectory(buildDir.toNativeUtf16(allocator: arena));
      egl = DynamicLibrary.open(p.join(buildDir, 'libEGL.dll'));
      gles = DynamicLibrary.open(p.join(buildDir, 'libGLESv2.dll'));
      platform = _eglPlatformAngle;
      platformAttributes = [_eglPlatformAngleType, _eglPlatformAngleTypeD3d11, _eglNone];
    } else {
      egl = DynamicLibrary.open('libEGL.so.1');
      gles = DynamicLibrary.open('libGLESv2.so.2');
      platform = _eglPlatformSurfacelessMesa;
      platformAttributes = [_eglNone];
    }
    final gl = Gles._(gles);
    final getProcAddress = egl
        .lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>(
          'eglGetProcAddress',
        );
    final initialize = egl
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
        >('eglInitialize');
    final bindApi = egl.lookupFunction<Int32 Function(Uint32), int Function(int)>('eglBindAPI');
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
    final display = getPlatformDisplay(platform, nullptr, _attributes(arena, platformAttributes));
    if (display == nullptr || initialize(display, nullptr, nullptr) != 1) {
      throw StateError('no EGL display');
    }
    bindApi(_eglOpenglEsApi);
    final config = arena<Pointer<Void>>();
    final count = arena<Int32>();
    final chosen = chooseConfig(
      display,
      _attributes(arena, [
        _eglRedSize, 8, _eglGreenSize, 8, _eglBlueSize, 8, _eglAlphaSize, 8, //
        _eglRenderableType, _eglOpenglEs3Bit, _eglSurfaceType, _eglPbufferBit, _eglNone,
      ]),
      config,
      1,
      count,
    );
    if (chosen != 1 || count.value < 1) {
      throw StateError('no OpenGL ES 3.0 pbuffer config');
    }
    final context = createContext(
      display,
      config.value,
      nullptr,
      _attributes(arena, [_eglContextClientVersion, 3, _eglNone]),
    );
    final surface = createPbufferSurface(
      display,
      config.value,
      _attributes(arena, [_eglWidth, width, _eglHeight, height, _eglNone]),
    );
    if (context == nullptr || surface == nullptr || makeCurrent(display, surface, surface, context) != 1) {
      throw StateError('no OpenGL ES 3.0 context');
    }
    return gl;
  }

  String string(int name) => getString(name).toDartString();

  /// Compiles [source]; the shader, or a [StateError] with the driver's log
  int compile(int type, String source) => using((arena) {
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

  /// Links [vertex] and [fragment] (sources); the program, or a [StateError] with the driver's log
  int program(String vertex, String fragment) => using((arena) {
    final program = createProgram();
    attachShader(program, compile(glVertexShader, vertex));
    attachShader(program, compile(glFragmentShader, fragment));
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

  int location(int program, String name) =>
      using((arena) => getUniformLocation(program, name.toNativeUtf8(allocator: arena)));

  /// A texture of [width] x [height] with clamped edges, filled with [rgba] when given (8 bits a channel, first row
  /// first), and a framebuffer drawing into it; RGBA16F when [halfFloat]
  GlTarget target(
    Arena arena,
    int width,
    int height, {
    List<int>? rgba,
    int filter = glLinear,
    bool halfFloat = false,
    int wrap = glClampToEdge,
  }) {
    final names = arena<Uint32>(2);
    genTextures(1, names);
    bindTexture(glTexture2d, names[0]);
    texParameteri(glTexture2d, glTextureMinFilter, filter);
    texParameteri(glTexture2d, glTextureMagFilter, filter);
    texParameteri(glTexture2d, glTextureWrapS, wrap);
    texParameteri(glTexture2d, glTextureWrapT, glClampToEdge);
    Pointer<Void> data = nullptr;
    if (rgba != null) {
      final bytes = arena<Uint8>(rgba.length);
      bytes.asTypedList(rgba.length).setAll(0, rgba);
      data = bytes.cast();
    }
    if (halfFloat) {
      texImage2D(glTexture2d, 0, glRgba16f, width, height, 0, glRgba, glHalfFloat, data);
    } else {
      texImage2D(glTexture2d, 0, glRgba8, width, height, 0, glRgba, glUnsignedByte, data);
    }
    genFramebuffers(1, names + 1);
    bindFramebuffer(glFramebuffer, names[1]);
    framebufferTexture2D(glFramebuffer, glColorAttachment0, glTexture2d, names[0], 0);
    final complete = checkFramebufferStatus(glFramebuffer) == glFramebufferComplete;
    bindFramebuffer(glFramebuffer, 0);
    bindTexture(glTexture2d, 0);
    return GlTarget(names[0], complete ? names[1] : 0, width, height);
  }

  /// The pixels of [target], 8 bits a channel, RGBA, first row first
  List<int> read8(GlTarget target) => using((arena) {
    final bytes = arena<Uint8>(target.width * target.height * 4);
    bindFramebuffer(glFramebuffer, target.framebuffer);
    readPixels(0, 0, target.width, target.height, glRgba, glUnsignedByte, bytes.cast());
    bindFramebuffer(glFramebuffer, 0);
    return List.of(bytes.asTypedList(target.width * target.height * 4));
  });

  /// The pixels of a float [target] as floats, RGBA, first row first; null when the driver does not read them so
  List<double>? readFloat(GlTarget target) => using((arena) {
    final values = arena<Float>(target.width * target.height * 4);
    bindFramebuffer(glFramebuffer, target.framebuffer);
    readPixels(0, 0, target.width, target.height, glRgba, glFloat, values.cast());
    bindFramebuffer(glFramebuffer, 0);
    return getError() == 0 ? List.of(values.asTypedList(target.width * target.height * 4)) : null;
  });
}

/// A texture with a framebuffer drawing into it (0 when the driver cannot render into it)
class GlTarget {
  const GlTarget(this.texture, this.framebuffer, this.width, this.height);

  final int texture;
  final int framebuffer;
  final int width;
  final int height;

  bool get valid => framebuffer != 0;
}
