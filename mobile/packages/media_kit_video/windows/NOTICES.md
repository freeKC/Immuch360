# Notices: the native libraries of the video player of Immuch360 Desktop on Windows

The Windows build of Immuch360 places the files below next to `immuch360.exe`. `media_kit_libs_windows_video`
(`mobile/packages/media_kit_libs_windows_video/windows/CMakeLists.txt`) downloads them, checks each archive by its
SHA-256 and bundles them; this plugin, `media_kit_video`, draws the frames they decode. Both plugins are MIT (`LICENSE`
in each package); Immuch360 itself is AGPL-3.0 (`LICENSE` at the root of the repository).

| File | What it is | Licence |
|---|---|---|
| `libmpv-2.dll` | mpv's player library, with FFmpeg and the libraries listed below linked into it | GNU LGPL version 3 or later as a whole (below) |
| `libEGL.dll`, `libGLESv2.dll` | ANGLE, OpenGL ES over Direct3D 11 | BSD-3-Clause |
| `vk_swiftshader.dll`, `vulkan-1.dll` | SwiftShader and the Vulkan loader, shipped with that ANGLE build | Apache-2.0 |
| `d3dcompiler_47.dll` | Microsoft's HLSL compiler, used by ANGLE | Microsoft, redistributable file of the Windows SDK |

The ANGLE files come from `ANGLE.7z` v1.0.1 of `alexmercerind/flutter-windows-ANGLE-OpenGL-ES` (SHA-256
`cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a`), built for x64 only.

The folder and the ZIP of the Windows build carry this file and the licence texts it refers to, in `licenses/`:
`LGPL-3.0.txt` and `GPL-3.0.txt` (`libmpv-2.dll`), `Apache-2.0.txt` (SwiftShader, the Vulkan loader and the Apache-2.0
libraries inside `libmpv-2.dll`) and `ANGLE-BSD-3-Clause.txt` (ANGLE). `.github/desktop/windows_bundle.py` copies them
from the `licenses/` folder next to this file. With the fork's build of libmpv, the archive's own `licenses/` (one folder
per library) and its `BUILDINFO.txt` go into `licenses/libmpv/` as well.

## libmpv-2.dll

### Which build the app carries

| Switch `IMMUCH360_LIBMPV_FROM_CI` | Archive | Versions |
|---|---|---|
| off (the default until the first published run) | `mpv-dev-x86_64-20241021-git-0f78584.7z`, SHA-256 `e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007` (arm64: `mpv-dev-aarch64-20241021-git-0f78584.7z`, `d445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae`), release `20241021` of `media-kit/libmpv-win32-video-cmake` | mpv v0.39.0-179-g0f78584518, FFmpeg N-117622-g8d940a07d (as the library reports them) |
| on | the archives of a `libmpv-windows-*` release of `freeKC/Immuch360`, built by `.github/workflows/immuch360-libmpv.yml` and pinned by the SHA-256 of that release's `SHA256SUMS.txt` | in that release's `BUILDINFO-x86_64.txt` and `BUILDINFO-aarch64.txt` |

### Licence

