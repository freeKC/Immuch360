#!/usr/bin/env python3
"""Make and check the AV2 test fixtures and the lighthouse test clip of Immuch360 (lot AD0, 2 November 2026).

Runs on the Linux build host where the AV2 tools of the measurement of 2 November 2026 are built
(ai1, ~/av2-2026-11-02, override with AV2_ROOT):

  avmenc  AVM branch av2-enc, commit ad715c88d5b1119780b3a82025696ab8e77f5c55 (encoder, 7.8x faster than v1.0.0)
  avmdec  AVM tag v1.0.0, commit 966a7d7cd6fcf60360caf5dc413b2aeeb65e144d (reference decoder)
  dav2d   VideoLAN dav2d, commit 30140b563596a1b14aef808ff021c90288948315 (the decoder the app ships)
  ffmpeg  only to cut and scale the source (Debian 13 package 7.1.5) and to make the AV1 negative sample

Source, CC0: "Orbit around Fremantle South Mole Lighthouse at sunset.webm" by JamesBromberger, Wikimedia Commons,
https://commons.wikimedia.org/wiki/File:Orbit_around_Fremantle_South_Mole_Lighthouse_at_sunset.webm
(VP9 1920x1080 at 30000/1001, 111 s), SHA-256 6a245417eb6bb7077f77178ae8697ba1ae6a8f82bdc19136e526ac40130e812d.
Frames 750 to 1049 of the source (25.0 s to 35.0 s) are used, retimed to exactly 30 frames per second.

Usage:
  make_av2_fixtures.py sources        cut the y4m sources from the webm (12 frames 256x144 8 and 10 bit, 300 frames 1080p)
  make_av2_fixtures.py fixtures       encode, derive, check with both decoders, write fixtures.json
  make_av2_fixtures.py clip-encode    encode the 10 s 1080p30 8-bit clip (about 30 to 40 min on ai1, 6 threads)
  make_av2_fixtures.py clip-check     derive the clip's .obu, check it with both decoders, write clip.json
  make_av2_fixtures.py doc DIR        write DIR/FIXTURES.md from DIR/fixtures.json (any machine)
  make_av2_fixtures.py verify DIR     decode the fixtures of DIR again and compare with DIR/fixtures.json
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("AV2_ROOT", "~/av2-2026-11-02")).expanduser()
WORK = ROOT / "fixtures"
SRC = WORK / "src"
OUT = WORK / "out"
TMP = WORK / "tmp"
CLIP = ROOT / "clips-ad0"
FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
TOOLS = {
    "avmenc": (ROOT / "build/avm-av2enc/avmenc", ROOT / "src/avm-av2-enc", "ad715c88d5b1119780b3a82025696ab8e77f5c55"),
    "avmdec": (ROOT / "build/avm-dec/avmdec", ROOT / "src/avm-v1.0.0", "966a7d7cd6fcf60360caf5dc413b2aeeb65e144d"),
    "dav2d": (ROOT / "build/dav2d/tools/dav2d", ROOT / "src/dav2d", "30140b563596a1b14aef808ff021c90288948315"),
}
SOURCE = SRC / "lighthouse.webm"
SOURCE_SHA256 = "6a245417eb6bb7077f77178ae8697ba1ae6a8f82bdc19136e526ac40130e812d"
FIRST = 750  # first source frame used (25.03 s)
FIX_FRAMES, CLIP_FRAMES = 12, 300
FIX_W, FIX_H = 256, 144
OBU_NAMES = {
    1: "SEQUENCE_HEADER", 2: "TEMPORAL_DELIMITER", 3: "MULTI_FRAME_HEADER", 4: "CLOSED_LOOP_KEY", 5: "OPEN_LOOP_KEY",
    6: "LEADING_TILE_GROUP", 7: "REGULAR_TILE_GROUP", 8: "METADATA_SHORT", 9: "METADATA_GROUP", 10: "SWITCH",
    11: "LEADING_SEF", 12: "REGULAR_SEF", 13: "LEADING_TIP", 14: "REGULAR_TIP", 15: "BUFFER_REMOVAL_TIMING",
    16: "LAYER_CONFIGURATION_RECORD", 17: "ATLAS_SEGMENT", 18: "OPERATING_POINT_SET", 19: "BRIDGE_FRAME",
    20: "MULTI_STREAM_DECODER_OPERATION", 21: "RAS_FRAME", 22: "QUANTIZATION_MATRIX", 23: "FILM_GRAIN_MODEL",
    24: "CONTENT_INTERPRETATION", 25: "PADDING",
}  # avm/avm_codec.h of AVM v1.0.0
KEY_OBUS = {4, 5, 21}
COMMANDS = []  # every external command, in order, written next to the outputs


def rel(p):
    """[p] as the outputs write it: under ROOT, relative to it; ffmpeg by its name, never the path of this computer"""
    s = str(p)
    if s == FFMPEG:
        return "ffmpeg"
    return s.replace(str(ROOT) + "/", "") if s.startswith(str(ROOT) + "/") else s


def run(cmd, check=True, stdout=None, log=True):
    cmd = [str(c) for c in cmd]
    if log:
        COMMANDS.append(shlex.join(rel(c) for c in cmd))
    r = subprocess.run(cmd, cwd=ROOT, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE)
    if check and r.returncode != 0:
        sys.exit(f"failed ({r.returncode}): {shlex.join(cmd)}\n{r.stderr.decode(errors='replace')[-2000:]}")
    return r


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def md5(b):
    return hashlib.md5(b).hexdigest()


def tool_versions():
    info = {}
    for name, (binary, src, commit) in TOOLS.items():
        head = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        desc = subprocess.run(["git", "-C", src, "describe", "--tags", "--always"], capture_output=True,
                              text=True).stdout.strip()
        if head != commit:
            sys.exit(f"{name}: source at {head}, expected {commit}")
        info[name] = {"binary": rel(binary), "commit": head, "describe": desc, "binary_sha256": sha256(binary)}
    v = subprocess.run([FFMPEG, "-hide_banner", "-version"], capture_output=True, text=True).stdout.splitlines()[0]
    info["ffmpeg"] = {"binary": rel(FFMPEG), "version": v}
    return info


# ---------------------------------------------------------------- container parsing (no decoding)


def leb128(buf, pos, end):
    val = 0
    for i in range(8):
        if pos + i >= end:
            raise EOFError
        b = buf[pos + i]
        val |= (b & 0x7F) << (7 * i)
        if not b & 0x80:
            return val, i + 1
    raise ValueError(f"LEB128 longer than 8 bytes at {pos}")


def obus(buf, pos, end):
    """OBUs of buf[pos:end]: (offset, length, type, complete). The size field counts the header byte(s)."""
    out = []
    while pos < end:
        try:
            size, n = leb128(buf, pos, end)
        except EOFError:
            out.append((pos, end - pos, None, False))
            break
        if pos + n >= end:
            out.append((pos, end - pos, None, False))
            break
        t = (buf[pos + n] >> 2) & 0x1F
        out.append((pos, min(n + size, end - pos), t, pos + n + size <= end))
        pos += n + size
    return out


def ivf_header(data):
    sig, ver, hlen, fourcc, w, h, rate, scale, nframes, _ = struct.unpack("<4sHH4sHHIII4s", data[:32])
    return {"signature": sig.decode("latin-1"), "version": ver, "header_len": hlen, "fourcc": fourcc.decode("latin-1"),
            "width": w, "height": h, "rate": rate, "scale": scale, "frames_in_header": nframes}


def index(path):
    """Packets (IVF) and temporal units of an AV2 .ivf or .obu (Section 5) file, from OBU headers only."""
    data = Path(path).read_bytes()
    spans, info = [], {}
    if data[:4] == b"DKIF":
        info = ivf_header(data)
        pos, packets = info["header_len"], []
        while pos + 12 <= len(data):
            size, pts = struct.unpack("<IQ", data[pos:pos + 12])
            end = min(pos + 12 + size, len(data))
            packets.append({"offset": pos, "size": size, "pts": pts, "complete": pos + 12 + size <= len(data)})
            spans.append((len(packets) - 1, pos + 12, end, pos + 12 + size <= len(data)))
            pos += 12 + size
        info["packets"] = packets
        info["trailing_bytes"] = len(data) - pos if pos < len(data) else 0
    else:
        spans.append((None, 0, len(data), True))
    units = []
    for pkt, start, end, pkt_complete in spans:
        for off, length, t, complete in obus(data, start, end):
            if t == 2 or not units or units[-1]["packet"] != pkt:
                if t != 2 and units and units[-1]["packet"] != pkt:
                    sys.exit(f"{path}: packet {pkt} does not start with a temporal delimiter")
                units.append({"offset": off, "size": 0, "packet": pkt, "obu_types": [], "complete": True})
            u = units[-1]
            u["size"] = off + length - u["offset"]
            u["obu_types"].append(t)
            u["complete"] = u["complete"] and complete and (pkt_complete or off + length < end)
    for i, u in enumerate(units):
        u["index"] = i
        u["access_point"] = any(t in KEY_OBUS for t in u["obu_types"] if t is not None)
        if u["complete"] and not pkt_complete_unit(u, units, spans):
            u["complete"] = False
    info["units"] = units
    info["whole_units"] = sum(1 for u in units if u["complete"])
    info["access_points"] = [u["index"] for u in units if u["access_point"] and u["complete"]]
    return info


def pkt_complete_unit(u, units, spans):
    # A unit inside a cut packet is whole only when a later unit of the same packet starts after it.
    if u["packet"] is None:
        return all(t is not None for t in u["obu_types"])
    span = spans[u["packet"]]
    if span[3]:
        return True
    later = [v for v in units if v["packet"] == u["packet"] and v["offset"] > u["offset"]]
    return bool(later)


# ---------------------------------------------------------------- decoding


def frame_bytes(w, h, bits):
    return w * h * 3 // 2 * (2 if bits > 8 else 1)


def split_md5(raw, fsize):
    data = Path(raw).read_bytes()
    return [md5(data[i:i + fsize]) for i in range(0, len(data) - len(data) % fsize, fsize)], len(data) % fsize, md5(data)


def decode(tool, path, raw, fsize, threads=2, cpumask=None, extra=(), log=True):
    """Decode to raw planar frames (16-bit little endian above 8 bit); return per-frame MD5 and the exit status."""
    Path(raw).unlink(missing_ok=True)
    if tool == "avmdec":
        cmd = [TOOLS["avmdec"][0], "--rawvideo", "-t", threads, *extra, "-o", raw, path]
    else:
        cmd = [TOOLS["dav2d"][0], "-q", "-i", path, "--muxer", "yuv", "-o", raw, "--threads", threads, *extra]
        if cpumask is not None:
            cmd += ["--cpumask", cpumask]
    r = run(cmd, check=False, log=log)
    frames, rest, whole = split_md5(raw, fsize) if Path(raw).exists() else ([], 0, None)
    Path(raw).unlink(missing_ok=True)
    return {"exit": r.returncode, "frames": frames, "rest_bytes": rest, "md5_all": whole,
            "stderr": r.stderr.decode(errors="replace").strip().splitlines()[-3:]}


def tool_md5(tool, path):
    if tool == "avmdec":
        r = run([TOOLS["avmdec"][0], "--rawvideo", "--md5", "-t", 2, path], check=False)
    else:
        r = run([TOOLS["dav2d"][0], "-q", "-i", path, "--muxer", "md5", "-o", "-", "--threads", 2], check=False)
    out = r.stdout.decode().split()
    return out[0] if r.returncode == 0 and out else None


def y4m_header(path):
    with open(path, "rb") as f:
        return f.readline().decode().strip()


# ---------------------------------------------------------------- sources


def cmd_sources(_):
    for d in (SRC, OUT, TMP, CLIP):
        d.mkdir(parents=True, exist_ok=True)
    if sha256(SOURCE) != SOURCE_SHA256:
        sys.exit("source SHA-256 differs")
    sel = f"select='between(n\\,{FIRST}\\,{{last}})',setpts=N/30/TB"
    jobs = [
        (SRC / "lighthouse-256x144-8bit-12f.y4m", FIX_FRAMES,
         f"scale={FIX_W}:{FIX_H}:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p"),
        (SRC / "lighthouse-256x144-10bit-12f.y4m", FIX_FRAMES,
         f"scale={FIX_W}:{FIX_H}:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p10le"),
        (SRC / "lighthouse-1080p30-8bit-300f.y4m", CLIP_FRAMES, "format=yuv420p"),
    ]
    for out, n, chain in jobs:
        vf = sel.format(last=FIRST + n - 1) + "," + chain
        run([FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", SOURCE, "-an", "-sn", "-map", "0:v:0",
             "-vf", vf, "-r", "30", "-frames:v", n, "-strict", "-1", "-f", "yuv4mpegpipe", out])
        print(out.name, y4m_header(out), out.stat().st_size)
    ten = (SRC / "lighthouse-256x144-10bit-12f.y4m").read_bytes()
    body = ten[ten.index(b"FRAME\n") + 6:][:FIX_W * FIX_H * 2]
    samples = struct.unpack(f"<{FIX_W * FIX_H}H", body)
    print("10-bit luma samples of frame 0 that are not a multiple of 4:",
          sum(1 for s in samples if s % 4), "of", len(samples))
    (SRC / "commands-sources.txt").write_text("\n".join(COMMANDS) + "\n")


# ---------------------------------------------------------------- fixtures


ENC_FIX = ["--cpu-used=6", "--end-usage=q", "--qp=160", "--kf-min-dist=6", "--kf-max-dist=6", "--threads=1",
           "--test-decode=fatal", "--psnr", f"--limit={FIX_FRAMES}"]


def encoder_summary(log):
    """Bitrate (kbit/s) and overall PSNR (dB) from the 'Summary:' line of avmenc --psnr."""
    m = re.findall(r"Summary:\s+([0-9.]+)\s*\|\s*[0-9.]+\s*\|\s*[0-9.]+\s*\|\s*[0-9.]+\s*\|\s*[0-9.]+\s*\|\s*([0-9.]+)",
                   log.replace("\r", "\n"))
    return {"kbps": float(m[-1][0]), "psnr_overall_db": float(m[-1][1])} if m else None


def encode_fixture(bits, out, fmt):
    src = SRC / f"lighthouse-256x144-{bits}bit-12f.y4m"
    r = run([TOOLS["avmenc"][0], *ENC_FIX, f"--bit-depth={bits}", f"--input-bit-depth={bits}", f"--{fmt}", "-o", out,
             src])
    return encoder_summary(r.stdout.decode(errors="replace") + r.stderr.decode(errors="replace"))


def check_full(path, bits, frames_expected, unit_index):
    fsize = frame_bytes(FIX_W, FIX_H, bits)
    raw = TMP / "dec.yuv"
    res = {"avmdec": decode("avmdec", path, raw, fsize)}
    for mask in (None, "avx2", "0"):
        res["dav2d" + ("" if mask is None else f"_cpumask_{mask}")] = decode("dav2d", path, raw, fsize, cpumask=mask)
    ref = res["avmdec"]["frames"]
    ok = len(ref) == frames_expected and all(
        v["exit"] == 0 and v["frames"] == ref and v["rest_bytes"] == 0 for v in res.values())
    tm = {t: tool_md5(t, path) for t in ("avmdec", "dav2d")}
    ok = ok and tm["avmdec"] == tm["dav2d"] == res["avmdec"]["md5_all"]
    return ok, ref, res, tm


def obu_slice(path, start_offset, out):
    data = Path(path).read_bytes()
    Path(out).write_bytes(data[start_offset:])


def cmd_fixtures(_):
    tools = tool_versions()
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    manifest = {"made": time.strftime("%Y-%m-%d %H:%M:%S %Z"), "tools": tools, "source": {
        "file": "Orbit_around_Fremantle_South_Mole_Lighthouse_at_sunset.webm", "author": "JamesBromberger",
        "licence": "CC0 1.0", "sha256": SOURCE_SHA256, "frames_used": [FIRST, FIRST + CLIP_FRAMES - 1],
        "url": "https://commons.wikimedia.org/wiki/File:Orbit_around_Fremantle_South_Mole_Lighthouse_at_sunset.webm"},
        "files": {}}
    for bits in (8, 10):
        ivf, obu = OUT / f"av2-256x144-{bits}bit.ivf", OUT / f"av2-256x144-{bits}bit.obu"
        psnr = encode_fixture(bits, ivf, "ivf")
        encode_fixture(bits, obu, "obu")
        again = TMP / f"again-{bits}.ivf"
        encode_fixture(bits, again, "ivf")
        reproducible = sha256(again) == sha256(ivf)
        again.unlink()
        ix = index(ivf)
        data = ivf.read_bytes()
        concat = b"".join(data[p["offset"] + 12:p["offset"] + 12 + p["size"]] for p in ix["packets"])
        obu_equal = concat == obu.read_bytes()
        ok, ref, res, tm = check_full(ivf, bits, FIX_FRAMES, ix)
        ok_obu, ref_obu, res_obu, tm_obu = check_full(obu, bits, FIX_FRAMES, index(obu))
        # Random access: decode from the second access point only, the frames must equal the tail of the full decode.
        ixo = index(obu)
        ap = ixo["access_points"]
        ra = {}
        if len(ap) > 1:
            part = TMP / f"from-ap{ap[1]}.obu"
            obu_slice(obu, ixo["units"][ap[1]]["offset"], part)
            fsize = frame_bytes(FIX_W, FIX_H, bits)
            for t in ("avmdec", "dav2d"):
                d = decode(t, part, TMP / "dec.yuv", fsize)
                ra[t] = {"exit": d["exit"], "frames": len(d["frames"]),
                         "equal_to_full_decode_tail": d["frames"] == ref[ap[1]:]}
            part.unlink()
        for f, x in ((ivf, ix), (obu, ixo)):
            manifest["files"][f.name] = {
                "kind": "av2", "bits": bits, "width": FIX_W, "height": FIX_H, "fps": "30/1", "frames": FIX_FRAMES,
                "bytes": f.stat().st_size, "sha256": sha256(f), "container": "ivf" if f.suffix == ".ivf" else "obu",
                "index": slim(x), "frame_md5": ref if f == ivf else ref_obu,
                "md5_all_frames": {"avmdec --md5": (tm if f == ivf else tm_obu)["avmdec"],
                                   "dav2d --muxer md5": (tm if f == ivf else tm_obu)["dav2d"]},
                "decoders_equal": ok if f == ivf else ok_obu,
                "decoders": summarize(res if f == ivf else res_obu),
            }
        uf = unit_frames(obu, bits, ref)
        for f in (ivf, obu):
            manifest["files"][f.name]["coding_order"] = uf
        manifest["files"][ivf.name].update({"encoder_summary": psnr, "encode_reproducible": reproducible})
        manifest["files"][obu.name].update({"equal_to_ivf_payloads": obu_equal, "frame_md5_equal_to_ivf": ref == ref_obu,
                                            "random_access_from_second_access_point": ra})
        print(bits, "bit:", ivf.stat().st_size, obu.stat().st_size, "decoders equal", ok, ok_obu, "obu=ivf payloads",
              obu_equal, "reproducible", reproducible, "units", ix["whole_units"], "aps", ix["access_points"], ra,
              "unit codes frame", uf["unit_codes_frame"], uf["decoders_agree"])
    make_cut(manifest)
    make_damaged(manifest)
    damage_survey(manifest)
    make_av1(manifest)
    manifest["total_bytes"] = sum(v["bytes"] for v in manifest["files"].values())
    manifest["commands"] = COMMANDS
    shutil.copy(SRC / "commands-sources.txt", OUT / "commands-sources.txt")
    (OUT / "fixtures.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print("total bytes", manifest["total_bytes"])


def slim(ix):
    keep = {k: v for k, v in ix.items() if k not in ("units",)}
    keep["units"] = [{"index": u["index"], "offset": u["offset"], "size": u["size"], "packet": u["packet"],
                      "obu_types": u["obu_types"], "access_point": u["access_point"], "complete": u["complete"]}
                     for u in ix["units"]]
    return keep


def summarize(res):
    return {k: {"exit": v["exit"], "frames": len(v["frames"]), "rest_bytes": v["rest_bytes"], "md5_all": v["md5_all"]}
            for k, v in res.items()}


def make_cut(manifest):
    """The 8-bit .ivf cut in the middle of a temporal unit that shares its IVF packet with earlier whole units."""
    src = OUT / "av2-256x144-8bit.ivf"
    ix = index(src)
    data = src.read_bytes()
    full = manifest["files"][src.name]["frame_md5"]
    # The first packet after the second access point that holds several units; cut inside its second unit.
    cands = [p for p in range(len(ix["packets"]))
             if len([u for u in ix["units"] if u["packet"] == p]) >= 2
             and ix["units"][[u["packet"] for u in ix["units"]].index(p)]["index"] >= 6]
    if not cands:
        cands = [p for p in range(len(ix["packets"])) if len([u for u in ix["units"] if u["packet"] == p]) >= 2]
    pkt = cands[0]
    units = [u for u in ix["units"] if u["packet"] == pkt]
    victim = units[1]
    obu_list = obus(data, victim["offset"], victim["offset"] + victim["size"])
    last = obu_list[-1]
    cut_at = last[0] + last[1] // 2  # in the middle of the unit's last OBU (its tile data)
    out = OUT / "av2-256x144-8bit-cut.ivf"
    out.write_bytes(data[:cut_at])
    cix = index(out)
    fsize = frame_bytes(FIX_W, FIX_H, 8)
    dec = {t: decode(t, out, TMP / "dec.yuv", fsize) for t in ("avmdec", "dav2d")}
    # The whole units as a Section 5 stream: what the companion is fed.
    whole = TMP / "cut-whole-units.obu"
    whole.write_bytes(b"".join(data[u["offset"]:u["offset"] + u["size"]] for u in cix["units"] if u["complete"]))
    dec_whole = {t: decode(t, whole, TMP / "dec.yuv", fsize) for t in ("avmdec", "dav2d")}
    whole.unlink()
    n = cix["whole_units"]
    coding = manifest["files"][src.name]["coding_order"]["unit_codes_frame"]
    carried = sorted(coding[:n])
    playable = next((i for i, f in enumerate(carried) if f != i), len(carried))
    manifest["files"][out.name] = {
        "kind": "av2-cut", "bits": 8, "width": FIX_W, "height": FIX_H, "fps": "30/1", "bytes": out.stat().st_size,
        "sha256": sha256(out), "container": "ivf", "cut_from": src.name, "cut_at_byte": cut_at,
        "cut_in_unit": victim["index"], "cut_in_packet": pkt, "index": slim(cix), "whole_units": n,
        "frames_carried_by_whole_units": carried, "contiguous_frames_from_start": playable,
        "decoders_on_cut_file": {t: {"exit": d["exit"], "frames": len(d["frames"]),
                                     "display_indices": labels(d["frames"], full), "stderr_tail": d["stderr"]}
                                 for t, d in dec.items()},
        "decoders_on_whole_units_as_obu": {t: {"exit": d["exit"], "frames": len(d["frames"]),
                                               "display_indices": labels(d["frames"], full),
                                               "frame_md5": d["frames"]} for t, d in dec_whole.items()},
    }
    print("cut:", out.stat().st_size, "at", cut_at, "unit", victim["index"], "packet", pkt, "whole units", n,
          {t: (d["exit"], labels(d["frames"], full)) for t, d in dec.items()},
          {t: (d["exit"], labels(d["frames"], full)) for t, d in dec_whole.items()})


DAMAGE_UNIT = 1  # the first inter frame: it codes frame 5, which frames 1 to 4 reference


def labels(frames, full):
    """Display index of each decoded frame in the full decode, or -1 for a frame the full decode never gives."""
    where = {h: i for i, h in enumerate(full)}
    return [where.get(h, -1) for h in frames]


def damage(data, edits):
    d = bytearray(data)
    for off, val in edits:
        d[off] = val
    return bytes(d)


def payload_start(data, o):
    return o[0] + leb128(data, o[0], o[0] + o[1])[1] + 1


def first_obu(data, unit, types):
    return [o for o in obus(data, unit["offset"], unit["offset"] + unit["size"]) if o[2] in types][0]


def make_damaged(manifest):
    """The 8-bit .ivf with 16 bytes set to 0xFF inside the tile data of unit 1; the container stays valid."""
    src = OUT / "av2-256x144-8bit.ivf"
    ix = index(src)
    data = src.read_bytes()
    full = manifest["files"][src.name]["frame_md5"]
    tile = first_obu(data, ix["units"][DAMAGE_UNIT], (6, 7))
    start = payload_start(data, tile) + 2
    edits = [(start + i, 0xFF) for i in range(16)]
    out = OUT / "av2-256x144-8bit-damaged.ivf"
    out.write_bytes(damage(data, edits))
    fsize = frame_bytes(FIX_W, FIX_H, 8)
    dec = {t: decode(t, out, TMP / "dec.yuv", fsize) for t in ("avmdec", "dav2d")}
    dix = index(out)
    manifest["files"][out.name] = {
        "kind": "av2-damaged", "bits": 8, "width": FIX_W, "height": FIX_H, "fps": "30/1", "bytes": out.stat().st_size,
        "sha256": sha256(out), "container": "ivf", "damaged_from": src.name, "damaged_unit": DAMAGE_UNIT,
        "damaged_bytes": {"offset": start, "length": 16, "value": "0xFF", "obu_type": tile[2],
                          "where": "payload bytes 2 to 17 of the unit's REGULAR_TILE_GROUP OBU"},
        "index": slim(dix), "whole_units": dix["whole_units"],
        "decoders": {t: {"exit": d["exit"], "frames": len(d["frames"]), "display_indices": labels(d["frames"], full),
                         "stderr_tail": d["stderr"]} for t, d in dec.items()},
    }
    print("damaged:", start, {t: (d["exit"], labels(d["frames"], full), d["stderr"][-1:]) for t, d in dec.items()})


def damage_survey(manifest):
    """Other damage patterns tried on the 8-bit .ivf (not kept as files): how each decoder behaves."""
    src = OUT / "av2-256x144-8bit.ivf"
    ix = index(src)
    data = src.read_bytes()
    full = manifest["files"][src.name]["frame_md5"]
    u = ix["units"]
    t1 = first_obu(data, u[1], (7,))
    k6 = first_obu(data, u[6], (4,))
    t7 = first_obu(data, u[7], (7,))
    sq = first_obu(data, u[0], (1,))
    variants = {
        "unit 1 tile payload bytes 2-17 set to 0xFF (the kept damaged fixture)":
            [(payload_start(data, t1) + 2 + i, 0xFF) for i in range(16)],
        "unit 1 tile OBU last 8 bytes set to 0x00": [(t1[0] + t1[1] - 8 + i, 0x00) for i in range(8)],
        "unit 1 tile payload all set to 0x00": [(i, 0x00) for i in range(payload_start(data, t1), t1[0] + t1[1])],
        "unit 6 key OBU, 16 bytes in the middle set to 0xFF":
            [(payload_start(data, k6) + k6[1] // 2 + i, 0xFF) for i in range(16)],
        "unit 6 key OBU, first 8 payload bytes set to 0xFF": [(payload_start(data, k6) + i, 0xFF) for i in range(8)],
        "unit 7 tile payload bytes 2-17 set to 0xFF": [(payload_start(data, t7) + 2 + i, 0xFF) for i in range(16)],
        "unit 0 sequence header payload all set to 0xFF":
            [(i, 0xFF) for i in range(payload_start(data, sq), sq[0] + sq[1])],
    }
    fsize = frame_bytes(FIX_W, FIX_H, 8)
    survey = []
    for name, edits in variants.items():
        p = TMP / "survey.ivf"
        p.write_bytes(damage(data, edits))
        row = {"damage": name, "first_byte": edits[0][0], "bytes": len(edits)}
        for t in ("dav2d", "avmdec"):
            d = decode(t, p, TMP / "dec.yuv", fsize)
            row[t] = {"exit": d["exit"], "display_indices": labels(d["frames"], full),
                      "last_message": d["stderr"][-1] if d["stderr"] else ""}
        p.unlink()
        survey.append(row)
        print("survey:", row)
    manifest["damage_survey"] = survey


def unit_frames(path, bits, full):
    """Which frame (display index) each temporal unit codes: decode the first k units for every k (decoders flush
    their reordering buffer at the end), the new frame is the one unit k-1 codes. Both decoders must agree."""
    ix = index(path)
    data = Path(path).read_bytes()
    fsize = frame_bytes(FIX_W, FIX_H, bits)
    codes, prev = {}, {"avmdec": [], "dav2d": []}
    outputs = []
    for k, u in enumerate(ix["units"], 1):
        p = TMP / "prefix.obu"
        p.write_bytes(data[:u["offset"] + u["size"]])
        got = {}
        for t in ("avmdec", "dav2d"):
            d = decode(t, p, TMP / "dec.yuv", fsize, log=False)
            got[t] = labels(d["frames"], full)
            new = sorted(set(got[t]) - set(prev[t]))
            codes.setdefault(t, []).append(new[0] if len(new) == 1 else None)
            prev[t] = got[t]
        outputs.append(got["dav2d"] if got["dav2d"] == got["avmdec"] else got)
        p.unlink()
    return {"unit_codes_frame": codes["dav2d"], "decoders_agree": codes["dav2d"] == codes["avmdec"],
            "frames_out_after_first_k_units": outputs}


def make_av1(manifest):
    """A short AV1 stream in IVF (fourcc AV01): the app must refuse it as AV2."""
    out = OUT / "av1-256x144-8bit.ivf"
    run([FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", SRC / "lighthouse-256x144-8bit-12f.y4m",
         "-frames:v", "2", "-c:v", "libaom-av1", "-cpu-used", "8", "-crf", "50", "-g", "2", "-threads", "1",
         "-f", "ivf", out])
    manifest["files"][out.name] = {"kind": "av1-negative", "bits": 8, "width": FIX_W, "height": FIX_H, "frames": 2,
                                   "bytes": out.stat().st_size, "sha256": sha256(out), "container": "ivf",
                                   "ivf_header": ivf_header(out.read_bytes())}


# ---------------------------------------------------------------- clip


CLIP_NAME = "fremantle-lighthouse-1080p30-av2"
ENC_CLIP = ["--cpu-used=6", "--end-usage=q", "--qp=160", "--kf-max-dist=60", "--tile-columns=1", "--bit-depth=8",
            "--input-bit-depth=8", "--threads=6", "--row-mt=1", "--test-decode=fatal", "--psnr", "--ivf",
            f"--limit={CLIP_FRAMES}"]


def cmd_clip_encode(_):
    CLIP.mkdir(parents=True, exist_ok=True)
    out = CLIP / f"{CLIP_NAME}.ivf"
    cmd = ["nice", "-n", "10", "/usr/bin/time", "-v", TOOLS["avmenc"][0], *ENC_CLIP, "-o", out,
           SRC / "lighthouse-1080p30-8bit-300f.y4m"]
    (CLIP / "command-encode.txt").write_text(shlex.join(rel(str(c)) for c in cmd) + "\n")
    t0 = time.time()
    with open(CLIP / "encode.log", "wb") as log:
        r = subprocess.run([str(c) for c in cmd], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    (CLIP / "encode-result.txt").write_text(f"exit={r.returncode} seconds={time.time() - t0:.1f}\n")


def cmd_clip_check(_):
    tools = tool_versions()
    ivf, obu = CLIP / f"{CLIP_NAME}.ivf", CLIP / f"{CLIP_NAME}.obu"
    ix = index(ivf)
    data = ivf.read_bytes()
    obu.write_bytes(b"".join(data[p["offset"] + 12:p["offset"] + 12 + p["size"]] for p in ix["packets"]))
    fsize = frame_bytes(1920, 1080, 8)
    res = {}
    for f in (ivf, obu):
        for t in ("avmdec", "dav2d"):
            res[f"{f.suffix[1:]}-{t}"] = decode(t, f, CLIP / "dec.yuv", fsize, threads=6)
    ref = res["ivf-avmdec"]["frames"]
    ok = len(ref) == CLIP_FRAMES and all(v["exit"] == 0 and v["frames"] == ref and v["rest_bytes"] == 0
                                         for v in res.values())
    tm = {t: tool_md5(t, ivf) for t in ("avmdec", "dav2d")}
    dec = CLIP / "dav2d.yuv"
    run([TOOLS["dav2d"][0], "-q", "-i", ivf, "--muxer", "yuv", "-o", dec, "--threads", 6])
    r = run([FFMPEG, "-hide_banner", "-nostats", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "1920x1080", "-r", "30",
             "-i", dec, "-i", SRC / "lighthouse-1080p30-8bit-300f.y4m", "-lavfi",
             "[0:v]setpts=N[a];[1:v]setpts=N[b];[a][b]psnr", "-f", "null", "-"], check=False)
    dec.unlink(missing_ok=True)
    psnr = re.findall(r"PSNR y:.*", r.stderr.decode(errors="replace"))
    log = (CLIP / "encode.log").read_text(errors="replace").replace("\r", "\n")
    enc_summary = encoder_summary(log)
    clip = {"made": time.strftime("%Y-%m-%d %H:%M:%S %Z"), "tools": tools,
            "encode_command": (CLIP / "command-encode.txt").read_text().strip(),
            "encode_result": (CLIP / "encode-result.txt").read_text().strip(),
            "files": {f.name: {"bytes": f.stat().st_size, "sha256": sha256(f)} for f in (ivf, obu)},
            "ivf_header": {k: v for k, v in ix.items() if k not in ("packets", "units")},
            "packets": len(ix["packets"]), "units": len(ix["units"]), "whole_units": ix["whole_units"],
            "access_points": ix["access_points"], "frames_decoded": {k: len(v["frames"]) for k, v in res.items()},
            "decoders_equal": ok, "md5_all_frames": {"avmdec --md5": tm["avmdec"], "dav2d --muxer md5": tm["dav2d"]},
            "frame_md5": ref, "psnr_against_source": psnr[-1] if psnr else None,
            "encoder_summary": enc_summary, "commands": COMMANDS}
    (CLIP / "clip.json").write_text(json.dumps(clip, indent=1) + "\n")
    print(json.dumps({k: v for k, v in clip.items() if k not in ("frame_md5", "commands", "tools")}, indent=1))


# ---------------------------------------------------------------- FIXTURES.md


INTRO = """# AV2 test fixtures (lot AD0, 2 November 2026)

