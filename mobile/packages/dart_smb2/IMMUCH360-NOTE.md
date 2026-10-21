# dart_smb2 0.1.3, vendored copy for Immuch360

Copied from pub.dev (BSD-3-Clause, https://github.com/ales-drnz/dart_smb2), without the example and the images, with four changes:

- `lib/src/smb2_client.dart`, `_applyCredentials`: an empty password is passed to libsmb2 (`smb2_set_password("")`) instead of
  being dropped. Dropping it made libsmb2 log on anonymously, which servers such as the Freebox Server refuse for their disk
  shares while they accept the user "freebox" with an empty password. A null password still means an anonymous logon.
- `lib/src/pool/context_lock.dart` (new, exported), `lib/src/pool/pool.dart`: every worker spawn and close of every pool, the
  respawns of the auto-reconnect included, and `Smb2Pool.listSharesOn` run one at a time through `Smb2ContextLock`, a lock for
  the whole isolate. libsmb2 changes its global `active_contexts` list without a lock in `smb2_init_context` and
  `smb2_destroy_context`; upstream only ordered the spawns of one pool, so two pools reconnecting at the same moment (two
  connections to a share after a Wi-Fi change) could corrupt it. The app takes the same lock for its own connects.

- `linux/CMakeLists.txt`: the environment variable `IMMUCH360_LIBSMB2` names a `libsmb2.so` to bundle instead of the
  release's, which is then not downloaded. The `libsmb2_linux-x86_64.so` of release `libsmb2-r8` asks glibc 2.38 for one
  function, `__isoc23_strtol` (what `strtol` becomes when compiled against the headers of glibc 2.38 or later), so SMB
  shares did not open on Ubuntu 22.04 and Debian 12 (glibc 2.35 and 2.36). The Linux job of the desktop workflow builds
  the same library again on Ubuntu 22.04 with `.github/desktop/libsmb2/build_linux.sh`, from the archive of its sources
  (below): the sources of the release are those of `ales-drnz/libsmb2-scripts` at its version 0.1.3 (commit
  `f0688e739ec5`), which pins libsmb2 at commit `595d128b4d11` by the SHA-256 of its archive and applies its patches;
  the script builds offline and checks that the library exports the same 515 symbols as the release's and asks no glibc
  version above 2.34 (it asks 2.25 at most). libsmb2 is under the LGPL 2.1 or later, loaded at run time and replaceable;
  its sources are those two public commits. Checked on 2026-10-20: the library built by the script in an `ubuntu:22.04`
  container asks glibc 2.25 at most and its `ldd` finds everything on Ubuntu 22.04 (glibc 2.35) and Debian 12 (2.36);
  the Samba tests of `test/infrastructure/network/smb_file_system_test.dart` (`IMMUCH_NET_TESTS=1`, `IMMUCH_LIBSMB2`
  pointing at that library) pass, 14 of 14 (the listing, the reads and the errors, then the streaming through the media
  bridge). Without the variable (a build on a developer's machine) the release's library is downloaded as before.

- `libsmb2/` (new) and `pubspec.yaml` (`flutter: assets`): the notice of libsmb2 (`NOTICE`: copyright, the build each
  system carries, the patches of libsmb2-scripts, where the source is, the other notices inside libsmb2) with libsmb2's
  own `COPYING` and `LICENCE-LGPL-2.1.txt`, both copied unchanged from libsmb2 at commit `595d128b4d11`. dart_smb2's
  `LICENSE` covers its BSD code only and Flutter's licence page lists nothing else of the package, so every build
  carries these files as assets of the package and `lib/utils/libsmb2_license.dart` shows the notice and the LGPL on
  the app's licence page; the desktop packages also copy them (`licenses/libsmb2/` of the Windows folder, the
  copyright file of the `.deb`, `/usr/share/licenses/immuch360/libsmb2/` of the `.rpm`). dart_smb2 0.2.x adds a
  `NOTICE` of its own for the same reason. Its YOUR RIGHTS part says how to build with another libsmb2: iOS and macOS
  take the package through Swift Package Manager, so there the pins are `ios/dart_smb2/Package.swift` and
  `macos/dart_smb2/Package.swift`, whose `smb2kit:remote` block is swapped for the `smb2kit:local` one (the framework in
  `Frameworks/libsmb2.xcframework` next to it); the podspecs serve a CocoaPods build only.

- `libsmb2/Immuch360-libsmb2-sources.tar.gz` (not in git): the corresponding source of every libsmb2 of the app, so
  that each build carries it next to the binary, the store builds included. `.github/desktop/libsmb2/pack_sources.py`
  packs it from the pinned commits only (libsmb2-scripts `f0688e739ec5` as git stores it, the libsmb2 archive it pins
  in its cache, the Linux build script and a README), the same way each time; the task `codegen:libsmb2-sources` of
  `mobile/mise.toml` runs it, so `mise //mobile:codegen` writes it before any build, on the CI (phone release,
  desktop, Codemagic) and on a developer's machine alike, and git ignores it. A build without it still works, without
  the archive: the CI checks that the APKs, the Windows ZIP, the `.deb` and the macOS app hold it. The Linux job of the
  desktop workflow builds `libsmb2.so` from that same file, offline, and each release attaches it
  (`Immuch360-libsmb2-sources.tar.gz` on the phone releases, `Immuch360-Desktop-<version>-libsmb2-sources.tar.gz` on
  the desktop ones). The licence page entry and `NOTICE` say where it is in each package and how to extract it.

The binaries of release `libsmb2-r8` are built from the sources named above (libsmb2-scripts `f0688e739ec5`, libsmb2
`595d128b4d11`), which the notice gives as their corresponding source. Checked on 2026-10-21 by building them again:
the Linux x86_64 library, built by the scripts' Linux build in an `ubuntu:24.04` container (GCC 13.3.0, the image of
their `docker/Dockerfile`), has the release's SHA-256 (`78f1a94a...`); the three Android libraries, built with NDK
28.2.13676358 (the version the scripts pin), have the release's SHA-256 (the files of `android/src/main/jniLibs`) once
linked in the order their symbol table records; the Windows x86_64 DLL, built with llvm-mingw 20240619 (that
Dockerfile), differs from the release's only by its link timestamp (2026-09-17 16:09:24 UTC, written twice). The iOS
and macOS frameworks were not rebuilt (no Mac): they export the same 515 functions as the Linux library plus the two
of the Apple-only code (`aes_apple.c`). After that build, libsmb2-scripts changed only its changelog until
`f0688e739ec5`, whose changelog says "dart_smb2 0.1.3, binaries libsmb2-r8".

Everything else is the upstream package. Remove this copy and the `dependency_overrides` entry of `mobile/pubspec.yaml` once
upstream accepts equivalent changes.
