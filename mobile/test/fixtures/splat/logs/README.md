# Logs of the measure of 1 November 2026

Lines COLMAP 4.2.1 and Brush 0.3.0 wrote on the PC of the measure (`logs/` of
`D:\DEV\immuch\splat-maker-2026-11-01`), which the runners of the splat scenes read (lot SP4,
`test/desktop/ai/splat/colmap_runner_test.dart` and `brush_runner_test.dart`). Our own logs of public datasets: the
150 photos of the room of Mip-NeRF 360 and 150 frames of the lighthouse video of Fremantle (CC0). No picture is kept.

* `c2s-extract.err`: `feature_extractor` on the 150 photos of the room, SIFT at 1 024 pixels; its head, the first three
  and the last three files, and its end (the whole log is 82 934 bytes).
* `c2s-match.err`: `exhaustive_matcher` on them, whole: 9 blocks of 50 images.
* `vlh-pairs-match.err`: `matches_importer` on the 150 frames of the video (lot SPF1, 3 November 2026, the
  `colmap.exe` of the test build T1 on 22 threads), whole: the 2 887 pairs a video longer than 200 frames is matched
  by (each frame with the 1st, 2nd, 4th ... 128th after it, and with every tenth frame), in 3 blocks, 49.3 s; the
  mapper then placed all 150 frames.
* `vlh-map.err`: `mapper` on those frames, which made two models (144 and 26 images); the lines of the incremental
  pipeline, of the registered images only the first and last four of the first model and the first eight and last
  three of the second (the whole log is 44 319 bytes).
* `m1-room1024.out`: Brush, the room at 1 024 pixels, 20 000 steps, at most 150 000 gaussians (pass P1 of M1), whole;
  the path of the dataset shortened to `D:\work\m1-room150`.
* `b4-2k-adapter.out`: the line in which Brush named the RTX 4060 Laptop it took (pass b4-2k of the measure).
