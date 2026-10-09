Copy of `media_kit_video` 2.0.1 (MIT, https://github.com/media-kit/media-kit, folder `media_kit_video`) at commit
`c533e446755f51cf53c7e57aea873f2aa5355f81` of `main` (2026-08-30, "fix: memory leaks (#1446)"), the newest commit of
`main` on 2026-10-08, which carries the 2026 fixes the pub.dev release 2.0.1 of 2025-12-02 lacks (#1440 for Linux,
#1446). Used by Immuch360 Desktop through `dependency_overrides` in `mobile/pubspec.yaml`, together with the copies of
`media_kit` and `media_kit_libs_windows_video` of the same commit. The MIT notice is in `LICENSE`, as upstream has it.

What differs from upstream, to apply again when a newer commit is copied here:

Layout (no change to the code):

- `pubspec.yaml`: `windows`, `linux` and `macos` are the only plugin platforms (upstream also declares android, ios and
  web), so that the Android and iOS builds of Immuch360 register nothing of it and bundle no libmpv through it; no
  `resolution: workspace` (the upstream repository is a pub workspace); `publish_to: none`, version `2.0.1+immuch360`.
- The `android/`, `ios/` and `example/` folders are left out.
- The macOS sources that upstream shares with iOS through symbolic links into `common/darwin/Classes/` are copied in
  place under `macos/media_kit_video/Sources/media_kit_video/{plugin,stub}/common/`, and `common/darwin/Classes/` is
  left out: the Windows mirror of the work tree and Windows clones do not carry symbolic links. `common/darwin/`
  keeps the Makefile (libmpv headers) and the Podspec helper the macOS podspec uses.

Patches:

1. Windows, an OpenGL ES 3.0 context (`windows/angle_surface_manager.h`, `windows/angle_surface_manager.cc`).
   Upstream asks ANGLE for an ES 2.0 context (`kEGLContextAttributes`, `EGL_CONTEXT_CLIENT_VERSION, 2`). In ES 2.0 mpv
   runs GLSL ES 1.00, cannot import the frames of the D3D11 decoder (its `d3d11egl` interop needs
   `GL_OES_EGL_image_external_essl3`, mpv `video/out/opengl/hwdec_d3d11egl.c`), so a hardware decoded frame is copied
   back, and it may render in an 8 bit FBO (`rgba8` is the last format it tries), which bands; the 360 projection hook
   and the Spatial passes of Immuch360 also want ES 3.0. `ANGLESurfaceManager` now chooses a config with
   `EGL_RENDERABLE_TYPE` = `EGL_OPENGL_ES3_BIT` and creates an ES 3.0 context (`CreateContext(3)`), and falls back to
   upstream's ES 2.0 config and context when the display refuses (the Direct3D 11 feature level 9_3 and Direct3D 9
   displays of its fallback chain), so a machine without ES 3.0 keeps the hardware path it had. It prints which one it
   got ("OpenGL ES 3.0 context") and exposes it as `client_version()`. Its premise is checked without a window by
   `mobile/test/desktop/video/libmpv_probe_test.dart` on Windows, which makes the same config and context through
   FFI: the ANGLE of the libs package gives OpenGL ES 3.0 with `GL_OES_EGL_image_external_essl3`, and mpv renders in
   it with GLSL ES 3.00 into an `rgba16f` FBO. The patched plugin itself runs in the reference run of the measurement
   harness (`mobile/integration_test/desktop_video_measure_test.dart`), on the owner's screen.

2. Linux, media_kit #1404, "[Linux] H/W rendering fails on Flutter 3.38+" (`linux/video_output.cc`). Since Flutter
   3.38 the engine's EGL context is current on the raster thread only, so `eglGetCurrentDisplay()` on the platform
   thread gives `EGL_NO_DISPLAY` and every output fell back to S/W rendering, in which mpv runs no user shader. The fix
   proposed in the issue: when no context is current, the EGL display is taken from GDK's native display (Wayland or
   X11) through `eglGetPlatformDisplayEXT`, looked up with `eglGetProcAddress` because epoxy's own dispatch of
   `eglGetPlatformDisplay` asks for EGL 1.5 on a current display that does not exist yet (reported in the issue); the
   config is chosen with `eglChooseConfig` (ES 2.0, RGBA 8) since Flutter's cannot be queried; the isolated context is
   released after its setup and in `dispose` instead of "restoring" a context that was never current. The path where
   Flutter's context is current is unchanged. Compiled only when `media_kit_libs_linux` is in the app (phase 4); until
   then the Linux build compiles the stub of upstream (`MEDIA_KIT_LIBS_NOT_FOUND`). To test in phase 4 on Wayland and
   on X11: the issue reports a GLX `BadAccess` on X11 with the GDK display on two machines.

3. Dart, the size of the texture (`lib/src/video_controller/native_video_controller/real.dart`,
   `lib/src/video_controller/video_controller.dart`). Upstream sets the texture to the size of each new video
   whenever mpv reports its parameters, even when the app fixed a size (`VideoControllerConfiguration.width` and
   `height`, or `setSize`): a fixed size lasted until the first frame. A fixed size now stays. And a new static
   `VideoController.maxOutputHeight` caps the texture of a video whose size is not fixed at that many lines, keeping
   its shape (the width rounded to an even number): the render height cap of the design (2.11), 1440 lines set by
   the app (`DesktopPlayerOptions.maxRenderHeight`), Flutter scaling the texture up the rest of the way, so that an
   8K video is drawn into 2880 x 1440 rather than 7680 x 3840. The measurement harness's "window" render size relied
   on the fixed size, which upstream replaced: its runs before this patch measured the video's own size.

Not done yet (plan 20-plan-desktop.md, 2.2): the D3D11 device on the adapter Flutter uses, only if spike 6 shows a
mismatch on a hybrid GPU machine.
