# immuch360-av2, the AV2 companion of Immuch360 Desktop

A small program in C on the library of [dav2d](https://code.videolan.org/videolan/dav2d) (VideoLAN, BSD 2-Clause) that
plays AV2 videos for the desktop app (plan of the 2nd of November 2026, section 2). The app reads the container itself
(IVF or Section 5 OBUs), cuts it into temporal units and feeds them through the standard input; the program decodes them
and serves the pictures to the player of the app (libmpv) as a virtual y4m over HTTP on 127.0.0.1, so that no decoded
byte crosses the app. Under the licence of this repository (AGPL 3.0); dav2d is linked statically (its licence, that of
`x86inc.asm` and the AOM patent licence travel with the program, `licenses/av2`).

Built by the CI only (`.github/workflows/immuch360-desktop.yml`, jobs `av2-windows`, `av2-linux`, `av2-macos`;
`.github/desktop/av2/av2_build.py`): `av2_build.py sources` puts dav2d at the commit of `av2.lock.json` in
`subprojects/dav2d`, then Meson builds both (dav2d without its command line tools and tests). By hand on Linux:

```
python3 .github/desktop/av2/av2_build.py sources
meson setup build mobile/native/av2 --buildtype=release --default-library=static
meson compile -C build
```

## Commands

* `immuch360-av2 probe FILE|- [--threads N]`: what the start of an AV2 file holds, as one line of JSON (the sequence
  header, the first picture decoded: size, depth, layout, colour description and range; `playable`, and `format`, the
  words the app shows when it refuses a stream: "4:4:4 10-bit", "4:2:0 12-bit"...). It reads 1 MiB first, then four
  times more while no picture came out, up to 64 MiB; `-` reads the bytes on the standard input until it closes (the
  start of a file of a share: the app sends what it has read, then closes it; bytes that end inside the first picture
  give `"playable": false` and the refusal "a stream without a picture in its start"). Exit code 3 and
  `{"error": "..."}` when it is not AV2 or not readable.
* `immuch360-av2 serve --token TOKEN --width W --height H --bits 8|10 --fps NUM/DEN --frames N [--threads N]
  [--range limited|full] [--depth 8] [--frame-bytes B] [--port P]`: below.
* `immuch360-av2 --version`: `immuch360-av2 protocol 1, source <commit>`, `dav2d <commit> (<describe>)`,
  `simd <levels the processor has>, uses <level dav2d uses>`.
* `immuch360-av2 --help`: frozen in `mobile/test/fixtures/av2/immuch360_av2_help.txt`.

## serve

The program listens on 127.0.0.1 only (a free port unless `--port`) and serves `http://127.0.0.1:PORT/TOKEN/video.y4m`:
our own y4m header (`YUV4MPEG2 W.. H.. F<fps> Ip A1:1 C420|C420p10 XCOLORRANGE=LIMITED|FULL`, the frame rate the app
read in the container: the one the `dav2d` program writes is wrong for files of avmenc), then `--frames` records of
`FRAME\n` and the picture (4:2:0, 8 bits, or 10 bits in 16 bit little endian words; `--depth 8` serves 10-bit pictures
as 8-bit samples). Its length is known before any decoding: `header + frames x (6 + frame bytes)`.

A request (GET or HEAD, `Range: bytes=a-`, `a-b` or `-n`) maps to picture k and an offset in it. The decoder goes on
from where it is when the random access unit before k is not after its position; otherwise it starts again there: a new
generation, `dav2d_flush`, and the line `need G U` for the app. The pictures before k are dropped without being
written. Another token gets 403, another path 404, a range past the end 416; a request from an address other than
127.0.0.1 is closed. One request is served at a time: a new one ends the one being served (its socket is shut down), as
the player does when it seeks. A player that stops reading (pause) blocks the write, then the decoder, then the app's
writes on the standard input: no processor time is spent.

### Standard input: records

Every record is a 16-byte header, little endian, then `length` bytes:

| Bytes | Field |
|---|---|
| 0 to 3 | `AV2R` |
| 4 to 7 | generation |
| 8 to 11 | unit |
| 12 to 15 | length |

1. First, the index: generation 0, unit 4294967295 (`0xFFFFFFFF`), the numbers of the temporal units that are random
   access points (a `CLOSED_LOOP_KEY` OBU), as 32-bit numbers, in order, the first one 0.
2. Then, for each line `need G U` of the program, the temporal units U, U+1... with generation G, each record holding
   one whole unit (from its temporal delimiter to the next one), and after the last unit of the file a record of length
   0 (unit = the number of units) so that the decoder gives its last pictures. A new `need` line stops the feeding of
   the previous generation: records of an older generation are read and dropped.

Unit k gives picture k of the y4m: each temporal unit of avmenc's files shows one picture, in the order of display after
the decoder (units 0 to 11 of the fixtures code pictures 0, 5, 2, 1, 3, 4, 6, 11, 8, 7, 9, 10; dav2d outputs 0 to 11).
Closing the standard input ends the program within a second (`exit input-closed`, code 0): the app closes it when the
player closes, and the system closes it when the app dies.

### Standard output: lines

| Line | When |
|---|---|
| `listening PORT address=127.0.0.1 length=L header=H frame=F frames=N` | once, when the socket listens |
| `need G U` | the decoder starts again at unit U, generation G |
| `request bytes=A-B frame=K` | a request is served from picture K |
| `stat decoded=D served=S fps=X simd=LEVEL gen=G frame=K serving=0\|1` | every half second, always |
| `refused token\|path\|method\|range\|address\|request` | a request was refused |
| `error KIND MESSAGE` | then the program ends with the code below |
| `exit input-closed` | the standard input closed |

`fps` is the speed at which this computer decodes and serves the video, measured on runs of pictures that the decoder
alone paced: a run ends when a write to the player takes more than 10 ms for 256 KiB (the player does not read: its
cache is full, or it is paused) or when a unit of the app has not come, and its first pictures are left out (the
decoder threads worked ahead while the main thread waited). Such runs happen when playback starts, after each seek, and
all the time on a computer too slow for the video; between them the line keeps the last speed measured, and `0.0`
until the first one (a few frames at least, 100 ms at least). On ai1 (lot AD2), it read 125 to 153 fps for WorldCup
(dav2d alone: 120 hot to 168 cold), 42 for FlowerSky 4K 8 bits (41.7), 8.7 for cosmos 4K 10 bits (8.4), and 15 to
20 % above dav2d alone for Skater and cosmos 2048 in 10 bits. The app can also count `decoded` and `served` against
the clock.

### Exit codes

0 the standard input closed, 1 internal error (memory, threads), 2 bad arguments, 3 the video cannot be decoded (a
dav2d error, `error decode`, or a picture of another size or depth than serve was told, `error format`), 4 no socket
on 127.0.0.1, 5 records that are not the protocol's.

## Tests

`.github/desktop/av2/av2_serve_check.py check` plays the app's side in Python against the program of each archive in
the CI: the MD5 of the pictures of the fixtures against those of the reference decoder `avmdec` v1.0.0, ranges, seeks,
the replaced request, the token, 127.0.0.1 only, the stat lines, no processor time while the player waits, the end of
the input, a damaged file. `av2_serve_check.py feed` serves a file for mpv by hand.
