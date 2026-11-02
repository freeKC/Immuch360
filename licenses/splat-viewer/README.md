# The splat viewer: Spark and three.js

The Gaussian splat scenes (.spz, .ply) open on the computers, phones and tablets in one web page of the app's assets
(`mobile/assets/splat_viewer/`), shown by the system's web view (WebView2 on Windows, WebKitGTK on Linux, WKWebView on
macOS and iOS, Android System WebView). The page draws with Spark and three.js; everything it runs ships in the app and
nothing is fetched from the internet (its Content-Security-Policy allows the app's own origin only).

| Artefact | Version, source | In the app as | Licence |
| --- | --- | --- | --- |
| Spark | 2.4.0, https://github.com/sparkjsdev/spark tag `v2.4.0`, commit `ffe210dc0a45d0515a06c9235878108112827d61`, built by `.github/desktop/splat_viewer/spark_build.py` with the patches of `.github/desktop/splat_viewer/patches/` | `spark.module.min.js`, `spark_rs_bg.wasm` | MIT, Copyright © 2025 World Labs Technologies, Inc. (`LICENSE` of the tag) |
| fflate | 0.8.3, the version of Spark's `package-lock.json`, bundled into `spark.module.min.js` by Spark's build (read from its source map) | inside `spark.module.min.js` | MIT, Copyright (c) 2026 Arjun Barrett (`LICENSE` of the npm package) |
| three.js | 0.180.0, npm `three` as locked by Spark's `package-lock.json` | `three.module.min.js`, `three.core.min.js`, `Pass.js` | MIT, Copyright © 2010-2025 three.js authors (`LICENSE` of the npm package) |
| The Rust crates of Spark's WebAssembly | the versions of Spark's `Cargo.lock` at the tag, as cargo resolves them for wasm32 | inside `spark_rs_bg.wasm` | `CRATES.txt`: each crate with its licence expression and the licence it is taken under (MIT where offered, otherwise Apache 2.0) |

The SHA-256 and the size of each file are in `MANIFEST`; the gates job of the desktop workflow checks the committed
files against it (`check_vendor.py`), and the spark job of the same workflow builds Spark again from its tag and fails
when it does not give the same bytes.

## Why our own build of Spark

Spark's npm file carries its WebAssembly built with flate2 on zlib-rs 0.6.3, a crate under the Zlib licence, which is
permissive but not among the licences the app takes (MIT, BSD, Apache 2.0, MPL 2.0). Our build changes two features
in Spark's `rust/Cargo.toml` (patch `0001`): flate2 on its `rust_backend` and zip on `deflate-flate2`, that is
miniz_oxide (MIT, Zlib or Apache 2.0, taken under MIT) instead of zlib-rs; `Cargo.lock` is used as it is, with
`--locked`. Patch `0002` makes the WebAssembly a file of its own, fetched next to the module, instead of a base64
string inside it: the module goes from 2.85 MB to 0.44 MB, the WebAssembly is 1.64 MB, and both deflate better in the
app's packages.

What the build checks:

* the tag is at the commit of `spark.lock.json`, and the toolchain is the lock's (Rust 1.98.0, wasm-pack 0.15.1,
  Node.js 24.21.0);
* every crate compiled into the WebAssembly (cargo's tree for wasm32, procedural macros left out since they run at
  build time only) has a licence expression with MIT, BSD, Apache 2.0 or MPL 2.0 as a choice, and none of zlib-rs,
  libz-sys and libz-rs-sys is there. unicode-ident (MIT or Apache 2.0, with the Unicode 3.0 licence for its tables) is
  in the tree through wasm-bindgen-shared, which uses it for the identifiers of wasm-bindgen's build tools only: no
  function of the module cargo links mentions it (read from the name section before wasm-bindgen strips it), so none
  of its code or tables ships, and `CRATES.txt` says so;
* ahash takes its keys from const-random at build time: `CONST_RANDOM_SEED` is fixed by the lock, so that two builds
  give the same bytes (checked twice on ai1 on 2 November 2026, and by the spark job against the committed files).

`THIRD_PARTY_NOTICES.txt` holds, for each crate of the WebAssembly, its licence and the licence files it ships for
the licence it is taken under (the MIT texts with their copyright lines, the Apache 2.0 text and NOTICE files).

## In the app

* `mobile/assets/splat_viewer/`: the page, our own modules and the engine files above, in every build (no flavour:
  the computers build without one).
* `mobile/assets/licenses/splat-viewer/`: `LICENSE-spark`, `LICENSE-three`, `LICENSE-fflate`,
  `THIRD_PARTY_NOTICES.txt`, shown by the licence page of the app under "Spark", "three.js", "fflate" and "Spark
  WebAssembly crates" (`mobile/lib/utils/splat_viewer_licenses.dart`, registered in `main.dart`, tested by
  `test/utils/splat_viewer_licenses_test.dart`).

## Why this engine

The exploration and plan of 2 November 2026 (research notes, `store/m2/splat-viewer-2026-11-02/`): Spark is the only
web renderer of Gaussian splats that reads every SPZ version, 1 to 4, and PLY in any property order; it was measured
right in Chrome, WebView2, WebKitGTK and the Android WebView on the owner's kit. The PlayCanvas engine 2.23.3 (MIT)
stays the fallback.
