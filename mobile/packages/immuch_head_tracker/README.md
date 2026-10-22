# immuch_head_tracker

Part of Immuch360 Desktop: the webcam head tracker of Spatial 2.5D on Windows (study
`feasibility-windows-spatial.md` of 22 October 2026, sections 3.1 and 3.2, in the research notes). The phones track
the head with the front camera and the system's face detectors (`HeadTracker.kt`, `HeadTracker.swift`); Windows gives a
desktop app neither, so this plugin reads the webcam with Media Foundation and finds faces with libfacedetection, on
the computer, and the app only ever sees samples: where the face is, how sure the detector is, whether the face is lost.

## Native part (`src/`, `windows/CMakeLists.txt`)

Three DLLs with a C interface (`src/ht_api.h`), called through `dart:ffi`; the plugin registers nothing with Flutter.

- `immuch_head_tracker.dll`: the sources of frames and the analysis.
  - The webcam (`ht_open_camera`): the cameras of `MFEnumDeviceSources` in the colour camera category
    (`KSCATEGORY_VIDEO_CAMERA`); the native format closest to 640 x 480 at 30 fps; a source reader in synchronous mode
    on a thread of the DLL, read as NV12 (or YUY2, I420, grey as they come; the reader adds the MJPEG decoder and the
    colour converter when needed). Each frame's luma plane is box filtered to 160 pixels on its long side, one frame
    in two goes to the detector (15 a second), and the largest face scoring 50 or more gives the sample. The frame
    buffers go back to Media Foundation at once: nothing leaves the capture thread but the sample, nothing is written
    anywhere.
  - Windows Studio Effects automatic framing, which would keep the face in the middle and flatten the parallax: once
    the camera streams, `KSPROPERTY_CAMERACONTROL_EXTENDED_DIGITALWINDOW` is read through the source's `IKsControl`
    and, when automatic face framing is on, the full view is asked for this stream (given back when it stops). The
    outcome is in `ht_info` (`AutoFramingState`): `stuckOn` when the driver refuses, for the message with the camera
    settings.
  - Errors: `E_ACCESSDENIED` (camera access turned off for desktop apps) gives `accessDenied`, for the privacy message
    and its `ms-settings:privacy-webcam` button; a missing `mfplat.dll`, `mfreadwrite.dll` or `mf.dll` (a Windows N
    edition without the Media Feature Pack) gives `noMediaFoundation`: Media Foundation is loaded at run time, never
    imported, so the DLL loads everywhere; a camera taken by another app gives `cameraBusy`, a camera unplugged while
    streaming `deviceLost`.
  - A file source (`ht_open_file`, `ht_next`), the same reader setup and luma path on a video file, and a raw frame
    entry point (`ht_open_frames`, `ht_process_frame`), for the tests. The app's pages never use them.
- `immuch_head_tracker_detect.dll` and `immuch_head_tracker_detect_avx2.dll`: libfacedetection
  (`third_party/libfacedetection`, 3-clause BSD, pinned commit, the network's weights compiled in) behind
  `src/face_detect.h`. The library chooses its SIMD code at compile time, so it is built twice; the tracker checks the
  processor with `cpuid` and `xgetbv` (AVX2, FMA, BMI1, BMI2, LZCNT, MOVBE and the AVX state saved by Windows) and
  loads the AVX2 build where it can run, the plain one otherwise. `IMMUCH360_FACE_DETECTOR=plain` forces the plain
  build.

`test_native/` builds the same sources with gcc on Linux (without the Media Foundation part) and checks the box
filter, the face states and the detector on the frames of the recorded clip, both builds:
`test_native/run.sh` (cmake, g++, ffmpeg).

## Dart part (`lib/`)

- `HeadTracker`: `HeadTracker.windows()`, `cameras()` (in a background isolate, opens no camera), `start(camera)` gives
  a `HeadTrackingSession`: `samples` (a stream of `HeadSample`, then the `HeadTrackerException` that stopped the
  camera), `latest`, `nowNanos()` (the clock of the samples), `info()`, `close()` (releases the camera, in a
  background isolate).
- `defaultHeadCamera`: the first camera whose name does not say infrared (`HeadCamera.infrared`); an infrared camera
  is used only when the user picks it.
- `HeadSample.headX`: the phones' convention, the face centre in the mirrored picture from -0.5 to 0.5, larger when the
  head moves to the user's right (`0.5 - faceX`: a webcam does not mirror its frames).
- `OneEuroFilter`, `HeadXFilter` and `HeadViewpoint`: ports of the phones' classes with the same constants, checked
  against values printed by the Kotlin classes (`test/desktop/spatial/head_tracker_test.dart`).
- `libfacedetectionLicenseEntry`: the notice of libfacedetection for the licence page.

Tests: `test/desktop/spatial/head_tracker_test.dart` (every system), and
`test/desktop/spatial/head_tracker_windows_test.dart`, which runs the DLLs of a Windows build on
`test/fixtures/video/painted-head-12s.mp4` (the desktop workflow runs it after the build).

Licence: the plugin's own code is under the licence of the app (AGPL-3.0); libfacedetection keeps its 3-clause BSD
licence (`third_party/libfacedetection/LICENSE`).
