#!/usr/bin/env python3
"""The two JPEGs of known colours the tests of src/tests.rs decode, written by Pillow (libjpeg-turbo), the reference
the codec is checked against: a strip of eight 8 x 8 blocks at quality 100 in 4:4:4, each block of one colour.

- adobe_cmyk.jpg: CMYK inks stored inverted with an Adobe APP14 segment (transform 0), as Photoshop writes them
- adobe_rgb.jpg: RGB stored as is, Adobe APP14 segment with transform 0 and components R, G and B (keep_rgb)

The colours are those of CMYK_INKS and RGB_STORED in src/tests.rs. Run again with the same Pillow to get the same
bytes: python3 make_fixtures.py (Pillow 10.2.0 and libjpeg-turbo 3.0.1 wrote the files of the repository).
"""

import io
import pathlib

from PIL import Image

CMYK_INKS = [
    (0, 0, 0, 0),
    (255, 0, 0, 0),
    (0, 255, 0, 0),
    (0, 0, 255, 0),
    (0, 0, 0, 255),
    (0, 0, 0, 128),
    (0, 128, 255, 64),
    (200, 40, 10, 30),
]

RGB_STORED = [
    (255, 255, 255),
    (255, 0, 0),
    (0, 255, 0),
    (0, 0, 255),
    (0, 0, 0),
    (200, 100, 50),
    (30, 160, 220),
    (128, 128, 128),
]


def strip(mode, colours):
    image = Image.new(mode, (8 * len(colours), 8))
    for index, colour in enumerate(colours):
        image.paste(colour, (8 * index, 0, 8 * index + 8, 8))
    return image


def main():
    here = pathlib.Path(__file__).resolve().parent
    for name, image, extra in [
        ('adobe_cmyk.jpg', strip('CMYK', CMYK_INKS), {}),
        ('adobe_rgb.jpg', strip('RGB', RGB_STORED), {'keep_rgb': True}),
    ]:
        out = io.BytesIO()
        image.save(out, 'JPEG', quality=100, subsampling=0, **extra)
        (here / name).write_bytes(out.getvalue())
        decoded = Image.open(io.BytesIO(out.getvalue())).convert('RGB')
        centres = [decoded.getpixel((8 * index + 4, 4)) for index in range(8)]
        print(f'{name}: {len(out.getvalue())} bytes, read back by Pillow as {centres}')


if __name__ == '__main__':
    main()
