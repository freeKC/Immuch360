Copy of `media_kit_libs_macos_video` 1.1.5 (MIT, https://github.com/media-kit/media-kit, folder
`libs/macos/media_kit_libs_macos_video`) at commit `c533e446755f51cf53c7e57aea873f2aa5355f81` of `main`, the commit the
other media-kit copies of `mobile/packages` come from. Used by Immuch360 Desktop as a path dependency of
`mobile/pubspec.yaml`; its plugin declares macos only, so the phone builds register nothing of it. The MIT notice is in
`LICENSE`; the licences of the libraries it brings into the app are in
`macos/media_kit_libs_macos_video/Sources/media_kit_libs_macos_video/licenses/NOTICES.md`.

What differs from upstream, to apply again when a newer commit is copied here:

- The frameworks are the fork's own build, not media-kit's: `Package.swift` downloads the xcframeworks of a
  `libmpv-macos-*` release of `freeKC/Immuch360`, made by `.github/workflows/immuch360-libmpv.yml` from pinned sources
  that the release publishes with them (`<tag>-sources.tar.xz`), and checks each zip by its SHA-256. The pins are the
  lines between `IMMUCH360_LIBMPV_PINS_BEGIN` and `IMMUCH360_LIBMPV_PINS_END`, pasted from the summary of the release
  run. Upstream pins `media-kit/libmpv-darwin-build` v0.7.2 (FFmpeg 6.0 and mpv 0.36 of 2023, older than the FFmpeg
  security fixes since, for an app that opens files and streams it does not control); the fork's build has FFmpeg and
  mpv at the commits of its Windows build, and libplacebo, which mpv needs since 0.37 (`Placebo.framework`).
- `Package.swift`: the targets are the keys of the checksums, so a release that adds or drops a library needs no other
  change; `licenses/` is a resource of the package, so every build of the app carries the notices and licence texts
  of the libraries.
- No podspec, no `Makefile` and no `create_framework_symlinks.sh`: the macOS app is built with Swift Package Manager
  (Flutter's default; `mobile/macos` has no Podfile), and the podspec path of upstream downloads media-kit's
  frameworks.
- `pubspec.yaml`: no `resolution: workspace`, no `plugin_platform_interface` (nothing of it is used), no dev
  dependencies; `publish_to: none`, version `1.1.5+immuch360`.
- No `example/`, `README.md` or `CHANGELOG.md`.

Updating the libraries: run `immuch360-libmpv.yml` with `systems` set to `macos` (FFmpeg and mpv come from
`.github/desktop/libmpv-macos/packages.lock.nix`), then paste the lines of its summary into `Package.swift`, and refresh
`licenses/libmpv/` from the release's `<tag>-licenses.tar.gz` and `BUILDINFO-macos.txt`.
