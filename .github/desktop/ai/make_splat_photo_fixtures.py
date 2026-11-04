#!/usr/bin/env python3
"""The splat photos of the plan of 3 November 2026 (store/m2/splat-photo-2026-11-03/plan.md, lot L1): the fixtures the
Dart tests read, written by this script from the contract, never by the code under test.

A splat photo is "<stem>_splat.jpg": a JPEG poster cleaned of its other metadata and trailers, our EXIF (Orientation 1,
the scene's date and place, Software, 4 KiB of the Microsoft padding tag 0xEA1C in IFD0), our XMP packet (namespace
http://ns.aprogsys.com/immuch360/1.0/, Kind GaussianSplat, FormatVersion 1, 4 KiB of whitespace before its end, ending
before byte 65,536), the poster's ICC profile and pixels, its EOI, then the SPZ byte for byte as the last SplatLength
bytes, checked by SplatSha256. The writer here is a second writing of lib/domain/services/splat_photo/
splat_photo_writer.dart: the Dart writer must give these files byte for byte from the same poster, scene and facts.

  make_splat_photo_fixtures.py            writes mobile/test/fixtures/splat_photo/ and splat_photo_contract_v1.json
  make_splat_photo_fixtures.py --check    exit 1 when a fixture differs from what this script writes; the posters
                                          PIL encodes and the file exiftool edits are read from the folder, never
                                          made again, so that another PIL or exiftool changes nothing
  make_splat_photo_fixtures.py --posters  also encodes the posters again with PIL (a new fixture set)
  make_splat_photo_fixtures.py --write SPZ POSTER OUT [--name N] [--date ISO]
                                          writes one splat photo (the measures of lot L1, never for the app)

The fixtures (the scenes are axes_v2.spz, axes_v4.spz and sh3.ply of ../splat, make_splat_fixtures.py):

  poster.jpg                  the poster, 48 x 32, a gradient with a mark, JPEG quality 85 (PIL)
  poster_motion.jpg           poster.jpg with an APP1 of GCamera MotionPhoto and Container items and an "MP4" after its
                              EOI, as a motion photo; written with axes_v2.spz it gives ok_v2.jpg
  poster_ultrahdr.jpg         poster.jpg with an APP2 MPF, an EXIF, a comment, and a gain map JPEG after its EOI;
                              written with axes_v2.spz it gives ok_v2.jpg
  poster_2to1.jpg, poster_square.jpg   64 x 32 and 32 x 32: refused for their shape
  ok_v2.jpg, ok_v4.jpg        poster.jpg with axes_v2.spz, and with axes_v4.spz (a date west of Greenwich, a place,
                              SplatUp, SplatPoster and a description to escape)
  ok_exiftool.jpg             ok_v2.jpg after exiftool 12.57 -Title= -Rating= (its head written again, the packet as
                              elements in three descriptions; the scene keeps its place from the end)
  bad_sum.jpg                 ok_v2.jpg with its last byte changed
  cut_tail.jpg                ok_v2.jpg without its last 100 bytes
  trailer.jpg                 ok_v2.jpg and a 64 byte trailer after the scene
  reencoded_with_xmp.jpg      the poster encoded again by PIL at quality 80, our packet copied, no scene (an editor)
  reencoded_plain.jpg         the poster encoded again, nothing copied
  huge_claim.jpg              a packet that says SplatLength 3000000000, on a file of a few KB
  newer_format.jpg            FormatVersion 2
  newer_payload.jpg           SplatFormat spz-2
  ply_payload.jpg             SplatFormat ply, sh3.ply as the tail
  head_mismatch.jpg           SplatGaussians 999 where the SPZ holds 686
  png_with_packet.png         a PNG whose iTXt holds the packet of ok_v2.jpg

splat_photo_contract_v1.json holds what the tests compare with: for each file, the packet it holds, the verdict of the
check of its scene (ok, missing, notSpz, wrongSum, newer, lost, or notCarrier), the head of its SPZ, its length, its
SHA-1 and its SHA-256. PIL (MIT-CMU) only; exiftool for ok_exiftool.jpg when it is made. Tools only: nothing of them
is shipped.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "mobile" / "test" / "fixtures" / "splat_photo"
SPLATS = ROOT / "mobile" / "test" / "fixtures" / "splat"

NAMESPACE = "http://ns.aprogsys.com/immuch360/1.0/"
XMP_BASIC = "http://ns.adobe.com/xap/1.0/"
DUBLIN_CORE = "http://purl.org/dc/elements/1.1/"
XMP_SIGNATURE = b"http://ns.adobe.com/xap/1.0/\x00"
PADDING = 4096
PACKET_WITHIN = 65536
RATIO_MIN, RATIO_MAX, LONGEST = 1.25, 1.85, 2048
POSTER_MAX = 1 << 20

POSTERS = ["poster.jpg", "poster_2to1.jpg", "poster_square.jpg", "reencoded_with_xmp.jpg", "reencoded_plain.jpg",
           "png_with_packet.png", "ok_exiftool.jpg"]


# --- The packet: xmpPacket of immersive_xmp.dart, then the padding ----------------------------------------------------

def xmp_safe(value: str) -> str:
    return "".join("\ufffd" if (ord(c) < 0x20 and c not in "\t\n\r") else c for c in value)


def xmp_escape(value: str) -> str:
    return (xmp_safe(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
            .replace("=", "&#x3D;").replace("\n", "&#xA;").replace("\r", "&#xD;").replace("\t", "&#x9;"))


def whitespace(length: int) -> str:
    out = []
    left = length
    while left > 0:
        line = 100 if left >= 100 else left
        out.append(" " * (line - 1) + "\n")
        left -= line
    return "".join(out)


def xmp_packet(fields: list, description: str | None) -> str:
    out = ['<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n', '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n',
           ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n', '  <rdf:Description rdf:about=""']
    for prefix, uri in [("xmp", XMP_BASIC), ("dc", DUBLIN_CORE), ("Immuch360", NAMESPACE)]:
        out.append(f'\n    xmlns:{prefix}="{uri}"')
    for name, value in fields:
        out.append(f'\n    {name}="{xmp_escape(value)}"')
    if description is None:
        out.append("/>\n")
    else:
        out.append(">\n")
        out.append('   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">' + xmp_escape(description)
                   + "</rdf:li></rdf:Alt>")
        out.append("</dc:description>\n")
        out.append("  </rdf:Description>\n")
    out.append(" </rdf:RDF>\n</x:xmpmeta>\n")
    out.append(whitespace(PADDING))
    out.append('<?xpacket end="w"?>\n')
    return "".join(out)


def packet_fields(p: dict) -> list:
    """The attributes in the order SplatPhotoXmp.toXml writes them"""
    order = [("xmp:CreatorTool", "creatorTool"), ("Immuch360:FormatVersion", "formatVersion"),
             ("Immuch360:Kind", "kind"), ("Immuch360:Origin", "origin"), ("Immuch360:Created", "created"),
             ("Immuch360:SplatFormat", "splatFormat"), ("Immuch360:SplatVersion", "splatVersion"),
             ("Immuch360:SplatGaussians", "splatGaussians"), ("Immuch360:SplatShDegree", "splatShDegree"),
             ("Immuch360:SplatLength", "splatLength"), ("Immuch360:SplatSha256", "splatSha256"),
             ("Immuch360:SplatName", "splatName"), ("Immuch360:SplatSourceSha256", "splatSourceSha256"),
             ("Immuch360:SplatUp", "splatUp"), ("Immuch360:SplatPoster", "splatPoster")]
    return [(name, str(p[key])) for name, key in order if p.get(key) is not None]


# --- The EXIF: splat_photo_exif.dart -----------------------------------------------------------------------------------

BYTE, ASCII, SHORT, LONG, RATIONAL, UNDEFINED = 1, 2, 3, 4, 5, 7
SIZES = {BYTE: 1, ASCII: 1, SHORT: 2, LONG: 4, RATIONAL: 8, UNDEFINED: 1}


def shorts(*values):
    return b"".join(struct.pack("<H", v) for v in values)


def longs(*values):
    return b"".join(struct.pack("<I", v) for v in values)


def rationals(pairs):
    return b"".join(struct.pack("<II", n, d) for n, d in pairs)


def ascii_entry(tag, text):
    data = text.encode("latin-1") + b"\x00"
    return (tag, ASCII, len(data), data)


def padding_value(length=PADDING):
    return bytes([0x1C, 0xEA, 0, 0, 0, 8]) + bytes(length - 6)


def ifd(entries, offset, next_ifd=0):
    entries = sorted(entries, key=lambda e: e[0])
    table_length = 2 + 12 * len(entries) + 4
    table = bytearray(struct.pack("<H", len(entries)))
    data = bytearray()
    # The padding first, right after the table: Windows grows the table into it when it adds a tag in place
    for tag, kind, count, value in sorted(entries, key=lambda e: e[0] != 0xEA1C):
        size = count * SIZES[kind]
        if size > 4:
            data += value + (b"\x00" if size % 2 else b"")
    places, at = {}, 0
    for tag, kind, count, value in sorted(entries, key=lambda e: e[0] != 0xEA1C):
        size = count * SIZES[kind]
        if size > 4:
            places[tag] = at
            at += size + size % 2
    for tag, kind, count, value in entries:
        size = count * SIZES[kind]
        assert len(value) == size, hex(tag)
        table += struct.pack("<HHI", tag, kind, count)
        if size <= 4:
            table += value + bytes(4 - size)
        else:
            table += struct.pack("<I", offset + table_length + places[tag])
    table += struct.pack("<I", next_ifd)
    return bytes(table + data)


def dms(degrees: float):
    value = abs(degrees)
    whole = int(value // 1)
    minutes = int(((value - whole) * 60) // 1)
    seconds = round(((value - whole) * 60 - minutes) * 60 * 10000)
    if seconds >= 600000:
        seconds -= 600000
        minutes += 1
    if minutes >= 60:
        minutes -= 60
        whole += 1
    return [(whole, 1), (minutes, 1), (seconds, 10000)]


def exif(width, height, software, date=None, latitude=None, longitude=None):
    has_place = latitude is not None and longitude is not None
    def ifd0_entries(exif_offset, gps_offset):
        entries = [(0x0112, SHORT, 1, shorts(1)), (0x011A, RATIONAL, 1, rationals([(72, 1)])),
                   (0x011B, RATIONAL, 1, rationals([(72, 1)])), (0x0128, SHORT, 1, shorts(2)),
                   ascii_entry(0x0131, software), (0x0213, SHORT, 1, shorts(1)), (0x8769, LONG, 1, longs(exif_offset))]
        if gps_offset is not None:
            entries.append((0x8825, LONG, 1, longs(gps_offset)))
        entries.append((0xEA1C, UNDEFINED, PADDING, padding_value()))
        return entries
    ifd0_size = len(ifd(ifd0_entries(0, 0 if has_place else None), 8))
    exif_offset = 8 + ifd0_size
    entries = [(0x9000, UNDEFINED, 4, b"0232")]
    if date is not None:
        entries.append(ascii_entry(0x9003, date["exif"]))
        entries.append(ascii_entry(0x9011, date["offset"]))
    entries += [(0x9101, UNDEFINED, 4, bytes([1, 2, 3, 0])), (0xA000, UNDEFINED, 4, b"0100"),
                (0xA001, SHORT, 1, shorts(1)), (0xA002, LONG, 1, longs(width)), (0xA003, LONG, 1, longs(height))]
    exif_ifd = ifd(entries, exif_offset)
    gps_offset = exif_offset + len(exif_ifd) if has_place else None
    gps = b""
    if has_place:
        gps = ifd([(0x0000, BYTE, 4, bytes([2, 3, 0, 0])), ascii_entry(0x0001, "N" if latitude >= 0 else "S"),
                   (0x0002, RATIONAL, 3, rationals(dms(latitude))), ascii_entry(0x0003, "E" if longitude >= 0 else "W"),
                   (0x0004, RATIONAL, 3, rationals(dms(longitude)))], gps_offset)
    ifd0 = ifd(ifd0_entries(exif_offset, gps_offset), 8)
    return b"Exif\x00\x00" + b"II*\x00\x08\x00\x00\x00" + ifd0 + exif_ifd + gps


def date_of(year, month, day, hour, minute, second, offset_minutes):
    sign = "-" if offset_minutes < 0 else "+"
    m = abs(offset_minutes)
    offset = f"{sign}{m // 60:02d}:{m % 60:02d}"
    return {"exif": f"{year:04d}:{month:02d}:{day:02d} {hour:02d}:{minute:02d}:{second:02d}", "offset": offset,
            "iso": f"{year:04d}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}{offset}"}


# --- The JPEG: jpeg_walk.dart and the cleaning of splat_photo_writer.dart -----------------------------------------------

def is_sof(marker):
    return 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC)


def walk(data: bytes):
    """[(marker, offset, end, header_end)], the end of the EOI, width, height"""
    assert data[:2] == b"\xff\xd8", "no SOI"
    segments, width, height, at = [], 0, 0, 2
    while True:
        assert data[at] == 0xFF, f"no marker at {at}"
        while data[at] == 0xFF:
            at += 1
        marker = data[at]
        at += 1
        if marker == 0xD9:
            return segments, at, width, height
        if 0xD0 <= marker <= 0xD7 or marker == 0x01:
            segments.append((marker, at - 2, at, at))
            continue
        length = struct.unpack(">H", data[at:at + 2])[0]
        offset, header_end = at - 2, at + length
        if is_sof(marker):
            height, width = struct.unpack(">HH", data[at + 3:at + 7])
        if marker == 0xDA:
            end = header_end
            while True:
                if data[end] != 0xFF:
                    end += 1
                    continue
                nxt = data[end + 1]
                if nxt == 0x00 or 0xD0 <= nxt <= 0xD7:
                    end += 2
                    continue
                if nxt == 0xFF:
                    end += 1
                    continue
                break
            segments.append((marker, offset, end, header_end))
            at = end
        else:
            segments.append((marker, offset, header_end, header_end))
            at = header_end


def clean_poster(jpeg: bytes, check_shape=True):
    segments, _, width, height = walk(jpeg)
    if check_shape:
        long, short = max(width, height), min(width, height)
        assert short > 0 and long <= LONGEST and RATIO_MIN <= long / short <= RATIO_MAX, "posterShape"
    app0, icc, rest = None, [], bytearray()
    for marker, offset, end, _ in segments:
        seg = jpeg[offset:end]
        payload = jpeg[offset + 4:end]
        if marker == 0xE0:
            if app0 is None and payload.startswith(b"JFIF\x00"):
                app0 = seg
        elif marker == 0xE2:
            if payload.startswith(b"ICC_PROFILE\x00"):
                icc.append(seg)
        elif marker == 0xEE:
            rest += seg
        elif 0xE0 <= marker <= 0xEF or marker == 0xFE:
            pass
        else:
            rest += seg
    rest += b"\xff\xd9"
    if icc and icc[0][4 + 12 + 2 + 16:4 + 12 + 2 + 20] != b"RGB ":
        icc = []
    poster = {"app0": app0, "icc": icc, "rest": bytes(rest), "width": width, "height": height}
    assert 2 + len(app0 or b"") + sum(len(c) for c in icc) + len(rest) <= POSTER_MAX, "posterTooLarge"
    return poster


def segment(marker, signature, payload):
    length = len(signature) + len(payload) + 2
    assert length - 2 <= 65533
    return bytes([0xFF, marker, length >> 8, length & 0xFF]) + signature + payload


def head_of(poster, exif_bytes, packet: str):
    out = bytearray(b"\xff\xd8")
    if poster["app0"]:
        out += poster["app0"]
    out += segment(0xE1, b"", exif_bytes)
    out += segment(0xE1, XMP_SIGNATURE, packet.encode("utf-8"))
    assert len(out) <= PACKET_WITHIN, "packetTooLate"
    for chunk in poster["icc"]:
        out += chunk
    out += poster["rest"]
    return bytes(out)


# --- The scenes ---------------------------------------------------------------------------------------------------------

def spz_head(data: bytes):
    """version, gaussians, degree of an SPZ"""
    if data[:2] == b"\x1f\x8b":
        header = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(data[:4096], 16)
    else:
        header = data[:16]
    magic, version, count = struct.unpack("<III", header[:12])
    assert magic == 0x5053474E
    return version, count, header[12]


def packet_for(scene: bytes, name: str, date, description, *, up=None, poster_kind=None, source=None, overrides=None):
    version, count, degree = spz_head(scene)
    sha = hashlib.sha256(scene).hexdigest()
    p = {"creatorTool": "Immuch360 fixtures (test)", "formatVersion": 1, "kind": "GaussianSplat", "origin": "Unknown",
         "created": date["iso"], "splatFormat": "spz", "splatVersion": version, "splatGaussians": count,
         "splatShDegree": degree, "splatLength": len(scene), "splatSha256": sha, "splatName": name,
         "splatSourceSha256": source or sha, "splatUp": up, "splatPoster": poster_kind}
    p.update(overrides or {})
    return p


def splat_photo(poster_jpeg: bytes, scene: bytes, p: dict, description, date, *, latitude=None, longitude=None,
                software="Immuch360 fixtures", tail=None):
    poster = clean_poster(poster_jpeg)
    packet = xmp_packet(packet_fields(p), description)
    head = head_of(poster, exif(poster["width"], poster["height"], software, date, latitude, longitude), packet)
    return head + (scene if tail is None else tail)


DATE_V2 = date_of(2026, 11, 3, 16, 53, 0, 60)
DATE_V4 = date_of(2026, 7, 14, 9, 30, 15, -240)
DESCRIPTION_V2 = "Splat scene of 686 gaussians. Open it with Immuch360 to explore it."
DESCRIPTION_V4 = 'Scène "splat" de 686 gaussiennes & <axes> = ok'
PLACE_V4 = (48.858222, -2.2945)


def make_posters():
    from PIL import Image, ImageDraw
    def poster(width, height):
        img = Image.new("RGB", (width, height))
        px = img.load()
        for y in range(height):
            for x in range(width):
                px[x, y] = (int(255 * x / (width - 1)), int(255 * y / (height - 1)), 96)
        ImageDraw.Draw(img).rectangle([width - 12, height - 10, width - 3, height - 3], fill=(240, 240, 240))
        return img
    def jpeg(img, quality=85):
        out = io.BytesIO()
        img.save(out, "JPEG", quality=quality)
        return out.getvalue()
    return {"poster.jpg": jpeg(poster(48, 32)), "poster_2to1.jpg": jpeg(poster(64, 32)),
            "poster_square.jpg": jpeg(poster(32, 32)), "_reencoded": jpeg(poster(48, 32), 80)}


def png_with_packet(packet: str) -> bytes:
    from PIL import Image
    from PIL.PngImagePlugin import PngInfo
    info = PngInfo()
    info.add_itxt("XML:com.adobe.xmp", packet)
    out = io.BytesIO()
    Image.new("RGB", (48, 32), (40, 80, 120)).save(out, "PNG", pnginfo=info)
    return out.getvalue()


def insert_after_app0(jpeg: bytes, segments: bytes) -> bytes:
    segs, _, _, _ = walk(jpeg)
    at = 2
    if segs and segs[0][0] == 0xE0:
        at = segs[0][2]
    return jpeg[:at] + segments + jpeg[at:]


def fixtures(posters: dict) -> dict:
    axes_v2 = (SPLATS / "axes_v2.spz").read_bytes()
    axes_v4 = (SPLATS / "axes_v4.spz").read_bytes()
    sh3 = (SPLATS / "sh3.ply").read_bytes()
    poster = posters["poster.jpg"]
    files = {}
    p_v2 = packet_for(axes_v2, "axes_v2.spz", DATE_V2, DESCRIPTION_V2, poster_kind="card")
    ok_v2 = splat_photo(poster, axes_v2, p_v2, DESCRIPTION_V2, DATE_V2)
    files["ok_v2.jpg"] = ok_v2
    p_v4 = packet_for(axes_v4, "axes_v4.spz", DATE_V4, DESCRIPTION_V4, up="yUp", poster_kind="render")
    files["ok_v4.jpg"] = splat_photo(poster, axes_v4, p_v4, DESCRIPTION_V4, DATE_V4, latitude=PLACE_V4[0],
                                     longitude=PLACE_V4[1])
    # A motion photo: GCamera and Container in an APP1 XMP, an MP4 after the EOI
    motion_xmp = ('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                  '<rdf:Description rdf:about="" xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
                  'xmlns:Container="http://ns.google.com/photos/1.0/container/" GCamera:MotionPhoto="1" '
                  'GCamera:MotionPhotoVersion="1"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource">'
                  '<Container:Item Item:Semantic="MotionPhoto" Item:Length="200"/></rdf:li></rdf:Seq>'
                  '</Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>')
    mp4 = struct.pack(">I", 200) + b"ftypmp42" + bytes(188)
    files["poster_motion.jpg"] = insert_after_app0(poster, segment(0xE1, XMP_SIGNATURE, motion_xmp.encode())) + mp4
    # An Ultra HDR photo: an EXIF, an MPF, a comment, a gain map after the EOI
    gain = posters["poster_square.jpg"]
    mpf = segment(0xE2, b"MPF\x00", b"MM\x00\x2a\x00\x00\x00\x08" + bytes(40))
    other_exif = segment(0xE1, b"", b"Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00")
    comment = segment(0xFE, b"", b"a comment the writer drops")
    files["poster_ultrahdr.jpg"] = insert_after_app0(poster, other_exif + mpf + comment) + gain
    files["bad_sum.jpg"] = ok_v2[:-1] + bytes([ok_v2[-1] ^ 0xFF])
    files["cut_tail.jpg"] = ok_v2[:-100]
    files["trailer.jpg"] = ok_v2 + b"SEFH" + bytes(60)
    # An editor: the poster encoded again, the packet copied, the scene gone
    packet_v2 = xmp_packet(packet_fields(p_v2), DESCRIPTION_V2)
    files["reencoded_with_xmp.jpg"] = insert_after_app0(posters["_reencoded"],
                                                        segment(0xE1, XMP_SIGNATURE, packet_v2.encode("utf-8")))
    files["reencoded_plain.jpg"] = posters["_reencoded"]
    huge = dict(p_v2, splatLength=3000000000)
    files["huge_claim.jpg"] = splat_photo(poster, axes_v2, huge, DESCRIPTION_V2, DATE_V2)
    files["newer_format.jpg"] = splat_photo(poster, axes_v2, dict(p_v2, formatVersion=2), DESCRIPTION_V2, DATE_V2)
    files["newer_payload.jpg"] = splat_photo(poster, axes_v2, dict(p_v2, splatFormat="spz-2"), DESCRIPTION_V2, DATE_V2)
    sha_ply = hashlib.sha256(sh3).hexdigest()
    ply = dict(p_v2, splatFormat="ply", splatVersion=1, splatGaussians=8, splatShDegree=3, splatLength=len(sh3),
               splatSha256=sha_ply, splatSourceSha256=sha_ply, splatName="sh3.ply")
    files["ply_payload.jpg"] = splat_photo(poster, axes_v2, ply, DESCRIPTION_V2, DATE_V2, tail=sh3)
    files["head_mismatch.jpg"] = splat_photo(poster, axes_v2, dict(p_v2, splatGaussians=999), DESCRIPTION_V2, DATE_V2)
    files["png_with_packet.png"] = png_with_packet(packet_v2)
    return files, {"ok_v2.jpg": p_v2, "ok_v4.jpg": p_v4}


def verdict(data: bytes):
    """What the check of the scene of [data] gives, as splat_photo_tail.dart decides it"""
    if data[:2] != b"\xff\xd8":
        return None, "notCarrier", None
    head = data[:131072].decode("latin-1")
    at = head.find(NAMESPACE)
    if at < 0:
        return None, "notCarrier", None
    start = head.rfind("<x:xmpmeta", 0, at)
    end = head.find("</x:xmpmeta>", at)
    packet = data[start:end + len("</x:xmpmeta>")].decode("utf-8")
    def field(name):
        m = re.search(r'Immuch360:' + name + r'''\s*=\s*["']([^"']*)["']''', packet)
        if m is None:
            m = re.search(r'<Immuch360:' + name + r'>([^<]*)</Immuch360:' + name + '>', packet)
        return m.group(1).strip() if m else None
    if field("Kind") != "GaussianSplat":
        return None, "notCarrier", None
    fv, fmt, version = int(field("FormatVersion") or 1), field("SplatFormat"), int(field("SplatVersion") or 0)
    length, sha = int(field("SplatLength") or 0), field("SplatSha256")
    facts = {"formatVersion": fv, "splatFormat": fmt, "splatVersion": version,
             "splatGaussians": int(field("SplatGaussians") or 0), "splatShDegree": int(field("SplatShDegree") or 0),
             "splatLength": length, "splatSha256": sha, "splatName": field("SplatName")}
    if fv > 1 or fmt != "spz" or version > 4:
        return facts, "newer", None
    if not (32 <= length <= 2147483647):
        return facts, "missing", None
    if len(data) < length + 4:
        return facts, "lost", None
    tail = data[len(data) - length:]
    if not ((1 <= version <= 3 and tail[:2] == b"\x1f\x8b") or (version == 4 and tail[:4] == b"NGSP")):
        return facts, "notSpz", None
    if hashlib.sha256(tail).hexdigest() != sha:
        return facts, "wrongSum", None
    v, count, degree = spz_head(tail)
    return facts, "ok", {"version": v, "gaussians": count, "shDegree": degree}


def contract(files: dict) -> dict:
    out = {"about": "What the tests of the splat photos compare with, written by "
                    ".github/desktop/ai/make_splat_photo_fixtures.py", "formatVersion": 1, "fixtures": {}}
    for name in sorted(files):
        if name.startswith("poster"):
            continue
        data = files[name]
        facts, result, head = verdict(data)
        entry = {"bytes": len(data), "sha1": hashlib.sha1(data).hexdigest(), "verdict": result, "packet": facts}
        if head is not None:
            entry["head"] = head
            entry["headMatches"] = (head["version"] == facts["splatVersion"] and head["gaussians"] ==
                                    facts["splatGaussians"] and head["shDegree"] == facts["splatShDegree"])
        out["fixtures"][name] = entry
    out["writer"] = {
        "poster.jpg + axes_v2.spz": "ok_v2.jpg",
        "poster_motion.jpg + axes_v2.spz": "ok_v2.jpg",
        "poster_ultrahdr.jpg + axes_v2.spz": "ok_v2.jpg",
        "poster.jpg + axes_v4.spz": "ok_v4.jpg",
    }
    out["meta"] = {
        "ok_v2.jpg": {"name": "axes_v2.spz", "date": DATE_V2["iso"], "software": "Immuch360 fixtures",
                      "creatorTool": "Immuch360 fixtures (test)", "description": DESCRIPTION_V2, "poster": "card"},
        "ok_v4.jpg": {"name": "axes_v4.spz", "date": DATE_V4["iso"], "software": "Immuch360 fixtures",
                      "creatorTool": "Immuch360 fixtures (test)", "description": DESCRIPTION_V4, "poster": "render",
                      "up": "yUp", "latitude": PLACE_V4[0], "longitude": PLACE_V4[1]},
    }
    out["refused"] = {"poster_2to1.jpg": "posterShape", "poster_square.jpg": "posterShape"}
    return out


def exiftool_copy(ok_v2: bytes) -> bytes | None:
    tool = shutil.which("exiftool")
    if tool is None:
        return None
    path = pathlib.Path("/tmp/splat_photo_exiftool.jpg")
    path.write_bytes(ok_v2)
    subprocess.run([tool, "-q", "-overwrite_original", "-Title=Axes", "-Rating=4", str(path)], check=True)
    return path.read_bytes()


def write_one(spz_path, poster_path, out_path, name, iso):
    scene = pathlib.Path(spz_path).read_bytes()
    poster = pathlib.Path(poster_path).read_bytes()
    y, mo, d = int(iso[0:4]), int(iso[5:7]), int(iso[8:10])
    h, mi, s = int(iso[11:13]), int(iso[14:16]), int(iso[17:19])
    sign = -1 if iso[19] == "-" else 1
    offset = sign * (int(iso[20:22]) * 60 + int(iso[23:25]))
    date = date_of(y, mo, d, h, mi, s, offset)
    version, count, degree = spz_head(scene)
    description = f"Splat scene of {count:,} gaussians. Open it with Immuch360 to explore it."
    p = packet_for(scene, name, date, description, poster_kind="render")
    pathlib.Path(out_path).write_bytes(splat_photo(poster, scene, p, description, date))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixtures instead of writing them")
    parser.add_argument("--posters", action="store_true", help="encode the posters again with PIL")
    parser.add_argument("--write", nargs=3, metavar=("SPZ", "POSTER", "OUT"), help="write one splat photo")
    parser.add_argument("--name", help="SplatName of --write")
    parser.add_argument("--date", default="2026-11-04T10:00:00+01:00", help="the date of --write")
    args = parser.parse_args()
    if args.write:
        spz, poster, out = args.write
        write_one(spz, poster, out, args.name or pathlib.Path(spz).name, args.date)
        return 0
    if args.posters or not (FIXTURES / "poster.jpg").is_file():
        posters = make_posters()
    else:
        posters = {name: (FIXTURES / name).read_bytes() for name in ["poster.jpg", "poster_2to1.jpg",
                                                                     "poster_square.jpg"]}
        posters["_reencoded"] = (FIXTURES / "reencoded_plain.jpg").read_bytes()
    files, _ = fixtures(posters)
    for name in ["poster.jpg", "poster_2to1.jpg", "poster_square.jpg"]:
        files[name] = posters[name]
    if args.posters or not (FIXTURES / "ok_exiftool.jpg").is_file():
        edited = exiftool_copy(files["ok_v2.jpg"])
        if edited is None:
            print("exiftool not found: ok_exiftool.jpg not made", file=sys.stderr)
            return 1
        files["ok_exiftool.jpg"] = edited
    else:
        files["ok_exiftool.jpg"] = (FIXTURES / "ok_exiftool.jpg").read_bytes()
    if not args.posters and (FIXTURES / "png_with_packet.png").is_file():
        files["png_with_packet.png"] = (FIXTURES / "png_with_packet.png").read_bytes()
    text = json.dumps(contract(files), indent=1, ensure_ascii=False) + "\n"
    if args.check:
        bad = [name for name, data in files.items()
               if not (FIXTURES / name).is_file() or (FIXTURES / name).read_bytes() != data]
        contract_path = FIXTURES / "splat_photo_contract_v1.json"
        if not contract_path.is_file() or contract_path.read_text(encoding="utf-8") != text:
            bad.append("splat_photo_contract_v1.json")
        for name in bad:
            print(f"differs: {name}")
        return 1 if bad else 0
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (FIXTURES / name).write_bytes(data)
    (FIXTURES / "splat_photo_contract_v1.json").write_text(text, encoding="utf-8")
    total = sum(len(d) for d in files.values())
    print(f"{len(files)} fixtures ({total} bytes) and splat_photo_contract_v1.json in {FIXTURES.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