Small AV2 streams for the tests of the AV2 playback of Immuch360 Desktop: the container reader and index (`av2_stream.dart`,
lot AD1) and the checks of the `immuch360-av2` companion and its CI (lot AD2). Made on ai1 by `make_av2_fixtures.py`
(next to this file), {made}. {total} bytes in all.

**Source**: "Orbit around Fremantle South Mole Lighthouse at sunset.webm" by JamesBromberger, Wikimedia Commons,
CC0 1.0 (<{url}>), VP9 1920x1080 at 30000/1001, SHA-256 `{sha}`. Frames {first} to {last_fix} (from 25.0 s), scaled
to 256x144 by ffmpeg (lanczos), retimed to exactly 30 frames per second. The fixtures are derived from a CC0 work and
carry no restriction: they can be committed to the repository.

**Tools** (sources and builds of the measurement of 2 November, `~/av2-2026-11-02/` on ai1):

| Tool | Role | Commit | Binary SHA-256 |
|---|---|---|---|
{tools}

**Encoder settings**: `{enc}` plus `--bit-depth` and `--input-bit-depth` (8 or 10) and `--ivf` or `--obu`. One
thread, so the encode is reproducible: a second encode gave the same bytes (8 and 10 bit).
"""

NOTES = """## What the tests should know

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
   exactly the payload after `FRAME\\n` of a y4m frame. `avmdec` v1.0.0 and dav2d give the same list on every complete
   file, dav2d on its three code paths of ai1 (AVX-512, `--cpumask avx2` and `--cpumask 0`, plain C). The whole-stream
   MD5 (`avmdec --rawvideo --md5`, `dav2d --muxer md5`) is the MD5 of all frames end to end.
