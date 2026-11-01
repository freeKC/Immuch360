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
