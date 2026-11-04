# AV2 test fixtures (lot AD0, 2 November 2026)

Small AV2 streams for the tests of the AV2 playback of Immuch360 Desktop: the container reader and index (`av2_stream.dart`,
lot AD1) and the checks of the `immuch360-av2` companion and its CI (lot AD2). Made on ai1 by `make_av2_fixtures.py`
(next to this file), 2026-11-02 14:00:16 CET. 32,174 bytes in all.

**Source**: "Orbit around Fremantle South Mole Lighthouse at sunset.webm" by JamesBromberger, Wikimedia Commons,
CC0 1.0 (<https://commons.wikimedia.org/wiki/File:Orbit_around_Fremantle_South_Mole_Lighthouse_at_sunset.webm>), VP9 1920x1080 at 30000/1001, SHA-256 `6a245417eb6bb7077f77178ae8697ba1ae6a8f82bdc19136e526ac40130e812d`. Frames 750 to 761 (from 25.0 s), scaled
to 256x144 by ffmpeg (lanczos), retimed to exactly 30 frames per second. The fixtures are derived from a CC0 work and
carry no restriction: they can be committed to the repository.

**Tools** (sources and builds of the measurement of 2 November, `~/av2-2026-11-02/` on ai1):

| Tool | Role | Commit | Binary SHA-256 |
|---|---|---|---|
| `avmenc` | encoder (AVM branch `av2-enc`) | `ad715c88d5b1119780b3a82025696ab8e77f5c55` (`ad715c8`) | `15e1f221e065f49f34e1053acd8f62fd5ff225e4d70aaa8bfc83414289734cf9` |
| `avmdec` | reference decoder (AVM tag `v1.0.0`) | `966a7d7cd6fcf60360caf5dc413b2aeeb65e144d` (`v1.0.0`) | `953c16d1db8defca758a9c2530ef8fe264797cd3722cc280c307d9fd56c46373` |
| `dav2d` | decoder of the app (VideoLAN) | `30140b563596a1b14aef808ff021c90288948315` (`0.0.1-525-g30140b56`) | `82fac2746406066b78f7f68f0f1a66f93cf6b748aa13762c604f8a3692720579` |
| ffmpeg | source cut and scale, AV1 sample | ffmpeg version 7.1.5-0+deb13u1 | |

**Encoder settings**: `--cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12` plus `--bit-depth` and `--input-bit-depth` (8 or 10) and `--ivf` or `--obu`. One
thread, so the encode is reproducible: a second encode gave the same bytes (8 and 10 bit).


## Files

| File | What | Bytes | SHA-256 | Frames |
|---|---|---|---|---|
| `av2-256x144-8bit.ivf` | AV2 8 bit, IVF (`DKIF`, `AV02`) | 5,365 | `fd424a918379d53f3b6d2295aec5b15aeafd2321e735469c45623152681aa28d` | 12 |
| `av2-256x144-8bit.obu` | AV2 8 bit, Section 5 OBU stream | 5,237 | `f1ba28c2352657d4cb82d56fd6b515bcb3222132d45b6eb5ae8b46d37a376941` | 12 |
| `av2-256x144-10bit.ivf` | AV2 10 bit, IVF | 5,288 | `1f1b9f68762ce6e407f587ccacaa703b106ff74f4afd6a42d8cf1a698fef8002` | 12 |
| `av2-256x144-10bit.obu` | AV2 10 bit, Section 5 OBU stream | 5,160 | `5aa5275a7e7587185ddb7710d0b235bfa32a52afee62f3bc009b82a7171bc736` | 12 |
| `av2-256x144-8bit-cut.ivf` | the 8-bit IVF cut in the middle of temporal unit 8 | 5,317 | `65c14fc174d8e340099c326ab21ecd6f2ff04f608174b741d7552d4f11a6a8af` | 7 playable (8 whole units) |
| `av2-256x144-8bit-damaged.ivf` | the 8-bit IVF with 16 bytes overwritten in the tile data of unit 1 | 5,365 | `1e9ae470b6c3bb7541a681b86f91f9f14be0ab9d56ed32374e2112c76bce26dd` | 12 units, dav2d gives 7 |
| `av1-256x144-8bit.ivf` | AV1 in IVF (`AV01`), 2 frames: must be refused as AV2 | 442 | `06617733ad6165abee0345e4e1484bc3f9a8cb7ea1356755172580fe6f10e120` | 2 |

All AV2 files: 256x144, 4:2:0, 30 frames per second (IVF rate 30, scale 1), 12 frames, key frames at 0 and 6, IVF header frame count 12 (kept as is in the cut file).

## What the tests should know

1. **Coding order is not display order.** avmenc codes each group of six frames as 0, 5, 2, 1, 3, 4 (unit 1 codes
   frame 5, which frames 1 to 4 then use). The decoders keep frames back and give them in display order; at the end of
   the data they give what they hold. Every temporal unit codes exactly one frame that is shown (12 units, 12 frames,
   no hidden frame): the number of temporal delimiters is the number of frames here, but unit k is not frame k.
2. **IVF packets carry several units** (packet 1 holds units 1, 2 and 3). The `pts` of a packet is the display index of
   the first frame that comes out once the packet is decoded (0, 1, 3, 4, 6, 7, 9, 10), not the frame its first unit
   codes. Index by temporal delimiter (OBU type 2), not by packet.
3. **Access points**: units 0 and 6 hold a `CLOSED_LOOP_KEY` OBU (4), each preceded by a sequence header (1). Their
   display index equals their unit index and their packet `pts`. Decoding from unit 6 alone (the `.obu` bytes from its
   offset) gives frames 6 to 11 with the same MD5 as the full decode, in both decoders.
4. **`.obu` = the IVF payloads put end to end**, byte for byte (and the same bytes as `avmenc --obu`). An AV2 stream
   starts with `01 08` (size 1, header 0x08: a temporal delimiter) then `18 04` (24-byte sequence header).
5. **Frame MD5**: MD5 of each decoded frame, planes Y, U and V one after the other without padding; 8 bit: one byte
   per sample, 55,296 bytes per frame; 10 bit: two bytes little endian per sample, 110,592 bytes per frame. This is
   exactly the payload after `FRAME\n` of a y4m frame. `avmdec` v1.0.0 and dav2d give the same list on every complete
   file, dav2d on its three code paths of ai1 (AVX-512, `--cpumask avx2` and `--cpumask 0`, plain C). The whole-stream
   MD5 (`avmdec --rawvideo --md5`, `dav2d --muxer md5`) is the MD5 of all frames end to end.
6. **The y4m header must come from us**: rate 30/1 is in the IVF header (rate 30, scale 1); dav2d writes another frame
   rate in its own y4m output for streams whose packets carry several frames (measurement, section 5).


## Temporal units of `av2-256x144-8bit.ivf` and `av2-256x144-8bit.obu`

| Unit | IVF packet | Offset in .ivf | Offset in .obu | Bytes | OBU types | Access point | Codes frame |
|---|---|---|---|---|---|---|---|
| 0 | 0 | 44 | 0 | 1698 | TEMPORAL_DELIMITER, SEQUENCE_HEADER, CLOSED_LOOP_KEY | yes | 0 |
| 1 | 1 | 1754 | 1698 | 95 | TEMPORAL_DELIMITER, REGULAR_TILE_GROUP |  | 5 |
| 2 | 1 | 1849 | 1793 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 2 |
| 3 | 1 | 1856 | 1800 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 1 |
| 4 | 2 | 1875 | 1807 | 9 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 3 |
| 5 | 3 | 1896 | 1816 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 4 |
| 6 | 4 | 1915 | 1823 | 3309 | TEMPORAL_DELIMITER, SEQUENCE_HEADER, CLOSED_LOOP_KEY | yes | 6 |
| 7 | 5 | 5236 | 5132 | 77 | TEMPORAL_DELIMITER, REGULAR_TILE_GROUP |  | 11 |
| 8 | 5 | 5313 | 5209 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 8 |
| 9 | 5 | 5320 | 5216 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 7 |
| 10 | 6 | 5339 | 5223 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 9 |
| 11 | 7 | 5358 | 5230 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 10 |

IVF packets (12-byte header each): 0: offset 32, 1698 bytes, pts 0, 1: offset 1742, 109 bytes, pts 1, 2: offset 1863, 9 bytes, pts 3, 3: offset 1884, 7 bytes, pts 4, 4: offset 1903, 3309 bytes, pts 6, 5: offset 5224, 91 bytes, pts 7, 6: offset 5327, 7 bytes, pts 9, 7: offset 5346, 7 bytes, pts 10. Encoder summary: 104.74 kbit/s, overall PSNR 42.480009 dB.

## Temporal units of `av2-256x144-10bit.ivf` and `av2-256x144-10bit.obu`

| Unit | IVF packet | Offset in .ivf | Offset in .obu | Bytes | OBU types | Access point | Codes frame |
|---|---|---|---|---|---|---|---|
| 0 | 0 | 44 | 0 | 1663 | TEMPORAL_DELIMITER, SEQUENCE_HEADER, CLOSED_LOOP_KEY | yes | 0 |
| 1 | 1 | 1719 | 1663 | 95 | TEMPORAL_DELIMITER, REGULAR_TILE_GROUP |  | 5 |
| 2 | 1 | 1814 | 1758 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 2 |
| 3 | 1 | 1821 | 1765 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 1 |
| 4 | 2 | 1840 | 1772 | 9 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 3 |
| 5 | 3 | 1861 | 1781 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 4 |
| 6 | 4 | 1880 | 1788 | 3260 | TEMPORAL_DELIMITER, SEQUENCE_HEADER, CLOSED_LOOP_KEY | yes | 6 |
| 7 | 5 | 5152 | 5048 | 84 | TEMPORAL_DELIMITER, REGULAR_TILE_GROUP |  | 11 |
| 8 | 5 | 5236 | 5132 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 8 |
| 9 | 5 | 5243 | 5139 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 7 |
| 10 | 6 | 5262 | 5146 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 9 |
| 11 | 7 | 5281 | 5153 | 7 | TEMPORAL_DELIMITER, REGULAR_TIP |  | 10 |

IVF packets (12-byte header each): 0: offset 32, 1663 bytes, pts 0, 1: offset 1707, 109 bytes, pts 1, 2: offset 1828, 9 bytes, pts 3, 3: offset 1849, 7 bytes, pts 4, 4: offset 1868, 3260 bytes, pts 6, 5: offset 5140, 98 bytes, pts 7, 6: offset 5250, 7 bytes, pts 9, 7: offset 5269, 7 bytes, pts 10. Encoder summary: 103.2 kbit/s, overall PSNR 42.751061 dB.

## Frame MD5, display order (avmdec v1.0.0 = dav2d)

| Frame | 8 bit (`.ivf` and `.obu`) | 10 bit (`.ivf` and `.obu`) |
|---|---|---|
| 0 | `09b1abae0f90a9536779d05c0150e2c2` | `3b058f724f45a2aa47358127b625d57a` |
| 1 | `9c7577eef292bd93d716ad4611787a85` | `e1b4cb484f4bd713ce9c721449d2f665` |
| 2 | `a2e8f77bc528ddd3ff991ea4affa2576` | `953859f5b019e999c9d6810d16fd0f84` |
| 3 | `25b59ced2cdf4ee9148d09f47e298ec5` | `942936c070718e8443a55a4553dcb216` |
| 4 | `1b721fba4f21abca8350c5b0ed8e0a7e` | `323d7e06b7ba56532c245147e5b99033` |
| 5 | `359cbff13563b17be11dbe9623121c0c` | `44064630150e38f5b310c50ad7293094` |
| 6 | `9eb0176c4953125b6a379a9e7a213ee1` | `a080a78c8e82fa1e3d75392c0b9a6b24` |
| 7 | `8aa5275f39225948c6151bc590b084e8` | `9f769e0fa400880a16fb345894e70a77` |
| 8 | `667fcd7420206b8f60f2310fbd50a0a1` | `f8526293659e51828f093c818e65c2de` |
| 9 | `36015d3c2ece7aacb3edf2da8be6cad6` | `132e8bb03883b4b45c62e514d4b61bf9` |
| 10 | `68e4b7a64021bfe929f42b468879fc0f` | `eea60db3d326acc6ad4730cef38927eb` |
| 11 | `6c2697dca26a92d58d99fb211cc51136` | `9f3705aafa5fd0eebb34d6146817d3b8` |

Whole stream: 8 bit `5a18f2703dfbb812d58d326cac00f746`, 10 bit `457cc73ee41a520b21b1584ec267ab8f` (same value from `avmdec --md5` and `dav2d --muxer md5`).

## The cut file

`av2-256x144-8bit-cut.ivf` is the first 5,317 bytes of `av2-256x144-8bit.ivf`: the file stops inside
temporal unit 8 (in the middle of its last OBU), which sits in IVF packet 5 after
unit 7, a whole unit of the same packet. The packet header still announces its full size and the IVF header still says
12 frames, as after an interrupted copy.

* **Index**: 8 whole units (0 to 7), unit 8 incomplete; access points 0 and 6.
* **Frames**: the whole units carry frames 0, 1, 2, 3, 4, 5, 6, 11; only the
  first **7** (0 to 6) play without a gap, since frames 7 to 10 are in the missing
  units. For an IVF this is also the `pts` of the first incomplete packet (7).
* **Decoders on the file**: avmdec exit 0, frames [0, 1, 2, 3, 4, 5, 6]; dav2d exit
  0, frames [0, 1, 2, 3, 4, 5, 6] (both drop the incomplete packet, with unit 7 in it).
* **Decoders on the 8 whole units as a Section 5 stream** (what the companion is fed): avmdec exit
  0, dav2d exit 0, both give frames [0, 1, 2, 3, 4, 5, 6, 11] in that
  order (frame 11 comes out at the end of the data), each with the MD5 of the full decode.

## The damaged file

`av2-256x144-8bit-damaged.ivf` is `av2-256x144-8bit.ivf` with bytes 1760 to
1775 set to 0xFF (payload bytes 2 to 17 of the unit's REGULAR_TILE_GROUP OBU;
unit 1 codes frame 5, which frames 1 to 4 use). The container is intact: the index still finds 12 whole units and the
access points 0 and 6.

* **dav2d**: prints `Error decoding frame: Invalid argument`, exit 0,
  frames [0, 6, 7, 8, 9, 10, 11]: frames 1 to 5 are lost, decoding comes back at the next access point.
* **avmdec v1.0.0**: `Warning: Additional information: Corrupted segment_ids`, exit
  1, frames [0] (it stops at the first error).
* Neither crashed. The companion must turn the error into its `stopped` message or skip to the next access point
  (AD2 decides); the app must stay up.

Other damage tried on the same file (not kept as files; frames as display indices):

| Damage | dav2d exit | dav2d frames | avmdec exit | avmdec frames | avmdec message |
|---|---|---|---|---|---|
| unit 1 tile payload bytes 2-17 set to 0xFF (the kept damaged fixture) | 0 | [0, 6, 7, 8, 9, 10, 11] | 1 | [0] | Corrupted segment_ids |
| unit 1 tile OBU last 8 bytes set to 0x00 | 0 | [0, 6, 7, 8, 9, 10, 11] | 1 | [0] | Failed to decode tile data |
| unit 1 tile payload all set to 0x00 | 0 | [0, 6, 7, 8, 9, 10, 11] | -11 | [] |  |
| unit 6 key OBU, 16 bytes in the middle set to 0xFF | 1 | [0, 1, 2, 3, 4, 5] | 1 | [0, 1, 2, 3, 4, 5] | Failed to decode tile data |
| unit 6 key OBU, first 8 payload bytes set to 0xFF | 1 | [0, 1, 2, 3, 4, 5] | 1 | [0, 1, 2, 3, 4, 5] | Frame dimensions are larger than the maximum values |
| unit 7 tile payload bytes 2-17 set to 0xFF | 0 | [0, 1, 2, 3, 4, 5, 6] | 1 | [0, 1, 2, 3, 4, 5, 6] | Invalid rst_ref_pic_idx: ref frame frame filter disabled |
| unit 0 sequence header payload all set to 0xFF | 0 | [6, 7, 8, 9, 10, 11] | 1 | [] | Truncated packet |

Exit -11 is a segmentation fault: `avmdec` v1.0.0 crashes on unit 1's tile data set to zero; dav2d does not (the reference decoder only verifies, it is never shipped).

## The AV1 sample

`av1-256x144-8bit.ivf`: 2 frames of the same source by libaom (through ffmpeg), IVF fourcc `AV01`.
Its first OBU is `12 00` (AV1 temporal delimiter); read as AV2 it would be an OBU of type 0, which does not exist. It
must be refused as AV2 by the fourcc for `.ivf`, and by the first OBU for a Section 5 stream.

## Check again, make again

* After a new dav2d commit: `python3 make_av2_fixtures.py verify DIR` decodes every AV2 fixture of DIR with both
  decoders and compares each frame with `fixtures.json` (exit 1 on any difference). The CI has no avmdec: it compares
  the companion's frames with the `frame_md5` lists of `fixtures.json`, which come from avmdec v1.0.0.
* Make again on ai1: `python3 make_av2_fixtures.py sources` then `python3 make_av2_fixtures.py fixtures` then
  `python3 make_av2_fixtures.py doc fixtures/out`. `fixtures.json` holds every value of this page, the index of every
  file and the 55 commands run, in order.

## Commands run

Sources (`commands-sources.txt`):

```
/home/frenaud/.local/share/mise/shims/ffmpeg -nostdin -hide_banner -loglevel error -y -i fixtures/src/lighthouse.webm -an -sn -map 0:v:0 -vf 'select='"'"'between(n\,750\,761)'"'"',setpts=N/30/TB,scale=256:144:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p' -r 30 -frames:v 12 -strict -1 -f yuv4mpegpipe fixtures/src/lighthouse-256x144-8bit-12f.y4m
/home/frenaud/.local/share/mise/shims/ffmpeg -nostdin -hide_banner -loglevel error -y -i fixtures/src/lighthouse.webm -an -sn -map 0:v:0 -vf 'select='"'"'between(n\,750\,761)'"'"',setpts=N/30/TB,scale=256:144:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p10le' -r 30 -frames:v 12 -strict -1 -f yuv4mpegpipe fixtures/src/lighthouse-256x144-10bit-12f.y4m
/home/frenaud/.local/share/mise/shims/ffmpeg -nostdin -hide_banner -loglevel error -y -i fixtures/src/lighthouse.webm -an -sn -map 0:v:0 -vf 'select='"'"'between(n\,750\,1049)'"'"',setpts=N/30/TB,format=yuv420p' -r 30 -frames:v 300 -strict -1 -f yuv4mpegpipe fixtures/src/lighthouse-1080p30-8bit-300f.y4m
```

Fixtures and checks (from `fixtures.json`, paths relative to `~/av2-2026-11-02/` on ai1):

```
build/avm-av2enc/avmenc --cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12 --bit-depth=8 --input-bit-depth=8 --ivf -o fixtures/out/av2-256x144-8bit.ivf fixtures/src/lighthouse-256x144-8bit-12f.y4m
build/avm-av2enc/avmenc --cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12 --bit-depth=8 --input-bit-depth=8 --obu -o fixtures/out/av2-256x144-8bit.obu fixtures/src/lighthouse-256x144-8bit-12f.y4m
build/avm-av2enc/avmenc --cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12 --bit-depth=8 --input-bit-depth=8 --ivf -o fixtures/tmp/again-8.ivf fixtures/src/lighthouse-256x144-8bit-12f.y4m
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/out/av2-256x144-8bit.ivf
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask avx2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask 0
build/avm-dec/avmdec --rawvideo --md5 -t 2 fixtures/out/av2-256x144-8bit.ivf
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.ivf --muxer md5 -o - --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/out/av2-256x144-8bit.obu
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask avx2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask 0
build/avm-dec/avmdec --rawvideo --md5 -t 2 fixtures/out/av2-256x144-8bit.obu
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit.obu --muxer md5 -o - --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/from-ap6.obu
build/dav2d/tools/dav2d -q -i fixtures/tmp/from-ap6.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-av2enc/avmenc --cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12 --bit-depth=10 --input-bit-depth=10 --ivf -o fixtures/out/av2-256x144-10bit.ivf fixtures/src/lighthouse-256x144-10bit-12f.y4m
build/avm-av2enc/avmenc --cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12 --bit-depth=10 --input-bit-depth=10 --obu -o fixtures/out/av2-256x144-10bit.obu fixtures/src/lighthouse-256x144-10bit-12f.y4m
build/avm-av2enc/avmenc --cpu-used=6 --end-usage=q --qp=160 --kf-min-dist=6 --kf-max-dist=6 --threads=1 --test-decode=fatal --psnr --limit=12 --bit-depth=10 --input-bit-depth=10 --ivf -o fixtures/tmp/again-10.ivf fixtures/src/lighthouse-256x144-10bit-12f.y4m
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/out/av2-256x144-10bit.ivf
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask avx2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask 0
build/avm-dec/avmdec --rawvideo --md5 -t 2 fixtures/out/av2-256x144-10bit.ivf
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.ivf --muxer md5 -o - --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/out/av2-256x144-10bit.obu
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask avx2
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2 --cpumask 0
build/avm-dec/avmdec --rawvideo --md5 -t 2 fixtures/out/av2-256x144-10bit.obu
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-10bit.obu --muxer md5 -o - --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/from-ap6.obu
build/dav2d/tools/dav2d -q -i fixtures/tmp/from-ap6.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/out/av2-256x144-8bit-cut.ivf
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit-cut.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/cut-whole-units.obu
build/dav2d/tools/dav2d -q -i fixtures/tmp/cut-whole-units.obu --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/out/av2-256x144-8bit-damaged.ivf
build/dav2d/tools/dav2d -q -i fixtures/out/av2-256x144-8bit-damaged.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
build/dav2d/tools/dav2d -q -i fixtures/tmp/survey.ivf --muxer yuv -o fixtures/tmp/dec.yuv --threads 2
build/avm-dec/avmdec --rawvideo -t 2 -o fixtures/tmp/dec.yuv fixtures/tmp/survey.ivf
/home/frenaud/.local/share/mise/shims/ffmpeg -nostdin -hide_banner -loglevel error -y -i fixtures/src/lighthouse-256x144-8bit-12f.y4m -frames:v 2 -c:v libaom-av1 -cpu-used 8 -crf 50 -g 2 -threads 1 -f ivf fixtures/out/av1-256x144-8bit.ivf
```

