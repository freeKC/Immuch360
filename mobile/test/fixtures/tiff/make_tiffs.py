"""Writes the TIFF fixtures of test/domain/services/tiff_decoder_test.dart.

The files come from other writers than the image package (tifffile 2024.9.20 with imagecodecs, Pillow 10.2.0), with the
options photo editors use: LZW and Deflate with the horizontal predictor, 16 bit samples, tiles, big endian, pages,
planes, CMYK, a palette, and the files the decoder must refuse (JPEG in TIFF, the floating point predictor, a damaged
strip). Their pixels follow sample(x, y, channel, bits) below, which the test computes again.

    python3 make_tiffs.py   (in this folder)
"""

import io

import numpy as np
import tifffile
from PIL import Image


def sample(x, y, c, bits):
    """A value that changes from one pixel to the next, and wraps, so that a wrong predictor or byte order shows"""
    v = ((x * 7919 + y * 104729 + c * 31337 + 17) * 2654435761) >> 13
    return v & ((1 << bits) - 1)


def picture(width, height, channels, bits):
    dtype = np.uint8 if bits == 8 else np.uint16
    out = np.zeros((height, width, channels), dtype=dtype)
    for y in range(height):
        for x in range(width):
            for c in range(channels):
                out[y, x, c] = sample(x, y, c, bits)
    return out


def write(name, data, **options):
    separate = options.get('planarconfig') == 'separate'
    # One plane after the other: the samples first
    tifffile.imwrite(name, np.moveaxis(data, -1, 0) if separate else data, **options)
    back = tifffile.imread(name)
    if separate:
        back = np.moveaxis(back, 0, -1)
    assert np.array_equal(back.reshape(data.shape), data), name


rgb8 = picture(64, 32, 3, 8)
rgb16 = picture(64, 32, 3, 16)

write('rgb8_lzw_pred.tif', rgb8, photometric='rgb', compression='lzw', predictor=True)
write('rgb8_deflate_pred.tif', rgb8, photometric='rgb', compression='zlib', predictor=True)
write('rgb16_lzw_pred.tif', rgb16, photometric='rgb', compression='lzw', predictor=True)
write('rgb16_deflate_pred.tif', rgb16, photometric='rgb', compression='zlib', predictor=True)
write('rgb16_be_lzw_pred.tif', rgb16, photometric='rgb', compression='lzw', predictor=True, byteorder='>')
write('rgb16_be_none.tif', rgb16, photometric='rgb', byteorder='>')
write('rgb8_lzw_noise.tif', picture(96, 64, 3, 8), photometric='rgb', compression='lzw')
write('rgb8_tiled_deflate_pred.tif', picture(72, 40, 3, 8), photometric='rgb', compression='zlib', predictor=True,
      tile=(16, 16))
write('rgb16_tiled_lzw_pred.tif', picture(72, 40, 3, 16), photometric='rgb', compression='lzw', predictor=True,
      tile=(16, 16))
write('rgb8_planar_lzw_pred.tif', rgb8, photometric='rgb', compression='lzw', predictor=True,
      planarconfig='separate')
write('rgba8_deflate_pred.tif', picture(64, 32, 4, 8), photometric='rgb', compression='zlib', predictor=True,
      extrasamples=['unassalpha'])
write('gray16_lzw_pred.tif', picture(64, 32, 1, 16)[:, :, 0], photometric='minisblack', compression='lzw',
      predictor=True)
write('cmyk8_lzw.tif', picture(64, 32, 4, 8), photometric='separated', compression='lzw')
write('rgb8_strips_lzw_pred.tif', rgb8, photometric='rgb', compression='lzw', predictor=True, rowsperstrip=5)

with tifffile.TiffWriter('pages_lzw_pred.tif') as tif:
    tif.write(rgb8, photometric='rgb', compression='lzw', predictor=True)
    tif.write(np.zeros((32, 64, 3), dtype=np.uint8), photometric='rgb', compression='lzw', predictor=True)

palette = picture(64, 32, 1, 8)[:, :, 0]
colors = np.array([[sample(i, 0, c, 16) for i in range(256)] for c in range(3)], dtype=np.uint16)
write('palette8_lzw.tif', palette, photometric='palette', colormap=colors, compression='lzw')

Image.fromarray(rgb8).save('rgb8_packbits_pillow.tif', compression='packbits')
write('rgb8_lzw_pred_orientation6.tif', rgb8, photometric='rgb', compression='lzw', predictor=True,
      extratags=[(274, 'H', 1, 6, True)])


def smooth(width, height):
    """A gradient, for the JPEG in TIFF files: JPEG keeps it within a few levels"""
    y, x = np.mgrid[0:height, 0:width]
    return np.stack([x * 255 // (width - 1), y * 255 // (height - 1), (x + y) * 255 // (width + height - 2)],
                    -1).astype(np.uint8)


# tifffile turns RGB into YCbCr for JPEG, each strip a whole JPEG; Pillow (libtiff) keeps RGB, its tables shared
tifffile.imwrite('smooth_jpeg_ycbcr.tif', smooth(96, 64), photometric='rgb', compression='jpeg')
tifffile.imwrite('smooth_jpeg_tiled.tif', smooth(72, 40), photometric='rgb', compression='jpeg', tile=(16, 16))
Image.fromarray(smooth(96, 64)).save('smooth_jpeg_rgb_tables.tif', compression='jpeg')

# The JPEG of the TIFF 6.0 era (compression 6), which nothing should write any more: the tag of a JPEG in TIFF changed
data = bytearray(open('smooth_jpeg_ycbcr.tif', 'rb').read())
with tifffile.TiffFile(io.BytesIO(bytes(data))) as tif:
    where = tif.pages[0].tags['Compression'].valueoffset
data[where:where + 2] = (6).to_bytes(2, 'little')
open('old_jpeg.tif', 'wb').write(bytes(data))
tifffile.imwrite('float32_pred3.tif', picture(64, 32, 1, 16)[:, :, 0].astype(np.float32), compression='zlib',
                 predictor=3)

# A strip of LZW cut short, as a copy that stopped half way: its byte count halved, its data ending there
data = bytearray(open('rgb8_lzw_noise.tif', 'rb').read())
with tifffile.TiffFile(io.BytesIO(bytes(data))) as tif:
    page = tif.pages[0]
    assert len(page.dataoffsets) == 1
    offset, count = page.dataoffsets[0], page.databytecounts[0]
    counts = page.tags['StripByteCounts']
    assert counts.count == 1 and counts.dtype == 4, counts
    where = counts.valueoffset
data[where:where + 4] = (count // 2).to_bytes(4, 'little')
open('rgb8_lzw_damaged.tif', 'wb').write(bytes(data[:offset + count // 2]))
try:
    tifffile.imread('rgb8_lzw_damaged.tif')
    raise AssertionError('tifffile reads the damaged strip')
except AssertionError:
    raise
except Exception as error:
    print('tifffile refuses the damaged strip:', type(error).__name__)
