# immuch_sbs_codec

The JPEG codec of the AI features of Immuch360 Desktop (design-final 2026-10-26, section 2.8, lot A2c): it decodes
an original photo without any colour conversion, keeping its ICC profile, and writes the side by side 3D photo with
its EXIF, XMP and ICC segments. package:image does the same in Dart; this crate is there for the big photos, where
the Dart encoder takes seconds (a 48 Mpx pair: 4.7 s with package:image, 0.4 to 1.3 s here, measured on an i9 laptop
and on a loaded i5 build machine).

- `rust/`: the crate, a Cargo workspace of its own with its lock and its toolchain (1.98.0, as upstream's
  `native/crates/native_core_ffi`), out of upstream's `native/` tree. zune-jpeg (MIT OR Apache-2.0 OR Zlib) decodes,
  jpeg-encoder ((MIT OR Apache-2.0) AND IJG) encodes. A narrow C interface: `isc_decode`, `isc_encode`, `isc_free`,
  and `isc_abi_version` and `isc_licenses`. A panic is caught at the boundary and returned as a status.
- `hook/build.dart`: builds the crate on Windows x64, Linux x64 and macOS arm64 and x86_64 only; nothing for the
  phones, the Quest or iOS.
- `lib/`: the Dart calls, used by `mobile/lib/desktop/ai/codec/native_sbs_codec.dart` only (the package is in
  `FORBIDDEN` of `.github/desktop/check_desktop_imports.py` and in `.github/desktop/desktop-packages.json`).
- `licenses/`: the licence texts of the crates, built into the library and shown on the licence page of the app,
  with the sentence the IJG terms ask for: "this software is based in part on the work of the Independent JPEG
  Group".

Tests: `cargo test` in `rust/` (round trip, ICC profile copied, quality, subsampling, segments, a panic turned into
a status, the C functions, and the colours of grey, CMYK, YCCK, RGB stored and progressive originals, two of them
written by Pillow: `rust/fixtures/make_fixtures.py`), and `mobile/test/desktop/ai/codec/native_sbs_codec_test.dart`
through dart:ffi, skipped with its reason when the library is not built. The measure of a 48 Mpx pair:
`IMMUCH360_SBS_MEASURE=photo.jpg cargo test --release -- --ignored --nocapture measure`.
