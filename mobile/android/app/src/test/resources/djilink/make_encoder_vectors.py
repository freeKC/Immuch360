#!/usr/bin/env python3
"""H.265 access units made by libx265 on this PC, as a fixture of EncodedUnitsTest: what a phone's encoder gives the
steady stream (p2/relay-bandwidth-2026-10-25.md, 7.3), written apart from the app's code.

1. "a1080": 1920x1080 at 30 a second, coded with 16 pixel units so that the SPS says 1088 lines with a conformance
   window of 8, a key picture every 3 pictures, no B pictures, VPS, SPS and PPS before every key picture (IDR, then
   CRA): four access units.
2. "b720": 1280x720, one key picture and one P picture, its VPS, SPS and PPS cut off into a codec configuration buffer
   of their own, as Android's encoders give them when the headers are not asked before each key picture.

Needs ffmpeg with libx265.  make_encoder_vectors.py > relay-encoder-vectors.json
"""
import json
import subprocess
import tempfile

VPS, SPS, PPS = 32, 33, 34


def encode(size, frames, params):
    with tempfile.NamedTemporaryFile(suffix='.hevc') as out:
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                        f'testsrc2=size={size}:rate=30', '-frames:v', str(frames), '-c:v', 'libx265', '-preset',
                        'ultrafast', '-x265-params', params, '-crf', '45', '-f', 'hevc', out.name], check=True)
        return open(out.name, 'rb').read()


def nals(stream):
    """(start of the start code, type) of every NAL unit"""
    found = []
    index = 0
    while True:
        at = stream.find(b'\x00\x00\x01', index)
        if at < 0:
            return found
        start = at - 1 if at > 0 and stream[at - 1] == 0 else at
        found.append((start, (stream[at + 3] >> 1) & 0x3F))
        index = at + 3


def units(stream):
    """Access units cut before a parameter set or a first slice that follows a slice"""
    cuts = []
    seen_slice = False
    for start, kind in nals(stream):
        boundary = kind in (VPS, SPS, PPS, 35, 39) or (kind < 32 and seen_slice)
        if not cuts or (boundary and seen_slice):
            cuts.append(start)
            seen_slice = False
        if kind < 32:
            seen_slice = True
    return [stream[a:b] for a, b in zip(cuts, cuts[1:] + [len(stream)])]


def main():
    params = 'bframes=0:info=0:log-level=error:scenecut=0:repeat-headers=1'
    a1080 = units(encode('1920x1080', 4, params + ':keyint=3:min-keyint=3:min-cu-size=16'))
    b720 = units(encode('1280x720', 2, params + ':keyint=30'))
    first = b720[0]
    slice_at = next(start for start, kind in nals(first) if kind < 32)
    vectors = {
        'a1080': {'units': [u.hex() for u in a1080]},
        'b720': {'config': first[:slice_at].hex(), 'units': [first[slice_at:].hex()] + [u.hex() for u in b720[1:]]},
    }
    print(json.dumps(vectors, indent=1))


if __name__ == '__main__':
    main()
