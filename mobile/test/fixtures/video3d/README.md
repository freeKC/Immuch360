# Fixtures of the 3D videos

`ffprobe_*.json`: what `ffprobe -v error -show_format -show_streams -count_packets -of json` says of the files of the
study of 18 November 2026 (`store/m2/release-49/video3d-study.md`), the file name only kept:

* `pedestrian_area`, `berbera_morning`: two of its CC0 clips of Wikimedia Commons (Taurus Media Technik; Brian Dell),
  the WebM with `avg_frame_rate` 1000/1 and the Ogg with `0/0`;
* `phone_src`: its synthetic phone file (4 s of the ped clip cropped to portrait, HEVC Main 10 tagged HLG, a 90
  degree display matrix, one frame in 7 dropped, made up date, place, make and model);
* `phone_3D_LRF_Full_SBS`: the side by side file the study made of it (st3d left right).

The variants the tests need (Dolby Vision, interlaced, 360°, several tracks) are these files changed in the tests.