6. **The y4m header must come from us**: rate 30/1 is in the IVF header (rate 30, scale 1); dav2d writes another frame
   rate in its own y4m output for streams whose packets carry several frames (measurement, section 5).
"""


def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def cmd_doc(args):
    d = Path(args.dir)
    m = json.loads((d / "fixtures.json").read_text())
    f = m["files"]
    roles = {"avmenc": "encoder (AVM branch `av2-enc`)", "avmdec": "reference decoder (AVM tag `v1.0.0`)",
             "dav2d": "decoder of the app (VideoLAN)"}
    tools = "\n".join(f"| `{k}` | {roles[k]} | `{v['commit']}` (`{v['describe']}`) | `{v['binary_sha256']}` |"
                      for k, v in m["tools"].items() if k in roles)
    tools += f"\n| ffmpeg | source cut and scale, AV1 sample | {m['tools']['ffmpeg']['version'].split(' Copyright')[0]} | |"
    out = [INTRO.format(made=m["made"], total=f"{m['total_bytes']:,}", url=m["source"]["url"], sha=m["source"]["sha256"],
                        first=m["source"]["frames_used"][0], last_fix=m["source"]["frames_used"][0] + FIX_FRAMES - 1,
                        tools=tools, enc=" ".join(ENC_FIX))]
    what = {
        "av2-256x144-8bit.ivf": "AV2 8 bit, IVF (`DKIF`, `AV02`)",
        "av2-256x144-8bit.obu": "AV2 8 bit, Section 5 OBU stream",
        "av2-256x144-10bit.ivf": "AV2 10 bit, IVF",
        "av2-256x144-10bit.obu": "AV2 10 bit, Section 5 OBU stream",
        "av2-256x144-8bit-cut.ivf": "the 8-bit IVF cut in the middle of temporal unit 8",
        "av2-256x144-8bit-damaged.ivf": "the 8-bit IVF with 16 bytes overwritten in the tile data of unit 1",
        "av1-256x144-8bit.ivf": "AV1 in IVF (`AV01`), 2 frames: must be refused as AV2",
    }
    rows = []
    for n, v in f.items():
        frames = v.get("frames", "")
        if v["kind"] == "av2-cut":
            frames = f"{v['contiguous_frames_from_start']} playable ({v['whole_units']} whole units)"
        if v["kind"] == "av2-damaged":
            frames = f"{v['whole_units']} units, dav2d gives {v['decoders']['dav2d']['frames']}"
        rows.append([f"`{n}`", what[n], f"{v['bytes']:,}", f"`{v['sha256']}`", frames])
    out.append("## Files\n\n" + md_table(["File", "What", "Bytes", "SHA-256", "Frames"], rows))
    out.append("All AV2 files: 256x144, 4:2:0, 30 frames per second (IVF rate 30, scale 1), 12 frames, key frames at "
               "0 and 6, IVF header frame count 12 (kept as is in the cut file).")
    out.append(NOTES)
    full8 = f["av2-256x144-8bit.ivf"]
    full10 = f["av2-256x144-10bit.ivf"]
    for name in ("av2-256x144-8bit.ivf", "av2-256x144-10bit.ivf"):
        v = f[name]
        codes = v["coding_order"]["unit_codes_frame"]
        rows = [[u["index"], u["packet"], u["offset"], u["size"],
                 ", ".join(OBU_NAMES.get(t, str(t)) for t in u["obu_types"]), "yes" if u["access_point"] else "",
                 codes[u["index"]]] for u in v["index"]["units"]]
        obu_name = name.replace(".ivf", ".obu")
        obu_off = [u["offset"] for u in f[obu_name]["index"]["units"]]
        for r, o in zip(rows, obu_off):
            r.insert(3, o)
        pk = ", ".join(f"{i}: offset {p['offset']}, {p['size']} bytes, pts {p['pts']}"
                       for i, p in enumerate(v["index"]["packets"]))
        out.append(f"## Temporal units of `{name}` and `{obu_name}`\n\n" +
                   md_table(["Unit", "IVF packet", "Offset in .ivf", "Offset in .obu", "Bytes", "OBU types",
                             "Access point", "Codes frame"], rows) +
                   f"\n\nIVF packets (12-byte header each): {pk}. Encoder summary: {v['encoder_summary']['kbps']} kbit/s, "
                   f"overall PSNR {v['encoder_summary']['psnr_overall_db']} dB.")
    rows = [[i, f"`{a}`", f"`{b}`"] for i, (a, b) in enumerate(zip(full8["frame_md5"], full10["frame_md5"]))]
    out.append("## Frame MD5, display order (avmdec v1.0.0 = dav2d)\n\n" +
               md_table(["Frame", "8 bit (`.ivf` and `.obu`)", "10 bit (`.ivf` and `.obu`)"], rows) +
               f"\n\nWhole stream: 8 bit `{full8['md5_all_frames']['avmdec --md5']}`, 10 bit "
               f"`{full10['md5_all_frames']['avmdec --md5']}` (same value from `avmdec --md5` and `dav2d --muxer md5`).")
    c = f["av2-256x144-8bit-cut.ivf"]
    dc = c["decoders_on_cut_file"]
    dw = c["decoders_on_whole_units_as_obu"]
    out.append(f"""## The cut file

