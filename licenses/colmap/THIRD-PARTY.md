# Other code built into the COLMAP of Immuch360

The archives `Immuch360-AI-colmap-<lock>-windows-x64.zip` and `-linux-x64.zip` hold `colmap` (on Windows `colmap.exe`
and the runtime DLLs of Visual C++), and on Linux `immuch360-run`. Besides COLMAP (BSD 3 Clause, `COPYING.txt`), the
program holds code of the projects below, built from the sources at the commits of `.github/desktop/ai/colmap.lock.json`
and statically linked. Each licence text is in its own file of this folder, or in `licenses/vcpkg/<port>.txt` of the
archive (the copyright file vcpkg installs with each port).

## Built from the sources of COLMAP

| Code | Where | Licence | Text |
|---|---|---|---|
| VLFeat (SIFT on the processor) | `src/thirdparty/VLFeat` of COLMAP | BSD 2 Clause | `VLFeat-LICENSE.txt` |
| PoissonRecon | `src/thirdparty/PoissonRecon` of COLMAP | MIT | `PoissonRecon-LICENSE.txt` |
| PoseLib | fetched by the CMake of COLMAP at `fa7280fee27f97aff31ae7f98bab7f583fac7d08`, checked by its SHA-256 | BSD 3 Clause | `PoseLib-LICENSE.txt` |
| faiss 1.14.1 | fetched by the CMake of COLMAP at the tag `v1.14.1`, checked by its SHA-256 | MIT | `faiss-LICENSE.txt` |
| libf2c (the runtime of CLAPACK) | port `clapack` of vcpkg | permission notice of AT&T, Lucent and Bellcore | `libf2c-Notice.txt` |

## Libraries of vcpkg

The licence of each port is the one its `vcpkg.spdx.json` gives; the colmap jobs fail when one is out of our list (MIT,
BSD, Apache 2.0, BSL 1.0, MPL 2.0, zlib, IJG, libpng, libtiff, public domain) or when this table differs from what they
installed. Three ports give no licence and were read by hand: `blas` and `lapack`, metapackages without code that select
OpenBLAS and CLAPACK, and `clapack`, LAPACK 3.2.1 translated to C (BSD 3 Clause, its `COPYING`) with libf2c (above).
`vcpkg-cmake`, `vcpkg-cmake-config` and `vcpkg-boost` are build scripts of vcpkg, installed beside the libraries
because the host triplet is the target one, never linked.

<!-- vcpkg ports: written by colmap_build.py table, checked by the colmap jobs -->

