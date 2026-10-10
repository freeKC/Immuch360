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
   runs GLSL ES 1.00 and may render in an 8 bit FBO (`rgba8` is the last format it tries), which bands; the 360
   projection hook and the Spatial passes of Immuch360 want GLSL ES 3.00, and ES 3.0 gives an `rgba16f` FBO. What the
   context does not change: whether mpv imports the frames of the D3D11 decoder without a copy. Its `d3d11egl` interop
   (`video/out/opengl/hwdec_d3d11egl.c`, `init`) waives `GL_OES_EGL_image_external_essl3` in ES 2.0 (`gl->es == 200`)
   anyway, and in both versions also wants `EGL_EXT_device_query` among the extensions of the display, which the
   ANGLE of the libs package lists only among its client extensions: so with the 2024 libmpv (mpv 0.39) every
   hardware decoded frame is copied back (`hwdec-current` is `d3d11va-copy` in every spike). The mpv commit that
   `.github/workflows/immuch360-libmpv.yml` builds (`0b7ed670`) also accepts the extension from the client list
   (`hwdec_d3d11egl.c`, `init`): zero copy needs no patch of mpv, only that build switched on
   (`IMMUCH360_LIBMPV_FROM_CI` in `media_kit_libs_windows_video`), then `hwdec-current` and the video support of the
   ANGLE device checked by the harness. `ANGLESurfaceManager` now chooses a config with
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

4. Windows, a lost graphics device (`windows/angle_surface_manager.{h,cc}`, `windows/video_output.{h,cc}`). After a
   driver update or reset, a GPU switched or gone, or some sleeps, the Direct3D 11 device of a player is removed:
   upstream then draws nothing, and a new texture size threw inside the thread pool's task, where the exception was
   lost with the texture already unregistered, so the video stayed black or frozen, with its sound, in every later
   use of that player. `ANGLESurfaceManager::IsDeviceLost` asks the device (`GetDeviceRemovedReason`) before each
   frame is drawn; `VideoOutput` stops drawing and making textures on a lost device, and tells Dart once through the
   texture update with the id 0, which is never given otherwise. The app's player pool then disposes that player and
   the idle ones, and the page opens its video again where it was in a new player, on a new device
   (`mobile/lib/desktop/video/player_pool.dart`, `PlayerLease.discard`). The detection is in the code paths that ran
   on the owner's PC; a real device loss (sleep and resume, a driver restart with `pnputil /restart-device`) is a
   check of the owner's session (plan 2.4, DEVICE).

5. Windows, a texture replaced while Flutter reads it (`windows/angle_surface_manager.cc`, `windows/video_output.cc`).
   Each new texture size (another video in a pooled player, or the render height cap of patch 3 arriving after mpv's
   first size) makes the two Direct3D textures again on the player's worker thread, while Flutter's raster thread may
   be copying between them (`Read`) for the texture being replaced. Upstream released and made them without the
   mutex `Read` holds, and gave `texture_id_` the new id before the texture was in the map its callbacks look it up
   in (`textures_.at`, which throws inside the engine). On 2026-10-09 the measurement harness ended three times out
   of eleven runs that way, each time just after a new texture of a 5.7K or 8K video on the Intel UHD, mostly when
   it shrank from 5760 x 2880 to 2880 x 1440: an access violation in the Intel driver (`igd10um64xe.dll`, c0000005)
   twice and a fail fast in `flutter_windows.dll` (c0000409) once. `SetSize` now holds the mutex while it makes the
   textures again, and `Resize` zeroes `texture_id_` before the old texture is unregistered and gives it the new id
   only once the texture is in the map, both under the lock the callbacks take.