`av2-256x144-8bit-cut.ivf` is the first {c['cut_at_byte']:,} bytes of `av2-256x144-8bit.ivf`: the file stops inside
temporal unit {c['cut_in_unit']} (in the middle of its last OBU), which sits in IVF packet {c['cut_in_packet']} after
unit 7, a whole unit of the same packet. The packet header still announces its full size and the IVF header still says
12 frames, as after an interrupted copy.

* **Index**: {c['whole_units']} whole units (0 to 7), unit 8 incomplete; access points 0 and 6.
* **Frames**: the whole units carry frames {', '.join(str(x) for x in c['frames_carried_by_whole_units'])}; only the
  first **{c['contiguous_frames_from_start']}** (0 to 6) play without a gap, since frames 7 to 10 are in the missing
  units. For an IVF this is also the `pts` of the first incomplete packet ({c['index']['packets'][c['cut_in_packet']]['pts']}).
* **Decoders on the file**: avmdec exit {dc['avmdec']['exit']}, frames {dc['avmdec']['display_indices']}; dav2d exit
  {dc['dav2d']['exit']}, frames {dc['dav2d']['display_indices']} (both drop the incomplete packet, with unit 7 in it).
* **Decoders on the 8 whole units as a Section 5 stream** (what the companion is fed): avmdec exit
  {dw['avmdec']['exit']}, dav2d exit {dw['dav2d']['exit']}, both give frames {dw['dav2d']['display_indices']} in that
  order (frame 11 comes out at the end of the data), each with the MD5 of the full decode.""")
    dm = f["av2-256x144-8bit-damaged.ivf"]
    dd = dm["decoders"]
    out.append(f"""## The damaged file

