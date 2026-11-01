# Brush in Immuch360

The splat scenes of Immuch360 Desktop ("Make a splat scene (AI)") are trained by Brush on the graphics card, through
Vulkan, run as a child process (`brush_app`). It is not part of the app: the app downloads it when the user installs
the splat scene components, as an archive our CI built from the sources (`.github/workflows/immuch360-desktop.yml`, jobs
`brush-windows` and `brush-linux`, script `.github/desktop/ai/brush_build.py`).

* Brush, Apache License 2.0: https://github.com/ArthurBrussee/brush at the tag and commit of
  `.github/desktop/ai/brush.lock.json` (v0.3.0, `3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486`), its licence in
  `brush-LICENSE.txt`. Brush has no NOTICE file.
* The crates compiled into it, each with its licence and the text of that licence: `THIRD-PARTY.md`, written by cargo
  about at each build, with the NOTICE files of that code, found next to each crate, at the root of each git
  repository a crate comes from (burn and cubecl keep theirs there) and at the root of Brush. Every licence there is on
  the list of `deny.toml` (Apache 2.0, MIT, BSD, ISC, Zlib, BSL 1.0, CC0, Unicode 3.0, and MPL 2.0 for crates compiled
  unmodified); the build fails otherwise.
* `EXTRA-NOTICES.md`: the copyright notices of the crates that carry no licence file (cargo about only has the template
  of their MIT licence, and `THIRD-PARTY.md` says so above it), copied from the licence file of their repository at the
  commit each was published from, with its SHA-256. The build fails when another crate comes with a template and no
  entry there. `about.toml` points cargo about at the `LICENSE.txt` of libm, which it does not recognise as a whole,
  so that the notices of musl and of the sources of its mathematics are kept.

## Modified files

Brush is built with `patches/0001-immuch360-headless-trainer.patch`, which changes these files of Brush (each changed
file says so in its first line, as the Apache License 2.0 asks in section 4 b):

* `crates/brush-app/Cargo.toml`, `crates/brush-app/src/bin.rs`, `crates/brush-app/src/lib.rs`: the window of Brush
  (egui, eframe, winit) behind a cargo feature, `viewer`, which our build leaves off. `brush_app` then only trains,
  from a folder given on the command line, and opens no window.
* `crates/brush-train/Cargo.toml`, `crates/brush-train/src/train.rs`: the LPIPS loss behind a feature, `lpips`, left
  off. Its weights (`crates/lpips/burn_mapped.bin`, a VGG network of 29,433,386 bytes whose provenance is not written
  in the repository of Brush) are therefore not in our binary; the build removes the file from the sources before it
  compiles, and checks that none of five 64 byte pieces of it, the first 64 bytes among them, is in the program. The
  LPIPS loss weighs 0 by default; a weight above 0 is refused.
* `crates/brush-process/Cargo.toml`, `crates/brush-process/src/visualize_tools.rs`: logging to a rerun.io viewer
  (a network client and server) behind a feature, `rerun`, left off.
* `crates/brush-vfs/Cargo.toml`, `crates/brush-vfs/src/data_source.rs`: the file dialogs and the sources given by a URL
  (an HTTP client) behind features, `pick` and `url`, left off. `brush_app` reads the folder it is given, nothing else.
* `crates/brush-ui/Cargo.toml`: the viewer asks for those features, so that a build with the viewer keeps what Brush
  has.

No dependency is added or removed: the `Cargo.lock` of the tag is used as it is (`cargo build --locked`).

## What the build checks

`brush_build.py`, in the jobs that build the archive: the tag still names the commit of the lock; the SHA-256 of
`LICENSE`, `Cargo.lock` and the LPIPS weights; the patches leave `Cargo.lock` as it is; the crates compiled into
`brush_app` hold neither the LPIPS crate, rerun, an HTTP, gRPC or TLS crate, nor a window or file dialog crate
(`cargo tree`, and `cargo deny` with `deny.toml`, our list, not the one of Brush, which allows more and counts the
fonts of egui as MIT or Apache 2.0); `brush_app --help` is the frozen `mobile/test/fixtures/ai_immersive/brush_help.txt`;
the program holds none of the probes of the LPIPS weights; on Windows every DLL it imports is in the archive or in
Windows.

Every file of this folder but `deny.toml`, `about.toml` and `about.hbs` (the configuration of the checks) goes into the
`licenses/` folder of both archives, with `THIRD-PARTY.md`.
