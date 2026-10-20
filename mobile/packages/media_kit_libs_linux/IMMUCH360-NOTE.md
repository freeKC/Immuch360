Copy of `media_kit_libs_linux` 1.2.1 (MIT, https://github.com/media-kit/media-kit, folder
`libs/linux/media_kit_libs_linux`) at commit `c533e446755f51cf53c7e57aea873f2aa5355f81` of `main` (2026-08-30), the
commit of the copies of `media_kit`, `media_kit_video` and `media_kit_libs_windows_video`; its code is that of the
pub.dev release 1.2.1. Used by Immuch360 Desktop through `dependency_overrides` in `mobile/pubspec.yaml`. The MIT
notice is in `LICENSE`, as upstream has it.

What it does: its plugin declares linux only, so the phones and the other computers register nothing of it. Its CMake
sets `MEDIA_KIT_LIBS_AVAILABLE`, which makes `media_kit_video` compile its real Linux plugin instead of a stub, and its
plugin sets `LC_NUMERIC` to `C` when it is registered, after GTK set the locale of the user: libmpv refuses to start in
a locale whose decimal separator is not a dot. It bundles nothing: libmpv is the system's (`libmpv2` or `libmpv1`,
`mpv-libs` on Fedora), a dependency of the .deb and the .rpm (`.github/desktop/desktop_installers.py`), opened at run
time by `media_kit` and by `media_kit_video` (its IMMUCH360-NOTE.md, patch 8). The app thus carries no copy of libmpv
on Linux, and the user's distribution updates it.

What differs from upstream, to apply again when a newer commit is copied here:

- `pubspec.yaml`: no `resolution: workspace`, no dev dependencies; `publish_to: none`, version `1.2.1+immuch360`.
- `linux/CMakeLists.txt`: upstream's mimalloc is left out. With `MIMALLOC_USE_STATIC_LIBS` on, its default, upstream
  downloads the mimalloc 2.1.2 archive from GitHub at configure time (checked by MD5 only) and builds it, for an app
  that links `MIMALLOC_LIB` into its executable by hand (upstream's README), which `mobile/linux/CMakeLists.txt` does
  not do: the download was of no use to the app.
- Left out: `example/`, `analysis_options.yaml`.