`av2-256x144-8bit-damaged.ivf` is `av2-256x144-8bit.ivf` with bytes {dm['damaged_bytes']['offset']} to
{dm['damaged_bytes']['offset'] + dm['damaged_bytes']['length'] - 1} set to 0xFF ({dm['damaged_bytes']['where']};
unit 1 codes frame 5, which frames 1 to 4 use). The container is intact: the index still finds 12 whole units and the
access points 0 and 6.

* **dav2d**: prints `{dd['dav2d']['stderr_tail'][-1] if dd['dav2d']['stderr_tail'] else ''}`, exit {dd['dav2d']['exit']},
  frames {dd['dav2d']['display_indices']}: frames 1 to 5 are lost, decoding comes back at the next access point.
* **avmdec v1.0.0**: `{dd['avmdec']['stderr_tail'][-1] if dd['avmdec']['stderr_tail'] else ''}`, exit
  {dd['avmdec']['exit']}, frames {dd['avmdec']['display_indices']} (it stops at the first error).
* Neither crashed. The companion must turn the error into its `stopped` message or skip to the next access point
  (AD2 decides); the app must stay up.

Other damage tried on the same file (not kept as files; frames as display indices):

""" + md_table(["Damage", "dav2d exit", "dav2d frames", "avmdec exit", "avmdec frames", "avmdec message"],
               [[r["damage"], r["dav2d"]["exit"], r["dav2d"]["display_indices"], r["avmdec"]["exit"],
                 r["avmdec"]["display_indices"], r["avmdec"]["last_message"].replace("Warning: Additional information: ", "")]
                for r in m["damage_survey"]]) +
               "\n\nExit -11 is a segmentation fault: `avmdec` v1.0.0 crashes on unit 1's tile data set to zero; "
               "dav2d does not (the reference decoder only verifies, it is never shipped).")
    a = f["av1-256x144-8bit.ivf"]
    out.append(f"""## The AV1 sample

