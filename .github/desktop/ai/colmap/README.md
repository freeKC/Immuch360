# vcpkg overlay of the COLMAP of Immuch360

The colmap jobs of `.github/workflows/immuch360-desktop.yml` build the libraries of COLMAP with vcpkg at the commit of
`../colmap.lock.json` (`../colmap_build.py vcpkg`), with the ports of this folder over those of vcpkg:

* `vcpkg-ports/lapack`: the `lapack` metapackage of vcpkg (MIT, https://github.com/microsoft/vcpkg/tree/127402f1c75bb3d5ff6bce04b285faa4930a5aca/ports/lapack)
  changed to take CLAPACK, LAPACK 3.2.1 translated to C, on every system but the Apple ones. The original takes it on
  Windows with static libraries only, and `lapack-reference` elsewhere, whose Fortran brings `libgfortran` (GPL 3 with
  the GCC runtime exception) into the program. COLMAP itself does not call LAPACK: faiss, which COLMAP builds for its
  feature index, asks for it.

Changed from the original: the `$comment` and the dependencies of `vcpkg.json`, and the branch of `portfile.cmake` that
chose `lapack-reference`. `lapack.pc.in` and `vcpkg-cmake-wrapper.cmake.in` are as in vcpkg.