- **mpv** is built with `-Dgpl=false`, which leaves out the files that are GPL only: the library is under the GNU
  Lesser General Public License version 2.1 or later (mpv's `Copyright` file).
- **FFmpeg** is configured with `--disable-gpl --disable-nonfree --enable-version3`. Its code is LGPL version 2.1 or
  later; `--enable-version3` makes FFmpeg as built "LGPL version 3 or later", the version of the LGPL that can be
  combined with OpenSSL 3 (Apache-2.0), linked into the same file for HTTPS. media_kit's own archives are configured the
  same way.
- **The other libraries** linked into the DLL (below) are under the LGPL 2.1 or later or under permissive licences,
  all of which can be combined under version 3 of the LGPL.

So `libmpv-2.dll` is distributed under the GNU Lesser General Public License version 3 or later
(https://www.gnu.org/licenses/lgpl-3.0.html, which adds to the GPL version 3,
https://www.gnu.org/licenses/gpl-3.0.html), each part keeping its own licence and copyright. Immuch360 uses the library only through mpv's C API, loaded at run time
(`media_kit` opens `libmpv-2.dll` by name), which the LGPL allows for a program under any licence.

### Your rights

- **Use another build of the library.** In the ZIP build of the app, `libmpv-2.dll` can be replaced by your own build of
  mpv's library (client API 2), for example one made from the sources below with your changes; the app loads
  whichever `libmpv-2.dll` sits next to `immuch360.exe`.
- **Get the corresponding source.**
  - Build of the fork (switch on): each `libmpv-windows-*` release carries `<tag>-sources.tar.xz`, the
    sources of every library built for the DLL at the commits listed in `BUILDINFO-<arch>.txt`, together with the
    build recipe at its commit and the two files of `.github/desktop/libmpv/` that set the options of FFmpeg and mpv.
    Every library is built at the commit pinned in `.github/desktop/libmpv/sources.lock`, so running the workflow
    again, or the same commands on a Linux machine with the container it names, rebuilds the DLL from the same code.
  - media-kit's 2024 archive (switch off): mpv at commit `0f78584518` (https://github.com/mpv-player/mpv) and FFmpeg at
    commit `8d940a07d` (https://github.com/FFmpeg/FFmpeg), built by the recipe `media-kit/libmpv-win32-video-cmake` at
    commit `8ddbe54` (tag `20241021`); that recipe took the other libraries from their repositories as they were on
    2024-10-21 and media-kit published no list of their commits. The fork keeps no copy of those sources, one of the
    reasons the fork's own build is meant to replace this archive before a public release: `windows_bundle.py`
    refuses a ZIP for a release that carries it, unless the owner decides otherwise (`--accept-2024-libmpv`).

### Libraries built into the DLL

The fork's build recipe compiles these projects for the DLL (the list is that of the Windows x64 build; arm64 has the
same without the NVIDIA headers). The linker keeps only the code that mpv and the enabled FFmpeg components reach, so
some of them (marked "build only") contribute nothing to the file; they are listed because their sources are part of the
published source archive. The full licence texts are in the `licenses/` folder of each archive of the fork's build.

| Project | Licence (SPDX) | Used for |
|---|---|---|
| mpv | LGPL-2.1-or-later (built with `-Dgpl=false`) | the player |
| FFmpeg | LGPL-2.1-or-later code, LGPL-3.0-or-later as configured | demuxing, decoding, network protocols, filters |
| libplacebo | LGPL-2.1-or-later | mpv's video renderer |
| FriBidi | LGPL-2.1-or-later | subtitle text direction |
| libsoxr | LGPL-2.1-or-later | audio resampling |
| libssh | LGPL-2.1-or-later | build only (SFTP protocol not enabled) |
| GNU libiconv | LGPL-2.1-or-later | character sets of subtitles |
| uchardet | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later | subtitle encoding detection |
| libass | ISC | subtitles |
| FreeType | FTL OR GPL-2.0-or-later (used under the FTL) | fonts of subtitles |
| HarfBuzz | MIT | text shaping of subtitles |
| Fontconfig | MIT-style (Fontconfig `COPYING`) | font lookup |
| libunibreak | Zlib | line breaking of subtitles |
| Expat | MIT | Fontconfig configuration |
| Brotli | MIT | WOFF2 fonts, compression in OpenSSL |
| zlib-ng | Zlib | compression |
| bzip2 | bzip2-1.0.6 | compressed fonts in FreeType when present at its build (FFmpeg's bzlib is disabled) |
| Zstandard | BSD-3-Clause OR GPL-2.0-only (used under BSD-3-Clause) | compression in OpenSSL |
| libpng | libpng-2.0 | PNG glyphs of fonts |
| libjpeg-turbo | IJG AND BSD-3-Clause AND Zlib | JPEG screenshots |
| Little CMS 2 | MIT | colour management |
| OpenSSL | Apache-2.0 | HTTPS and TLS |
| dav1d | BSD-2-Clause | AV1 decoding |
| libxml2 | MIT | DASH manifests |
| Intel libvpl | MIT | Intel Quick Sync dispatch |
| libjxl | BSD-3-Clause | build only (JPEG XL not enabled) |
| Highway | Apache-2.0 OR BSD-3-Clause | build only (used by libjxl) |
| libwebp | BSD-3-Clause | build only (FFmpeg's own WebP decoder is used) |
| zimg, graphengine | WTFPL | build only (zscale filter not enabled) |
| libbs2b | MIT | build only (filter not enabled) |
| libmysofa | BSD-3-Clause | build only (filter not enabled) |
| Speex | BSD-3-Clause | build only (decoder not enabled) |
| Ogg, Vorbis, Opus (and its model data) | BSD-3-Clause | build only (FFmpeg's own decoders are used) |
| libmodplug | public domain | build only |
| SRT | MPL-2.0 | build only (protocol not enabled) |
| OpenAL Soft | LGPL-2.0-or-later | build only (OpenAL output disabled in mpv) |
| SDL2 | Zlib | FFmpeg's SDL output device |
| shaderc | Apache-2.0 | shader compilation for libplacebo |
| glslang | BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0 (glslang `LICENSE.txt`) | shader compilation |
| SPIRV-Tools | Apache-2.0 | shader compilation |
| SPIRV-Cross | Apache-2.0 | shader translation for Direct3D 11 |
| SPIRV-Headers | MIT | headers |
| Vulkan-Loader, Vulkan-Headers | Apache-2.0 | libplacebo's Vulkan support (mpv's Vulkan output disabled) |
| glad | MIT (generator) and Apache-2.0 (Khronos registry) | OpenGL loader of libplacebo |
| fast_float | Apache-2.0 OR BSL-1.0 OR MIT | number parsing in libplacebo |
| xxHash | BSD-2-Clause | hashing in libplacebo |
| ANGLE headers | BSD-3-Clause | EGL headers |
| AMF headers | MIT | AMD AMF, loaded at run time when present |
| nv-codec-headers | MIT | NVIDIA decoding, loaded at run time when present (x64) |
| AviSynth+ headers | GPL-2.0-or-later with a linking exception | build only (AviSynth not enabled) |
| mingw-w64 runtime and winpthreads | ZPL-2.1, MIT, BSD-3-Clause and public domain parts | C runtime start-up, threads |
| LLVM libc++, libunwind, compiler-rt | Apache-2.0 WITH LLVM-exception | C++ runtime |

media-kit's 2024 archive comes from the same recipe family with nearly the same options: FFmpeg with the same licence
switches and fewer filters, mpv with its Vulkan output and with libarchive (BSD-2-Clause, reading videos inside
archives), which the fork's build leaves out.

### Credits some of these licences ask for

- Portions of this software are copyright © The FreeType Project (https://freetype.org). All rights reserved.
- This software is based in part on the work of the Independent JPEG Group.

These two sentences go into the documentation of the app (its about box or the README of the package) when the
Windows build is published.

## Dart code compiled into the app

`media_kit` (MIT, `mobile/packages/media_kit/LICENSE`) carries a copy of `package:ffi` 1.2.1 in its `lib/ffi/`, compiled
into `data/app.so` with the rest of the app's Dart code. Its licence, also in `mobile/packages/media_kit/lib/ffi/LICENSE`:

    Copyright 2019, the Dart project authors.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:

        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above
          copyright notice, this list of conditions and the following
          disclaimer in the documentation and/or other materials provided
          with the distribution.
        * Neither the name of Google LLC nor the names of its
          contributors may be used to endorse or promote products derived
          from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
