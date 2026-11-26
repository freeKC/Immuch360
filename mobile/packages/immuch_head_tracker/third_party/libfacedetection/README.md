# libfacedetection in Immuch360

https://github.com/ShiqiYu/libfacedetection, commit `acf7b254121927e7dced30e233a2e03119f28ea2` (28 June 2026, "Merge
pull request #383 from pszemus/fix-sigsegv-in-highway-kernels"), 3-clause BSD licence (`LICENSE`, kept as it is).

Taken unchanged from that commit (the git blob of each file is the one of the commit):

| File | Blob |
|---|---|
| `LICENSE` | `33abd64f061d58b8a25d60c7567b0769d47afb17` |
| `src/facedetectcnn.h` | `bfd0f427c49cc484b852e84cfbd8e63460027267` |
| `src/facedetectcnn.cpp` | `c9cfc78e2e3d5584dfb95e827a4958a943ec5483` |
| `src/facedetectcnn-model.cpp` | `1893e0a4d8baf35e577b4751c7294c574f9cc676` |
| `src/facedetectcnn-data.cpp` (the weights of the network, compiled in) | `7be51a1914fd3fa2080b85dbdec5e5545dfc0e1f` |

Nothing else of the repository is used (no CMake, no OpenCV examples, no Highway or Rust code). The header the
library's CMake would generate, `facedetection_export.h`, is the plugin's own (`../../src/facedetection_export.h`):
the detector DLLs export their own C interface (`../../src/face_detect.h`), not the library's.

The library chooses its SIMD code when it is compiled (`_ENABLE_AVX2`), so `../../windows/CMakeLists.txt` builds it
twice, `immuch_head_tracker_detect.dll` (plain x86_64) and `immuch_head_tracker_detect_avx2.dll` (`/arch:AVX2`), and the
tracker loads one of them after checking the processor.

The notice travels with the app: the licence page of Immuch360 Desktop on Windows shows it (`../../lib/src/licence.dart`,
compared with `LICENSE` by a test), and the Windows ZIP and installer carry `LICENSE` in `licenses/libfacedetection`.

To update: take the same five files from a newer commit, update the commit here and in `../../lib/src/licence.dart`,
and run the native tests (`../../test_native/run.sh`) and the Windows test of the plugin.
