# COLMAP in Immuch360

The splat scenes of Immuch360 Desktop ("Make a splat scene (AI)") place the photos or the frames of a video in 3D with
COLMAP, run as a child process (`colmap`), on the processor only. It is not part of the app: the app downloads it when
the user installs the components of the splat scenes, as an archive our CI built from the sources
(`.github/workflows/immuch360-desktop.yml`, jobs `colmap-windows` and `colmap-linux`; `.github/desktop/ai/colmap_build.py`).

* COLMAP, BSD 3 Clause: https://github.com/colmap/colmap at the commit of `.github/desktop/ai/colmap.lock.json` (tag
  4.2.1), its licence in `COPYING.txt`.
* Our changes to its sources, in `patches/`: `0001-without-cholmod.patch` makes CHOLMOD optional (`CHOLMOD_ENABLED`),
  so that the sparse Cholesky factorization of COLMAP goes through Eigen's `SimplicialLDLT` instead of CHOLMOD's
  supernodal module (GPL 2 or later); `0002-vcpkg-without-suitesparse.patch` builds Ceres with Eigen's sparse solvers
  instead of SuiteSparse and LAPACK, takes BLAS and LAPACK as faiss needs them, and drops JasPer, which nothing of our
  build uses. Eigen's sparse Cholesky and AMD ordering, which take over, are under the MPL 2.0 like the rest of Eigen
  (their headers say that Timothy A. Davis, author of the LDL and CSparse code they come from, licensed it to Google
  LLC for Eigen under the MPL 2.0; read in Eigen 3.4.1 on 2026-11-01).
* Left out of our build, where the official binaries of COLMAP have them: the graphical interface (Qt, LGPL 3),
  OpenGL and SiftGPU (educational, research and non-profit use only), LSD (AGPL 3), CGAL (GPL 3 parts) with GMP and
  MPFR, CHOLMOD and SPQR of SuiteSparse (GPL 2 parts), CUDA, ONNX Runtime and the learned features, the dense
  reconstruction, the downloads (curl, OpenSSL) and the vocabulary trees, which come with no licence. The CI fails when
  a file, an import or a string of any of them is found in the archive.
* The other code built into COLMAP and the libraries of vcpkg: `THIRD-PARTY.md`.
* On Windows, the archive holds the Visual C++ and OpenMP runtime DLLs of Microsoft (`vcruntime140.dll`,
  `vcruntime140_1.dll`, `msvcp140.dll`, `vcomp140.dll`), redistributable under the licence of Visual Studio, as the
  archive of `sd-cli` and the app itself do. On Linux, `immuch360-run`, the launcher of the app (MIT, its source in
  `.github/desktop/ai/immuch360_run.c`), and the program needs `libgomp.so.1`, the OpenMP runtime of GCC (GPL 3 with
  the GCC Runtime Library Exception, like `libstdc++`), from the system.

Every file of this folder goes into the `licenses/` folder of both archives, with the copyright file of every port of
vcpkg in `licenses/vcpkg/`; the job that packs them checks that the texts of COLMAP, VLFeat, PoissonRecon, PoseLib and
faiss here are those of the sources it built.