`av1-256x144-8bit.ivf`: 2 frames of the same source by libaom (through ffmpeg), IVF fourcc `{a['ivf_header']['fourcc']}`.
Its first OBU is `12 00` (AV1 temporal delimiter); read as AV2 it would be an OBU of type 0, which does not exist. It
must be refused as AV2 by the fourcc for `.ivf`, and by the first OBU for a Section 5 stream.""")
    out.append(f"""## Check again, make again

* After a new dav2d commit: `python3 make_av2_fixtures.py verify DIR` decodes every AV2 fixture of DIR with both
  decoders and compares each frame with `fixtures.json` (exit 1 on any difference). The CI has no avmdec: it compares
  the companion's frames with the `frame_md5` lists of `fixtures.json`, which come from avmdec v1.0.0.
* Make again on ai1: `python3 make_av2_fixtures.py sources` then `python3 make_av2_fixtures.py fixtures` then
  `python3 make_av2_fixtures.py doc fixtures/out`. `fixtures.json` holds every value of this page, the index of every
  file and the {len(m['commands'])} commands run, in order.

## Commands run

Sources (`commands-sources.txt`):

```
""" + (d / "commands-sources.txt").read_text().strip() + """
```

Fixtures and checks (from `fixtures.json`, paths relative to `~/av2-2026-11-02/` on ai1):

