# dart_smb2 0.1.3, vendored copy for Immuch360

Copied from pub.dev (BSD-3-Clause, https://github.com/ales-drnz/dart_smb2), without the example and the images, with three changes:

- `lib/src/smb2_client.dart`, `_applyCredentials`: an empty password is passed to libsmb2 (`smb2_set_password("")`) instead of
  being dropped. Dropping it made libsmb2 log on anonymously, which servers such as the Freebox Server refuse for their disk
  shares while they accept the user "freebox" with an empty password. A null password still means an anonymous logon.
- `lib/src/pool/context_lock.dart` (new, exported), `lib/src/pool/pool.dart`: every worker spawn and close of every pool, the
  respawns of the auto-reconnect included, and `Smb2Pool.listSharesOn` run one at a time through `Smb2ContextLock`, a lock for
  the whole isolate. libsmb2 changes its global `active_contexts` list without a lock in `smb2_init_context` and
  `smb2_destroy_context`; upstream only ordered the spawns of one pool, so two pools reconnecting at the same moment (two
  connections to a share after a Wi-Fi change) could corrupt it. The app takes the same lock for its own connects.

- `linux/CMakeLists.txt`: the environment variable `IMMUCH360_LIBSMB2` names a `libsmb2.so` to bundle instead of the
  release's, which is then not downloaded. The `libsmb2_linux-x86_64.so` of release `libsmb2-r8` asks glibc 2.38 for
  one function, `__isoc23_strtol` (what `strtol` becomes when compiled against the headers of glibc 2.38 or later), so
  SMB shares did not open on Ubuntu 22.04 and Debian 12 (glibc 2.35 and 2.36). The Linux job of the desktop workflow
  builds the same library again on Ubuntu 22.04 with `.github/desktop/libsmb2/build_linux.sh`: the sources of the
  release are those of `ales-drnz/libsmb2-scripts` at its version 0.1.3 (commit `f0688e739ec5`), which pins libsmb2 at
  commit `595d128b4d11` by the SHA-256 of its archive and applies its patches; the script checks that the library
  exports the same 515 symbols as the release's and asks no glibc version above 2.34 (it asks 2.25 at most). libsmb2 is
  under the LGPL 2.1 or later, loaded at run time and replaceable; its sources are those two public commits. Checked on
  2026-10-20: the library built by the script in an `ubuntu:22.04` container asks glibc 2.25 at most and its `ldd` finds
  everything on Ubuntu 22.04 (glibc 2.35) and Debian 12 (2.36); the Samba tests of
  `test/infrastructure/network/smb_file_system_test.dart` (`IMMUCH_NET_TESTS=1`, `IMMUCH_LIBSMB2` pointing at that
  library) pass, 14 of 14 (the listing, the reads and the errors, then the streaming through the media bridge). Without
  the variable (a build on a developer's machine) the release's library is downloaded as before.

Everything else is the upstream package. Remove this copy and the `dependency_overrides` entry of `mobile/pubspec.yaml` once
upstream accepts equivalent changes.
