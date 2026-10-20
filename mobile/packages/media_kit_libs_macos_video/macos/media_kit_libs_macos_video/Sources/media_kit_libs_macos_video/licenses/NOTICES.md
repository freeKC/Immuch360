# Notices: the native libraries of the video player of Immuch360 Desktop on macOS

The macOS build of Immuch360 places the frameworks below in `Immuch360 Desktop.app/Contents/Frameworks`.
`media_kit_libs_macos_video` (`mobile/packages/media_kit_libs_macos_video`, MIT) downloads them through Swift Package
Manager, which checks each one by its SHA-256, and `media_kit_video` (MIT) draws the frames they decode. Immuch360
itself is AGPL-3.0 (`LICENSE` at the root of the repository). This file and the licence texts next to it are in the
app, in `Contents/Resources/media_kit_libs_macos_video_media_kit_libs_macos_video.bundle/Contents/Resources/licenses/`.

## Which build the app carries

The frameworks of a `libmpv-macos-*` release of https://github.com/freeKC/Immuch360, built by
`.github/workflows/immuch360-libmpv.yml` of that repository for macOS 12 and later, arm64 and x86_64 in each framework.
The release named in `Package.swift` (`libmpvTag`) lists every library with its version and the SHA-256 of its source
archive in `BUILDINFO-macos.txt`, also copied in `libmpv/` next to this file.

The recipe is media-kit's own (https://github.com/media-kit/libmpv-darwin-build, a Nix build) at a pinned commit, with
the files of `.github/desktop/libmpv-macos/` over it: FFmpeg, mpv, libplacebo, fast_float and the Vulkan headers at the
commits of the Windows build of the app, the other libraries at the versions of the recipe, libpng with one line
changed for the SDK of Xcode 16, mpv with its macOS clipboard left out (it needs mpv's Swift part, which this build does
not make).

## Licence

- **mpv** is built with `-Dgpl=false`, which leaves out the files that are GPL only: the library is under the GNU
  Lesser General Public License version 2.1 or later (mpv's `Copyright` file).
- **FFmpeg** (`Avcodec`, `Avfilter`, `Avformat`, `Avutil`, `Swresample`, `Swscale`) is configured with
  `--enable-version3` and without `--enable-gpl` or `--enable-nonfree`. Its code is LGPL version 2.1 or later;
  `--enable-version3` makes FFmpeg as built "LGPL version 3 or later", the version of the LGPL that can be combined with
  Mbed TLS (Apache-2.0), which FFmpeg uses for HTTPS.
- **The other libraries** (below) are under the LGPL 2.1 or later or under permissive licences, all of which can be
  combined under version 3 of the LGPL.

So these frameworks are distributed under the GNU Lesser General Public License version 3 or later (`LGPL-3.0.txt`,
which adds to the GPL version 3, `GPL-3.0.txt`), each part keeping its own licence and copyright. Immuch360 uses them
only through mpv's C API: `media_kit` opens `Mpv.framework/Mpv` at run time, which the LGPL allows for a program under
any licence.

## Your rights

- **Use another build of the libraries.** The frameworks are separate files inside the app. You can replace them with
  your own build of the same libraries (mpv's client API 2), for example one made from the sources below with your
  changes, with the same framework names; then sign the app again for your computer
  (`codesign --force --deep --sign - "Immuch360 Desktop.app"`), as macOS refuses an app whose files changed after it
  was signed. To build the app itself with your frameworks, point `Package.swift` at your own zips.
- **Get the corresponding source.** Each `libmpv-macos-*` release carries `<tag>-sources.tar.xz`: the recipe at its
  commit with the files of `.github/desktop/libmpv-macos/` applied, and every source archive it builds from, each
  checked by the SHA-256 that `packages.lock.nix` pins. Running the workflow again, or the recipe's `make` on a Mac with
  Nix and the Xcode named in `BUILDINFO-macos.txt`, rebuilds the frameworks from the same code. The licence texts of
  each library, as its sources hold them, are in `<tag>-licenses.tar.gz` and in `libmpv/` next to this file.

## Libraries in the frameworks

| Framework | Project | Licence (SPDX) | Used for |
|---|---|---|---|
| `Mpv` | mpv | LGPL-2.1-or-later (built with `-Dgpl=false`) | the player |
| `Avcodec`, `Avfilter`, `Avformat`, `Avutil`, `Swresample`, `Swscale` | FFmpeg | LGPL-2.1-or-later code, LGPL-3.0-or-later as configured | demuxing, decoding (VideoToolbox on the GPU), network protocols, filters |
| `Placebo` | libplacebo | LGPL-2.1-or-later | mpv's video renderer |
| `Fribidi` | GNU FriBidi | LGPL-2.1-or-later | subtitle text direction |
| `Uchardet` | uchardet | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later | subtitle encoding detection |
| `Ass` | libass | ISC | subtitles |
| `Freetype` | FreeType | FTL OR GPL-2.0-or-later (used under the FTL) | fonts of subtitles |
| `Harfbuzz` | HarfBuzz | MIT | text shaping of subtitles |
| `Png16` | libpng | libpng-2.0 | PNG glyphs of fonts |
| `Dav1d` | dav1d | BSD-2-Clause | AV1 decoding |
| `Xml2` | libxml2 | MIT | DASH manifests |
| `Mbedtls`, `Mbedx509`, `Mbedcrypto` | Mbed TLS | Apache-2.0 (`Apache-2.0.txt`) | HTTPS and TLS |
| none (built in) | fast_float | Apache-2.0 OR BSL-1.0 OR MIT | number parsing in libplacebo (header only) |
| none (built in) | Vulkan-Headers | Apache-2.0 OR MIT | headers of libplacebo's Vulkan stubs (Vulkan is off) |

### Credits some of these licences ask for

- Portions of this software are copyright © The FreeType Project (https://freetype.org). All rights reserved.