```
""" + "\n".join(m["commands"]) + "\n```\n")
    (d / "FIXTURES.md").write_text("\n\n".join(out) + "\n")
    print("wrote", d / "FIXTURES.md")


# ---------------------------------------------------------------- verify


def cmd_verify(args):
    d = Path(args.dir).resolve()
    TMP.mkdir(parents=True, exist_ok=True)
    m = json.loads((d / "fixtures.json").read_text())
    bad = 0
    for name, f in m["files"].items():
        if f["kind"] != "av2":
            continue
        fsize = frame_bytes(f["width"], f["height"], f["bits"])
        for t in ("avmdec", "dav2d"):
            if not (d / name).exists():
                sys.exit(f"missing {d / name}")
            got = decode(t, d / name, TMP / "dec.yuv", fsize)
            same = got["exit"] == 0 and got["frames"] == f["frame_md5"]
            bad += not same
            print(name, t, "OK" if same else f"DIFFERENT (exit {got['exit']}, {len(got['frames'])} frames)")
    sys.exit(1 if bad else 0)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sources").set_defaults(fn=cmd_sources)
    sub.add_parser("fixtures").set_defaults(fn=cmd_fixtures)
    sub.add_parser("clip-encode").set_defaults(fn=cmd_clip_encode)
    sub.add_parser("clip-check").set_defaults(fn=cmd_clip_check)
    dp = sub.add_parser("doc")
    dp.add_argument("dir")
    dp.set_defaults(fn=cmd_doc)
    v = sub.add_parser("verify")
    v.add_argument("dir")
    v.set_defaults(fn=cmd_verify)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