6. Windows, renderer C: the 360 view drawn by the plugin (`windows/projection_renderer.{h,cc}`,
   `windows/projection_shaders.h`, `windows/video_output.{h,cc}`, `windows/video_output_manager.{h,cc}`,
   `windows/angle_surface_manager.{h,cc}`, `windows/media_kit_video_plugin.cc`, `windows/CMakeLists.txt`,
   `lib/src/projection_output.dart`, exported by `lib/media_kit_video.dart`). Decision DP1 of Immuch360 Desktop
   (2026-10-09): the 360 view as an mpv user shader changed through `glsl-shader-opts` rebuilt mpv's passes at every
   change, kept 40 to 200 MB of GPU memory per change on an RTX 4060 until the PC ran out of memory, and gave 11 frames
   a second on an Intel UHD. With this patch a player may be switched to a projection
   (`VideoOutputManager.SetProjection`): mpv then draws each frame, exactly as for a flat video, into an intermediate
   RGBA 8 texture of the video's size, capped by the tier Dart asks (at most so wide and so many pixels, the shape kept,
   rounded to even sizes), and one GLSL ES 3.00 pass draws the view from it into the player's own texture, which keeps
   its id, its `VideoController` and its `Video` widget; the texture is then the output size Dart gives (capped at
   `maxOutputHeight` lines) from its first frame, not the video's. Three passes: an equirectangular frame (one eye of a
   stereo layout, the whole sphere or its front half), a fisheye pair (Mei, equidistant, Kannala-Brandt) and a GoPro EAC
   pair, both stitches being the GLSL of the phones (`RawStitchShaders.kt` of the app) reading the decoded streams side
   by side in the one frame; bilinear while the view moves, Catmull-Rom (or four reads per pixel when the view shrinks
   the frame) once it rests. The view (`VideoOutputManager.SetView`, yaw, pitch, vertical field of view, sharp) is kept
   by the output and drawn by at most one waiting task of the thread pool, so that views coming faster than the pass are
   merged; it is answered on the platform thread without waiting for `VideoOutputManager`'s mutex (a lookup map of its
   own, filled once an output is made and emptied before it is destroyed). Each draw asks mpv
   (`mpv_render_context_update`) whether it has a frame: mpv draws into the intermediate texture only then, and a paused
   video is redrawn from the texture kept without any call into mpv. The player's `ANGLESurfaceManager` gets a second
   internal texture while a projection is on (`SetDoubleBuffered`, `MakeBackCurrent`, `SwapBack`, and `Read` copying
   from the front one): mpv's frame and the view are drawn into the texture Flutter does not copy from and finished
   (`glFinish`), then the two are swapped under the lock that `Read` takes on Flutter's raster thread, which is thus
   held for the swap only (0.01 ms at the 99th percentile on both GPUs, against up to 16 ms per draw when the drawing
   happened under it: the RTX 4060 takes 14 to 16 ms to finish each draw of a paused video). No swap is reported to mpv
   (`mpv_render_context_report_swap`): once one is, vo_libmpv waits for the next before it hands over each frame, which
   put 30 to 53 frame intervals over 50 ms in 10 s into an 8K video on the RTX 4060.
   `VideoOutputManager.ProjectionStats` gives the counts and times of the draws and, on request, five pixels of the
   output read back. A context without OpenGL ES 3.0 (patch 1's fallback) refuses the projection with the reason;
   turning it off gives upstream's drawing back, the current frame drawn at once. The view convention is the app's photo
   sphere: yaw positive to the right of the frame's centre column, pitch positive up; the first row of the output is the
   top of the view, as mpv draws into the pbuffer (`MPV_RENDER_PARAM_FLIP_Y` left at 0). Checked without a window by
   `mobile/test/desktop/video/plugin_shaders_windows_test.dart` (the three programs compile and link in ANGLE's ES 3.0,
   the equirectangular pass looks where the view looks) and with the player by the measurement harness
   (`IMMUCH360_MEASURE_RENDERER=c`). Also fixed on the way, in `VideoOutput::~VideoOutput`: when no texture was
   registered (after a lost device of patch 4, or a failed `Resize`), the destructor waited for a promise that nothing
   would fulfil, holding `VideoOutputManager`'s mutex, so that every later player of the app hung; the cleanup is now
   posted to the thread pool in that case too.

Not done yet (plan 20-plan-desktop.md, 2.2): the D3D11 device on the adapter Flutter uses, only if spike 6 shows a
mismatch on a hybrid GPU machine.