| Port | Version | Licence (SPDX of vcpkg) | Systems | Text in the archive |
|---|---|---|---|---|
| `blas` | 2023-04-14#6 | NOASSERTION | linux-x64, windows-x64 | none, a metapackage without code |
| `boost-algorithm` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-algorithm.txt` |
| `boost-align` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-align.txt` |
| `boost-any` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-any.txt` |
| `boost-array` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-array.txt` |
| `boost-assert` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-assert.txt` |
| `boost-atomic` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-atomic.txt` |
| `boost-bimap` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-bimap.txt` |
| `boost-bind` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-bind.txt` |
| `boost-chrono` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-chrono.txt` |
| `boost-cmake` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-cmake.txt` |
| `boost-compat` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-compat.txt` |
| `boost-concept-check` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-concept-check.txt` |
| `boost-config` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-config.txt` |
| `boost-container` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-container.txt` |
| `boost-container-hash` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-container-hash.txt` |
| `boost-conversion` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-conversion.txt` |
| `boost-core` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-core.txt` |
| `boost-date-time` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-date-time.txt` |
| `boost-describe` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-describe.txt` |
| `boost-detail` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-detail.txt` |
| `boost-dynamic-bitset` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-dynamic-bitset.txt` |
| `boost-endian` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-endian.txt` |
| `boost-exception` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-exception.txt` |
| `boost-foreach` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-foreach.txt` |
| `boost-function` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-function.txt` |
| `boost-function-types` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-function-types.txt` |
| `boost-fusion` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-fusion.txt` |
| `boost-graph` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-graph.txt` |
| `boost-headers` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-headers.txt` |
| `boost-heap` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-heap.txt` |
| `boost-integer` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-integer.txt` |
| `boost-intrusive` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-intrusive.txt` |
| `boost-io` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-io.txt` |
| `boost-iterator` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-iterator.txt` |
| `boost-lambda` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-lambda.txt` |
| `boost-lexical-cast` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-lexical-cast.txt` |
| `boost-math` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-math.txt` |
| `boost-move` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-move.txt` |
| `boost-mp11` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-mp11.txt` |
| `boost-mpl` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-mpl.txt` |
| `boost-multi-index` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-multi-index.txt` |
| `boost-multiprecision` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-multiprecision.txt` |
| `boost-numeric-conversion` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-numeric-conversion.txt` |
| `boost-optional` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-optional.txt` |
| `boost-parameter` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-parameter.txt` |
| `boost-phoenix` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-phoenix.txt` |
| `boost-pool` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-pool.txt` |
| `boost-predef` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-predef.txt` |
| `boost-preprocessor` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-preprocessor.txt` |
| `boost-program-options` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-program-options.txt` |
| `boost-property-map` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-property-map.txt` |
| `boost-property-tree` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-property-tree.txt` |
| `boost-proto` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-proto.txt` |
| `boost-random` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-random.txt` |
| `boost-range` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-range.txt` |
| `boost-ratio` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-ratio.txt` |
| `boost-regex` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-regex.txt` |
| `boost-serialization` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-serialization.txt` |
| `boost-smart-ptr` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-smart-ptr.txt` |
| `boost-spirit` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-spirit.txt` |
| `boost-static-assert` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-static-assert.txt` |
| `boost-system` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-system.txt` |
| `boost-thread` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-thread.txt` |
| `boost-throw-exception` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-throw-exception.txt` |
| `boost-tokenizer` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-tokenizer.txt` |
| `boost-tti` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-tti.txt` |
| `boost-tuple` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-tuple.txt` |
| `boost-type-index` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-type-index.txt` |
| `boost-type-traits` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-type-traits.txt` |
| `boost-typeof` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-typeof.txt` |
| `boost-uninstall` | 1.92.0 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/boost-uninstall.txt` |
| `boost-unordered` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-unordered.txt` |
| `boost-utility` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-utility.txt` |
| `boost-variant` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-variant.txt` |
| `boost-variant2` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-variant2.txt` |
| `boost-winapi` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-winapi.txt` |
| `boost-xpressive` | 1.92.0 | BSL-1.0 | linux-x64, windows-x64 | `licenses/vcpkg/boost-xpressive.txt` |
| `ceres` | 2.2.0#6 | Apache-2.0 | linux-x64, windows-x64 | `licenses/vcpkg/ceres.txt` |
| `clapack` | 3.2.1#25 | NOASSERTION | linux-x64, windows-x64 | `licenses/vcpkg/clapack.txt` |
| `eigen3` | 5.0.1 | MPL-2.0 | linux-x64, windows-x64 | `licenses/vcpkg/eigen3.txt` |
| `expat` | 2.8.3 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/expat.txt` |
| `fmt` | 12.2.0#1 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/fmt.txt` |
| `gflags` | 2.3.0 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/gflags.txt` |
| `gklib` | 2023-03-27 | Apache-2.0 | linux-x64, windows-x64 | `licenses/vcpkg/gklib.txt` |
| `glog` | 0.7.1#2 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/glog.txt` |
| `imath` | 3.2.2 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/imath.txt` |
| `lapack` | 2023-06-10#4 | NOASSERTION | linux-x64, windows-x64 | none, a metapackage without code |
| `libdeflate` | 1.25 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/libdeflate.txt` |
| `libjpeg-turbo` | 3.2.0 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/libjpeg-turbo.txt` |
| `libpng` | 1.6.58 | libpng-2.0 | linux-x64, windows-x64 | `licenses/vcpkg/libpng.txt` |
| `metis` | 2022-07-27#1 | Apache-2.0 | linux-x64, windows-x64 | `licenses/vcpkg/metis.txt` |
| `minizip-ng` | 4.1.0 | Zlib | linux-x64, windows-x64 | `licenses/vcpkg/minizip-ng.txt` |
| `openblas` | 0.3.33 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/openblas.txt` |
| `opencolorio` | 2.5.2 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/opencolorio.txt` |
| `openexr` | 3.4.14 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/openexr.txt` |
| `openimageio` | 3.1.14.0#1 | Apache-2.0 | linux-x64, windows-x64 | `licenses/vcpkg/openimageio.txt` |
| `openjph` | 0.31.0 | BSD-2-Clause | linux-x64, windows-x64 | `licenses/vcpkg/openjph.txt` |
| `pystring` | 1.2.0 | BSD-3-Clause | linux-x64, windows-x64 | `licenses/vcpkg/pystring.txt` |
| `robin-map` | 1.4.1 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/robin-map.txt` |
| `sqlite3` | 3.53.4 | blessing | linux-x64, windows-x64 | `licenses/vcpkg/sqlite3.txt` |
| `tiff` | 4.7.2 | libtiff | linux-x64, windows-x64 | `licenses/vcpkg/tiff.txt` |
| `vcpkg-boost` | 2026-08-21 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/vcpkg-boost.txt` |
| `vcpkg-cmake` | 2025-08-07 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/vcpkg-cmake.txt` |
| `vcpkg-cmake-config` | 2026-07-21 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/vcpkg-cmake-config.txt` |
| `yaml-cpp` | 0.9.0#1 | MIT | linux-x64, windows-x64 | `licenses/vcpkg/yaml-cpp.txt` |
| `zlib` | 1.3.2#2 | Zlib | linux-x64, windows-x64 | `licenses/vcpkg/zlib.txt` |

<!-- end of the vcpkg ports -->
