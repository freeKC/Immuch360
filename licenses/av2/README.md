# The AV2 decoder of Immuch360 Desktop

Immuch360 Desktop plays AV2 videos (`.ivf`, `.obu`) with `immuch360-av2`, a small program of ours that decodes them
with the library of [dav2d](https://code.videolan.org/videolan/dav2d) (VideoLAN) and serves the pictures to the video
player of the app on 127.0.0.1 only. It is not part of the app: the app downloads it the first time an AV2 video plays,
as an archive our CI built from the sources (`.github/workflows/immuch360-desktop.yml`, jobs `av2-windows`, `av2-linux`
and `av2-macos`; `.github/desktop/av2/av2_build.py`).

| Code | Where | Licence | Text in the archive |
|---|---|---|---|
| dav2d | https://code.videolan.org/videolan/dav2d at the commit of `.github/desktop/av2/av2.lock.json`, built as a static library without its command line tools | BSD 2-Clause | `dav2d-COPYING.txt` (its `COPYING`) |
| `x86inc.asm` of the x264 project, part of dav2d | `src/ext/x86/x86inc.asm` of dav2d | ISC | `x86inc-ISC.txt` (its header) |
| The patent licence AV2 implementations come with | `doc/PATENTS` of dav2d | Alliance for Open Media Patent License 1.0 | `AOM-PATENTS.txt` |
| immuch360-av2 | `mobile/native/av2` of Immuch360 | AGPL 3.0, the licence of this repository | `immuch360-av2-AGPL-3.0.txt` and `immuch360-av2-SOURCE.txt` (where its source is, at the commit built) |
| immuch360-run, the launcher of the Linux archive | `.github/desktop/ai/immuch360_run.c` of Immuch360 | MIT | `immuch360-run-MIT.txt` |

Nothing under the GPL is built in: the jobs read the dynamic libraries and the imports of each program (only those of
the system), look for the strings of GPL code in it, and compare every licence text of the archive with the sources it
was built from; a licence of the lock outside the permissive list (`permissive` in the lock) fails the job.

The three texts of dav2d in this folder are copies of its files at the commit of the lock; `av2_build.py licences`
compares them with the sources at each build, and with the SHA-256 the lock gives. `AOM-PATENTS.txt` is the patent
licence as dav2d ships it (`doc/PATENTS`): the same text as the `PATENTS` file of AVM v1.0.0 and of libaom, but for
typographic quotes and one typo of dav2d's copy ("OTHER PARTRY" for "OTHER PARTY" in section 1.3), kept as it is so
that the archive carries what the code it holds came with.
