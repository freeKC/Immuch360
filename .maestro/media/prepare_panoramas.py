#!/usr/bin/env python3
"""Prepares the equirectangular photos the screenshot flows add to the photo library of the iOS simulator.

usage:
  prepare_panoramas.py SRC DST [--gpano]   copy SRC to DST without its metadata; --gpano adds the GPano XMP of a full
                                            360 sphere, which is what the app reads to list a photo of the device as 360
  prepare_panoramas.py --check DIR          for every JPEG under DIR: size, frame, and whether GPano XMP is in the
                                            first 128 KiB (where the app looks for it)

Only the Python standard library: the Codemagic Mac has no Pillow and exiftool is not guaranteed there.

The EXIF, XMP, Photoshop and comment segments are dropped, so that the photo library dates every photo at its import,
in the order the workflow adds them; the frame, the colour profile and the image data are copied as they are.
"""
import os
import sys

XMP_HEADER = b'http://ns.adobe.com/xap/1.0/\x00'
GPANO_WINDOW = 131072

# Segments dropped: APP1 (EXIF or XMP), APP13 (Photoshop, IPTC), COM
DROPPED = {0xE1, 0xED, 0xFE}
# Markers without a length: the restart markers and TEM
STANDALONE = set(range(0xD0, 0xD8)) | {0x01}
# Start of frame markers, which carry the size of the image
SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def segments(data):
    """The segments before the image data: (marker, payload) pairs, then the offset of the SOS marker"""
    if data[:2] != b'\xff\xd8':
        raise ValueError('not a JPEG file')
    out = []
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            raise ValueError(f'no marker at offset {i}')
        while data[i] == 0xFF:
            i += 1
        marker = data[i]
        i += 1
        if marker == 0xDA:
            return out, i - 2
        if marker in STANDALONE:
            out.append((marker, None))
            continue
        length = int.from_bytes(data[i:i + 2], 'big')
        out.append((marker, data[i + 2:i + length]))
        i += length
    raise ValueError('no image data')


def frame_size(segs):
    for marker, payload in segs:
        if marker in SOF:
            return int.from_bytes(payload[3:5], 'big'), int.from_bytes(payload[1:3], 'big')
    raise ValueError('no frame header')


def gpano_xmp(width, height):
    xmp = (
        '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '    xmlns:GPano="http://ns.google.com/photos/1.0/panorama/"\n'
        '   GPano:UsePanoramaViewer="True"\n'
        '   GPano:ProjectionType="equirectangular"\n'
        f'   GPano:CroppedAreaImageWidthPixels="{width}"\n'
        f'   GPano:CroppedAreaImageHeightPixels="{height}"\n'
        f'   GPano:FullPanoWidthPixels="{width}"\n'
        f'   GPano:FullPanoHeightPixels="{height}"\n'
        '   GPano:CroppedAreaLeftPixels="0"\n'
        '   GPano:CroppedAreaTopPixels="0"/>\n'
        ' </rdf:RDF>\n'
        '</x:xmpmeta>\n'
        '<?xpacket end="w"?>'
    )
    return XMP_HEADER + xmp.encode('utf-8')


def segment(marker, payload):
    if len(payload) + 2 > 0xFFFF:
        raise ValueError('segment too long')
    return bytes([0xFF, marker]) + (len(payload) + 2).to_bytes(2, 'big') + payload


def prepare(src, dst, gpano):
    data = open(src, 'rb').read()
    segs, sos = segments(data)
    width, height = frame_size(segs)
    kept = [(m, p) for m, p in segs if m not in DROPPED]
    out = bytearray(b'\xff\xd8')
    inserted = not gpano
    for marker, payload in kept:
        # The XMP right after the JFIF header, else first
        if not inserted and marker != 0xE0:
            out += segment(0xE1, gpano_xmp(width, height))
            inserted = True
        out += bytes([0xFF, marker]) if payload is None else segment(marker, payload)
    if not inserted:
        out += segment(0xE1, gpano_xmp(width, height))
    out += data[sos:]
    with open(dst, 'wb') as f:
        f.write(out)
    print(f'{os.path.basename(dst)}: {width}x{height}, {len(out)} bytes, GPano {"yes" if gpano else "no"}, '
          f'{len(segs) - len(kept)} metadata segments dropped')


def check(folder):
    found = False
    for root, _, files in os.walk(folder):
        for name in sorted(files):
            if not name.lower().endswith(('.jpg', '.jpeg')):
                continue
            path = os.path.join(root, name)
            data = open(path, 'rb').read()
            try:
                width, height = frame_size(segments(data)[0])
                frame = f'{width}x{height}'
            except ValueError as error:
                frame = f'unreadable ({error})'
            head = data[:GPANO_WINDOW]
            gpano = b'GPano:ProjectionType="equirectangular"' in head or \
                b'<GPano:ProjectionType>equirectangular' in head
            print(f'{path}: {len(data)} bytes, {frame}, GPano in the first 128 KiB: {"yes" if gpano else "no"}')
            found = True
    if not found:
        print(f'no JPEG under {folder}')


def main(argv):
    if len(argv) == 3 and argv[1] == '--check':
        check(argv[2])
    elif len(argv) in (3, 4) and (len(argv) == 3 or argv[3] == '--gpano'):
        prepare(argv[1], argv[2], gpano=len(argv) == 4)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
