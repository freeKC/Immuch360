# Gaussian splat fixtures

Written by `.github/desktop/ai/make_splat_fixtures.py` (run it again with `--check` to compare), read by the Dart
tests (`test/domain/splat/`) and the Kotlin tests (`android/app/src/test/kotlin/app/alextran/immich/immersive/splat/`).
`expected.json` holds what both compare with.

All the files are synthetic, made by the script from the public descriptions of the formats, except two heads:

* `cash_register_head.spz` and `measuring_tape_head.ply`: the first 65 536 bytes of `gsplat-cash-register.spz`
  (686 150 bytes, SHA-256 `9f01f445...7cd9dd8`) and `gsplat-measuring-tape.ply` (1 324 307 bytes, SHA-256
  `1f6323c7...70feff10`) of InnerScene, https://www.innerscene.com/tools/gaussian-splat-viewer, published there as
  "public domain (CC0)", trained by DX.GL from models of Poly Haven (CC0). Read on 30 October 2026.

`sh3_v2.spz` and `edges_sh3_v2.spz` are `sh3.ply` and `edges_sh3.ply` packed as SPZ version 2 by the rules the script
writes once (`spz_v2_from_ply`, after `packGaussians` of Niantic Labs, MIT): the golden files of the splat scenes made on
a computer, whose decompressed bytes the Dart writer gives again.

`brush_sh3.ply` is an export as Brush 0.3.0 writes it (its comments, its properties in alphabetical order, with values
no format carries); `scene_sh3.ply` and `scene_sh3_v2.spz` are what a splat scene made on a computer writes of it
(`scene_ply`: the finite gaussians scaled by 0.5, in the usual order, our comments), the golden files of the Dart PLY
writer (byte for byte) and SPZ writer (once inflated).

One file is not the script's: `scene_sh3_v2_dart.spz`, the SPZ the Dart writer made of `brush_sh3.ply`, kept so that the
Kotlin tests read a gzip wrapper of the Dart side. `spz_v2_writer_test.dart` checks that it inflates to what the writer
gives (`IMMUCH360_WRITE_SPLAT_FIXTURES=1` writes it again), `make_splat_fixtures.py --check` that it inflates to
`scene_sh3_v2.spz`.

`dataset.json` is no splat: the sums of the pixels and the true poses of the 24 views of the synthetic room that
`.github/desktop/ai/make_splat_dataset.py` draws (two lenses, three boxes, the same pixels on every system), which the
jobs that run the real COLMAP compare with what it finds. The views themselves are drawn again, never kept here.
