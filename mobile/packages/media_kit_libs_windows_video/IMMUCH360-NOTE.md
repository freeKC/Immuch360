Copy of `media_kit_libs_windows_video` 1.0.12 (MIT, https://github.com/media-kit/media-kit, folder
`libs/windows/media_kit_libs_windows_video`) at commit `c533e446755f51cf53c7e57aea873f2aa5355f81` of `main`
(2026-08-30); pub.dev only has 1.0.11 of 2025-03-24, without the arm64 libraries. Used by Immuch360 Desktop through
`dependency_overrides` in `mobile/pubspec.yaml`. Its CMake downloads, at configure time, libmpv
(`mpv-dev-x86_64-20241021-git-0f78584.7z`, or the aarch64 one) from `media-kit/libmpv-win32-video-cmake` and ANGLE
(`ANGLE.7z` v1.0.1) from `alexmercerind/flutter-windows-ANGLE-OpenGL-ES`, checked by MD5 upstream and by SHA-256 here,
and bundles `libmpv-2.dll`, `libEGL.dll`, `libGLESv2.dll`, `d3dcompiler_47.dll`, `vk_swiftshader.dll` and
`vulkan-1.dll` next to the executable. The plugin declares windows only. The MIT notice is in `LICENSE`; the licences
of libmpv (LGPL) and of the other files it bundles are in `../media_kit_video/windows/NOTICES.md`.

What differs from upstream, to apply again when a newer commit is copied here:

- `pubspec.yaml`: no `resolution: workspace`, no dev dependencies; `publish_to: none`, version `1.0.12+immuch360`.
- `windows/CMakeLists.txt`: `POST_BUILD` added to the CMake tar fallback that extracts ANGLE when 7-Zip is not on the
  PATH. Upstream left it out when it added the 7-Zip path (commit 46c08485), and the `cmake_policy(SET CMP0175 NEW)`
  of commit 7102e7da turns that into a configure error ("Exactly one of PRE_BUILD, PRE_LINK, or POST_BUILD must be
  given"), so no machine without `7z` on its PATH could build the app.
- `windows/CMakeLists.txt`: every archive is checked by SHA-256 instead of MD5 (`download_and_verify`), with the
  SHA-256 of the 2024 libmpv archives (x64 `e23701df...a007`, arm64 `d445d02a...33ae`) and of `ANGLE.7z`
  (`cc5911bb...5f9a`), whose MD5 matched upstream's when they were computed (2026-10-08).
- `windows/CMakeLists.txt`: the switch `IMMUCH360_LIBMPV_FROM_CI`. Off by default: the 2024 archive of
  `media-kit/libmpv-win32-video-cmake`. On: the archive of a `libmpv-windows-*` release of `freeKC/Immuch360`, built by
  `.github/workflows/immuch360-libmpv.yml` (plan 20-plan-desktop.md, 2.4, V-LIBMPV) and pinned by
  `IMMUCH360_LIBMPV_TAG`, the archive names and their SHA-256, which stay empty until that workflow has published its
  first release (the run summary prints the lines to paste); turning the switch on before that stops the configure with
  a message. The environment variable of the same name overrides the default for one build
  (`IMMUCH360_LIBMPV_FROM_CI=1 win_flutter.sh --env IMMUCH360_LIBMPV_FROM_CI build windows ...`).
- `windows/CMakeLists.txt`: `zlib.dll` of `ANGLE.7z` is no longer bundled. That file is a debug build (it imports
  `VCRUNTIME140D.dll` and `ucrtbased.dll`, absent from a Windows without Visual Studio) and no file of the folder
  imports it or names it; `.github/desktop/windows_bundle.py` refuses a debug runtime, so no ZIP could be made with it.
- `windows/CMakeLists.txt`: the extracted `libmpv` folder is marked `.immuch360-<SHA-256 of its archive>`; a folder
  without the mark of the current archive is removed and extracted again, so a change of archive never bundles the
  DLL of the previous one (the folder is reused across builds of the same build directory).

Known limit, not changed here: `ANGLE.7z` holds x64 DLLs only, and the recipes of media-kit and of the fork build the
arm64 libmpv without OpenGL (`-Dgl=disabled -Degl-angle=disabled` for aarch64), so a Windows arm64 build of the app
would link `media_kit_video` against x64 import libraries; arm64 video needs an arm64 ANGLE and an arm64 libmpv with
OpenGL first (phase 4).
