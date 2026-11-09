#!/usr/bin/env python3
"""Prepares the equirectangular photos the screenshot flows add to the photo library of the iOS simulator.

usage:
  prepare_panoramas.py SRC DST DATE [--gpano]
                         copy SRC to DST without its metadata, dated DATE ("YYYY:MM:DD HH:MM:SS") in a new EXIF;
                         --gpano adds the GPano XMP of a full 360 sphere, which is what the app reads to list a photo
                         of the device as 360
  prepare_panoramas.py --check DIR
                         for every JPEG under DIR: size, frame, EXIF date, and whether GPano XMP is in the first
                         128 KiB (where the app looks for it)

Only the Python standard library: the Codemagic Mac has no Pillow and exiftool is not guaranteed there.

The EXIF, XMP, Photoshop and comment segments of SRC are dropped; the frame, the colour profile and the image data are
copied as they are. The date fixes the order of the photos in the app, newest first: without one, the photo library
gives photos added within a few seconds the same date, and their order is left to chance.
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


def exif_dates(date):
    """An EXIF APP1 payload with DateTime, DateTimeOriginal and DateTimeDigitized set to DATE, and the EXIF version"""
    value = date.encode('ascii') + b'\x00'
    if len(value) != 20:
        raise ValueError(f'date must read YYYY:MM:DD HH:MM:SS, not {date!r}')

    def entry(tag, kind, count, value_or_offset):
        field = value_or_offset if isinstance(value_or_offset, bytes) else value_or_offset.to_bytes(4, 'big')
        return tag.to_bytes(2, 'big') + kind.to_bytes(2, 'big') + count.to_bytes(4, 'big') + field

    ascii_type, long_type, undefined_type = 2, 4, 7
    # Big endian TIFF header, IFD0 at 8: DateTime, then the pointer to the EXIF IFD, whose tags follow in their order
    ifd0_at = 8
    datetime_at = ifd0_at + 2 + 2 * 12 + 4
    exif_ifd_at = datetime_at + 20
    original_at = exif_ifd_at + 2 + 3 * 12 + 4
    digitized_at = original_at + 20
    tiff = b'MM\x00\x2a' + ifd0_at.to_bytes(4, 'big')
    tiff += (2).to_bytes(2, 'big') + entry(0x0132, ascii_type, 20, datetime_at) + \
        entry(0x8769, long_type, 1, exif_ifd_at) + (0).to_bytes(4, 'big')
    tiff += value
    tiff += (3).to_bytes(2, 'big') + entry(0x9000, undefined_type, 4, b'0232') + \
        entry(0x9003, ascii_type, 20, original_at) + entry(0x9004, ascii_type, 20, digitized_at) + \
        (0).to_bytes(4, 'big')
    tiff += value + value
    return b'Exif\x00\x00' + tiff


def exif_date(payload):
    """DateTimeOriginal of an EXIF APP1 payload written by exif_dates, or of any big or little endian one"""
    if not payload.startswith(b'Exif\x00\x00'):
        return None
    tiff = payload[6:]
    order = 'big' if tiff[:2] == b'MM' else 'little'

    def u16(at):
        return int.from_bytes(tiff[at:at + 2], order)

    def u32(at):
        return int.from_bytes(tiff[at:at + 4], order)

    def find(ifd, tag):
        for i in range(u16(ifd)):
            at = ifd + 2 + 12 * i
            if u16(at) == tag:
                return at
        return None

    pointer = find(u32(4), 0x8769)
    if pointer is None:
        return None
    original = find(u32(pointer + 8), 0x9003)
    if original is None:
        return None
    offset = u32(original + 8)
    return tiff[offset:offset + 19].decode('ascii', 'replace')


def segment(marker, payload):
    if len(payload) + 2 > 0xFFFF:
        raise ValueError('segment too long')
    return bytes([0xFF, marker]) + (len(payload) + 2).to_bytes(2, 'big') + payload


def prepare(src, dst, date, gpano):
    data = open(src, 'rb').read()
    segs, sos = segments(data)
    width, height = frame_size(segs)
    kept = [(m, p) for m, p in segs if m not in DROPPED]
    added = [segment(0xE1, exif_dates(date))]
    if gpano:
        added.append(segment(0xE1, gpano_xmp(width, height)))
    out = bytearray(b'\xff\xd8')
    inserted = False
    for marker, payload in kept:
        # The EXIF then the XMP right after the JFIF header, else first
        if not inserted and marker != 0xE0:
            out += b''.join(added)
            inserted = True
        out += bytes([0xFF, marker]) if payload is None else segment(marker, payload)
    if not inserted:
        out += b''.join(added)
    out += data[sos:]
    with open(dst, 'wb') as f:
        f.write(out)
    print(f'{os.path.basename(dst)}: {width}x{height}, {len(out)} bytes, dated {date}, '
          f'GPano {"yes" if gpano else "no"}, {len(segs) - len(kept)} metadata segments dropped')


def check(folder):
    found = False
    for root, _, files in os.walk(folder):
        for name in sorted(files):
            if not name.lower().endswith(('.jpg', '.jpeg')):
                continue
            path = os.path.join(root, name)
            data = open(path, 'rb').read()
            date = None
            try:
                segs = segments(data)[0]
                width, height = frame_size(segs)
                frame = f'{width}x{height}'
                date = next((d for m, p in segs if m == 0xE1 for d in [exif_date(p)] if d), None)
            except ValueError as error:
                frame = f'unreadable ({error})'
            head = data[:GPANO_WINDOW]
            gpano = b'GPano:ProjectionType="equirectangular"' in head or \
                b'<GPano:ProjectionType>equirectangular' in head
            print(f'{path}: {len(data)} bytes, {frame}, dated {date}, '
                  f'GPano in the first 128 KiB: {"yes" if gpano else "no"}')
            found = True
    if not found:
        print(f'no JPEG under {folder}')


def main(argv):
    if len(argv) == 3 and argv[1] == '--check':
        check(argv[2])
    elif len(argv) in (4, 5) and (len(argv) == 4 or argv[4] == '--gpano'):
        prepare(argv[1], argv[2], argv[3], gpano=len(argv) == 5)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
