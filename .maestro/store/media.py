#!/usr/bin/env python3
"""Builds the media of the App Store captures of Immuch360 (workflow immuch360-ios-captures.yml, job media).

Every file comes from a public CC0 source, downloaded here (SOURCES below): Poly Haven panoramas and backplates
(https://polyhaven.com/license) and one Wikimedia Commons film clip (CC0 1.0). From them it writes:

  OUT/library/       the photos and videos the capture jobs add to the photo library of the simulator, each dated
                     (EXIF DateTimeOriginal for a photo, creation_time for a video) so that the timeline reads as a
                     library of several years, newest first; the 360° photos carry the GPano XMP the app reads
  OUT/nas/           the files of the WebDAV share the capture jobs serve: a folder of holiday panoramas and photos
                     and a 360° video ("holidays"), and a film of more than ten minutes ("films")
  OUT/manifest.json  every file written, its source, authors, date and what was made of it

Made here from the downloads, with Pillow, numpy, ffmpeg and spatialmedia (Spatial Media Metadata Injector):
  - a 3D 360° photo, side by side (two equirectangular eyes, 4:1), from Lakeside Dawn;
  - a VR180 clip, side by side (two square eyes, 2:1), 8 s, from the front half of Lakeside Sunrise, with Spherical
    Video V1 metadata: stereo left-right, crop of half the width;
  - a 360° video, 12 s, from Pink Sunrise turning slowly, with Spherical Video V1 metadata;
  - a film of 12 min 30 s, the clip of the lighthouse at sunset played again and again.
The 3D eyes differ by a parallax that grows below the horizon, as the ground comes closer: an approximation, enough
for a file the viewers lay out as 3D.

usage: media.py OUT [--cache DIR]   (--cache: a folder of files already downloaded, by the names of SOURCES)
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'media'))
import prepare_panoramas as pp  # noqa: E402

PH = 'https://dl.polyhaven.org/file/ph-assets/HDRIs/extra'
PANO = f'{PH}/Tonemapped%20JPG'
PLATE = f'{PH}/Backplates'
UA = 'Immuch360-store-captures/1.0 (https://github.com/freeKC/Immuch360)'

# name: (url, title, authors), authors as the Poly Haven API gives them (api.polyhaven.com/info/<asset>)
SOURCES = {
    'the_sky_is_on_fire': (f'{PANO}/the_sky_is_on_fire.jpg', 'The Sky Is On Fire', ['Greg Zaal', 'Rico Cilliers']),
    'pink_sunrise': (f'{PANO}/pink_sunrise.jpg', 'Pink Sunrise', ['Greg Zaal', 'Rico Cilliers']),
    'rogland_clear_night': (f'{PANO}/rogland_clear_night.jpg', 'Rogland Clear Night', ['Greg Zaal']),
    'lakeside_sunrise': (f'{PANO}/lakeside_sunrise.jpg', 'Lakeside Sunrise', ['Greg Zaal', 'Jarod Guest']),
    'lakeside_dawn': (f'{PANO}/lakeside_dawn.jpg', 'Lakeside Dawn', ['Greg Zaal', 'Jarod Guest']),
    'lakeside_night': (f'{PANO}/lakeside_night.jpg', 'Lakeside Night', ['Greg Zaal', 'Jarod Guest']),
    'lakeside': (f'{PANO}/lakeside.jpg', 'Lakeside', ['Greg Zaal']),
    'kiara_1_dawn': (f'{PANO}/kiara_1_dawn.jpg', 'Kiara 1 Dawn', ['Greg Zaal']),
    'dikhololo_night': (f'{PANO}/dikhololo_night.jpg', 'Dikhololo Night', ['Greg Zaal']),
    'spruit_sunrise': (f'{PANO}/spruit_sunrise.jpg', 'Spruit Sunrise', ['Greg Zaal']),
    'snowy_forest_path_01': (f'{PANO}/snowy_forest_path_01.jpg', 'Snowy Forest Path 01', ['Oliksiy Yakovlyev']),
    'belfast_sunset_puresky': (f'{PANO}/belfast_sunset_puresky.jpg', 'Belfast Sunset (Pure Sky)',
                               ['Dimitrios Savva', 'Greg Zaal', 'Jarod Guest']),
    'plate_fire_IMG_0809': (f'{PLATE}/the_sky_is_on_fire/jpg_pretty/IMG_0809.jpg', 'The Sky Is On Fire, backplate IMG_0809',
                            ['Greg Zaal', 'Rico Cilliers']),
    'plate_pink_IMG_0233': (f'{PLATE}/pink_sunrise/jpg_pretty/IMG_0233.jpg', 'Pink Sunrise, backplate IMG_0233',
                            ['Greg Zaal', 'Rico Cilliers']),
    'plate_pink_IMG_0251': (f'{PLATE}/pink_sunrise/jpg_pretty/IMG_0251.jpg', 'Pink Sunrise, backplate IMG_0251',
                            ['Greg Zaal', 'Rico Cilliers']),
    'plate_umhlanga_DSC08466': (f'{PLATE}/umhlanga_sunrise/jpg_plain/DSC08466.jpg',
                                'Umhlanga Sunrise, backplate DSC08466', ['Greg Zaal']),
    'plate_sunflowers_DSC_0261': (f'{PLATE}/sunflowers/jpg_pretty/DSC_0261.jpg', 'Sunflowers, backplate DSC_0261',
                                  ['Sergej Majboroda']),
    'plate_sunflowers_DSC_0296': (f'{PLATE}/sunflowers/jpg_pretty/DSC_0296.jpg', 'Sunflowers, backplate DSC_0296',
                                  ['Sergej Majboroda']),
    'plate_tucker_IMG_0401': (f'{PLATE}/tucker_wreck/jpg_plain/IMG_0401.jpg', 'Tucker Wreck, backplate IMG_0401',
                              ['Greg Zaal', 'Rico Cilliers']),
    'plate_venetian_DSC07319': (f'{PLATE}/venetian_crossroads/jpg_plain/DSC07319.jpg',
                                'Venetian Crossroads, backplate DSC07319', ['Greg Zaal', 'Rico Cilliers']),
    'plate_table_mountain_IMG_0929': (f'{PLATE}/table_mountain_1/jpg_plain/IMG_0929.jpg',
                                      'Table Mountain 1, backplate IMG_0929', ['Greg Zaal', 'Rico Cilliers']),
    'plate_meadow_10': (f'{PLATE}/meadow/jpg_plain/10.jpg', 'Meadow, backplate 10', ['Sergej Majboroda']),
    'plate_studio_10': (f'{PLATE}/christmas_photo_studio_07/jpg_plain/10.jpg',
                        'Christmas Photo Studio 07, backplate 10', ['Sergej Majboroda']),
    'plate_lythwood_DSC08767': (f'{PLATE}/lythwood_room/jpg_plain/DSC08767.jpg', 'Lythwood Room, backplate DSC08767',
                                ['Greg Zaal']),
    'plate_vignaioli_DSC07542': (f'{PLATE}/vignaioli_night/jpg_plain/DSC07542.jpg',
                                 'Vignaioli Night, backplate DSC07542', ['Greg Zaal', 'Rico Cilliers']),
    'plate_autumn_10': (f'{PLATE}/autumn_field/jpg_pretty/10.jpg', 'Autumn Field, backplate 10', ['Sergej Majboroda']),
    'plate_autumn_13': (f'{PLATE}/autumn_field/jpg_pretty/13.jpg', 'Autumn Field, backplate 13', ['Sergej Majboroda']),
    'plate_pine_attic_10': (f'{PLATE}/pine_attic/jpg_plain/10.jpg', 'Pine Attic, backplate 10', ['Sergej Majboroda']),
    'lighthouse_webm': ('https://upload.wikimedia.org/wikipedia/commons/6/65/'
                        'Orbit_around_Fremantle_South_Mole_Lighthouse_at_sunset.webm',
                        'Orbit around Fremantle South Mole Lighthouse at sunset', ['JamesBromberger']),
}
LICENCE_PH = 'CC0 1.0, Poly Haven (https://polyhaven.com/license)'
LICENCE_WM = ('CC0 1.0, Wikimedia Commons (https://commons.wikimedia.org/wiki/'
              'File:Orbit_around_Fremantle_South_Mole_Lighthouse_at_sunset.webm)')

# The photo library: (file, source, date, kind, options). kind: pano (GPano, width), flat (longest side 3000),
# stereo3d, vr180, video360
LIBRARY = [
    ('sky_is_on_fire.jpg', 'plate_fire_IMG_0809', '2026:10:24 18:50:00', 'flat', {}),
    # The hero: its initial view looks at the glow over the sea (63 percent of the width), a little above the horizon
    ('sky_is_on_fire_360.jpg', 'the_sky_is_on_fire', '2026:10:24 18:42:00', 'pano',
     {'width': 8192, 'heading': 47, 'pitch': 6}),
    ('pink_sunrise_360.mp4', 'pink_sunrise', '2026:10:19 07:10:00', 'video360', {}),
    ('pink_sunrise_b.jpg', 'plate_pink_IMG_0251', '2026:10:19 07:02:00', 'flat', {}),
    ('pink_sunrise_a.jpg', 'plate_pink_IMG_0233', '2026:10:19 06:55:00', 'flat', {}),
    ('pink_sunrise_360.jpg', 'pink_sunrise', '2026:10:19 06:48:00', 'pano', {'width': 4096}),
    ('lakeside_sunrise_VR180.mp4', 'lakeside_sunrise', '2026:09:30 07:05:00', 'vr180', {}),
    ('lakeside_dawn_360_3D.jpg', 'lakeside_dawn', '2026:09:30 06:40:00', 'stereo3d', {}),
    ('milky_way_360.jpg', 'rogland_clear_night', '2026:09:22 23:10:00', 'pano', {'width': 4096}),
    ('beach_sunrise.jpg', 'plate_umhlanga_DSC08466', '2026:09:22 06:35:00', 'flat', {}),
    ('sunflowers_b.jpg', 'plate_sunflowers_DSC_0296', '2026:08:15 16:20:00', 'flat', {}),
    ('sunflowers_a.jpg', 'plate_sunflowers_DSC_0261', '2026:08:15 16:10:00', 'flat', {}),
    ('lakeside_360.jpg', 'lakeside', '2026:07:04 12:30:00', 'pano', {'width': 4096}),
    ('lakeside_night_360.jpg', 'lakeside_night', '2026:06:20 22:45:00', 'pano', {'width': 4096}),
    ('narrow_street.jpg', 'plate_venetian_DSC07319', '2026:04:11 13:15:00', 'flat', {}),
    ('rocky_shore.jpg', 'plate_tucker_IMG_0401', '2026:03:08 16:40:00', 'flat', {}),
    ('snowy_forest_360.jpg', 'snowy_forest_path_01', '2026:01:17 10:20:00', 'pano', {'width': 4096}),
    ('armchair.jpg', 'plate_lythwood_DSC08767', '2025:12:24 18:00:00', 'flat', {}),
    ('sunset_sky_360.jpg', 'belfast_sunset_puresky', '2025:09:06 19:50:00', 'pano', {'width': 4096}),
    ('table_mountain.jpg', 'plate_table_mountain_IMG_0929', '2025:07:12 11:05:00', 'flat', {}),
    ('kiara_dawn_360.jpg', 'kiara_1_dawn', '2025:07:12 06:05:00', 'pano', {'width': 4096}),
    ('meadow.jpg', 'plate_meadow_10', '2025:05:03 09:30:00', 'flat', {}),
    ('studio.jpg', 'plate_studio_10', '2025:02:14 15:00:00', 'flat', {}),
    ('autumn_field.jpg', 'plate_autumn_10', '2024:10:13 17:30:00', 'flat', {}),
    ('savanna_night_360.jpg', 'dikhololo_night', '2024:08:09 22:30:00', 'pano', {'width': 4096}),
    ('autumn_field_b.jpg', 'plate_autumn_13', '2024:06:02 18:20:00', 'flat', {}),
    ('night_square.jpg', 'plate_vignaioli_DSC07542', '2024:03:30 21:10:00', 'flat', {}),
    ('attic.jpg', 'plate_pine_attic_10', '2023:12:03 11:00:00', 'flat', {}),
    ('spruit_sunrise_360.jpg', 'spruit_sunrise', '2023:06:18 07:05:00', 'pano', {'width': 4096}),
]

# The share: holiday panoramas (GPano, 2048 wide), two photos and the 360° video, then the film
NAS_HOLIDAYS = [
    ('IMG_3601.jpg', 'the_sky_is_on_fire', 'pano', '2026:10:24 18:42:00'),
    ('IMG_3602.jpg', 'pink_sunrise', 'pano', '2026:10:19 06:48:00'),
    ('IMG_3603.jpg', 'lakeside_sunrise', 'pano', '2026:09:30 07:00:00'),
    ('IMG_3604.jpg', 'rogland_clear_night', 'pano', '2026:09:22 23:10:00'),
    ('IMG_3605.jpg', 'lakeside_dawn', 'pano', '2026:09:30 06:30:00'),
    ('IMG_3606.jpg', 'kiara_1_dawn', 'pano', '2025:07:12 06:05:00'),
    ('IMG_3607.jpg', 'dikhololo_night', 'pano', '2024:08:09 22:30:00'),
    ('IMG_3608.jpg', 'spruit_sunrise', 'pano', '2023:06:18 07:05:00'),
    ('IMG_3609.jpg', 'lakeside', 'pano', '2026:07:04 12:30:00'),
    ('IMG_3610.jpg', 'snowy_forest_path_01', 'pano', '2026:01:17 10:20:00'),
    ('IMG_3611.jpg', 'lakeside_night', 'pano', '2026:06:20 22:45:00'),
    ('IMG_3612.jpg', 'belfast_sunset_puresky', 'pano', '2025:09:06 19:50:00'),
    ('IMG_3613.jpg', 'plate_fire_IMG_0809', 'flat', '2026:10:24 18:50:00'),
    ('IMG_3614.jpg', 'plate_umhlanga_DSC08466', 'flat', '2026:09:22 06:35:00'),
]
FILM_SECONDS = 750


def run(*args, **kw):
    print('+', ' '.join(str(a) for a in args), flush=True)
    subprocess.run([str(a) for a in args], check=True, **kw)


def fetch(name, cache, dl):
    url = SOURCES[name][0]
    ext = os.path.splitext(url)[1]
    for d in (cache, dl):
        if d and (Path(d) / f'{name}{ext}').exists():
            return Path(d) / f'{name}{ext}'
    dst = Path(dl) / f'{name}{ext}'
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=180) as r, open(dst.with_suffix('.part'), 'wb') as f:
                shutil.copyfileobj(r, f, 1 << 20)
            dst.with_suffix('.part').rename(dst)
            print(f'downloaded {name}: {dst.stat().st_size} bytes', flush=True)
            return dst
        except Exception as error:  # noqa: BLE001
            print(f'download {name} failed ({error}), attempt {attempt + 1}', flush=True)
    raise SystemExit(f'could not download {url}')


def gpano_xmp(full_w, full_h, heading=None, pitch=None):
    view = ''
    if heading is not None and pitch is not None:
        view = (f'   GPano:InitialViewHeadingDegrees="{heading}"\n'
                f'   GPano:InitialViewPitchDegrees="{pitch}"\n'
                '   GPano:PoseHeadingDegrees="0"\n')
    xmp = (
        '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '    xmlns:GPano="http://ns.google.com/photos/1.0/panorama/"\n'
        '   GPano:UsePanoramaViewer="True"\n'
        '   GPano:ProjectionType="equirectangular"\n'
        f'{view}'
        f'   GPano:CroppedAreaImageWidthPixels="{full_w}"\n'
        f'   GPano:CroppedAreaImageHeightPixels="{full_h}"\n'
        f'   GPano:FullPanoWidthPixels="{full_w}"\n'
        f'   GPano:FullPanoHeightPixels="{full_h}"\n'
        '   GPano:CroppedAreaLeftPixels="0"\n'
        '   GPano:CroppedAreaTopPixels="0"/>\n'
        ' </rdf:RDF>\n'
        '</x:xmpmeta>\n'
        '<?xpacket end="w"?>'
    )
    return pp.XMP_HEADER + xmp.encode('utf-8')


def save_jpeg(img, dst, date, xmp=None, quality=90):
    """img saved as a JPEG, then its metadata replaced: an EXIF dated `date`, and the XMP when given"""
    tmp = Path(str(dst) + '.tmp.jpg')
    img.save(tmp, quality=quality, subsampling=0 if quality >= 92 else 2)
    data = tmp.read_bytes()
    tmp.unlink()
    segs, sos = pp.segments(data)
    kept = [(m, p) for m, p in segs if m not in pp.DROPPED]
    added = [pp.segment(0xE1, pp.exif_dates(date))]
    if xmp:
        added.append(pp.segment(0xE1, xmp))
    out = bytearray(b'\xff\xd8')
    inserted = False
    for marker, payload in kept:
        if not inserted and marker != 0xE0:
            out += b''.join(added)
            inserted = True
        out += bytes([0xFF, marker]) if payload is None else pp.segment(marker, payload)
    if not inserted:
        out += b''.join(added)
    out += data[sos:]
    Path(dst).write_bytes(out)


def load(path, width=None, longest=None):
    im = Image.open(path)
    if width:
        im.draft('RGB', (width, width // 2))
    im = im.convert('RGB')
    if width and im.width != width:
        im = im.resize((width, width // 2), Image.LANCZOS)
    if longest:
        im.thumbnail((longest, longest), Image.LANCZOS)
    return im


def parallax(eq, strength):
    """The two eyes of an equirectangular image: rows below the horizon shift apart as the ground comes nearer"""
    a = np.asarray(eq)
    h, w = a.shape[:2]
    lat = (0.5 - (np.arange(h) + 0.5) / h) * np.pi  # +pi/2 at the top
    shift = np.where(lat < 0, np.sin(-lat), 0.0) * strength * w
    left = np.empty_like(a)
    right = np.empty_like(a)
    for y in range(h):
        s = int(round(shift[y] / 2))
        left[y] = np.roll(a[y], s, axis=0)
        right[y] = np.roll(a[y], -s, axis=0)
    return left, right


def stereo3d(src, dst, date):
    """A 3D 360° photo, eyes side by side (4:1). The lake view, at the middle of the source, is turned to the seam of
    the eyes, the middle of the frame, which is what a square thumbnail shows"""
    eq = load(src, width=3072)
    a = np.roll(np.asarray(eq), eq.width // 2, axis=1)
    left, right = parallax(Image.fromarray(a), 0.006)
    sbs = Image.fromarray(np.concatenate([left, right], axis=1))
    save_jpeg(sbs, dst, date, gpano_xmp(eq.width, eq.height), quality=92)


def ffmpeg_from_frames(frames, size, fps, dst, extra):
    proc = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s',
                             f'{size[0]}x{size[1]}', '-r', str(fps), '-i', '-', '-c:v', 'libx264', '-preset', 'medium',
                             '-crf', '21', '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-tag:v', 'avc1',
                             '-movflags', '+faststart', *extra, str(dst)], stdin=subprocess.PIPE)
    for frame in frames:
        proc.stdin.write(frame.tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        raise SystemExit(f'ffmpeg failed for {dst}')


def iso(date):
    d, t = date.split(' ')
    return d.replace(':', '-') + 'T' + t + 'Z'


def inject(src, dst, *args):
    run(sys.executable, '-m', 'spatialmedia', '-i', *args, src, dst)
    Path(src).unlink()
    out = subprocess.run([sys.executable, '-m', 'spatialmedia', str(dst)], capture_output=True, text=True).stdout
    print(out, flush=True)
    if 'Spherical' not in out:
        raise SystemExit(f'no spherical metadata in {dst}')


def video360(src, dst, date, seconds=12, fps=30, size=(2880, 1440)):
    """The panorama turning slowly, a 360° video with Spherical Video V1 metadata"""
    eq = np.asarray(load(src, width=size[0]))
    step = size[0] * 0.03 / fps  # 3 percent of the width a second, a turn of about 11 degrees
    frames = (np.roll(eq, -int(round(i * step)), axis=1) for i in range(seconds * fps))
    raw = Path(str(dst) + '.raw.mp4')
    ffmpeg_from_frames(frames, size, fps, raw, ['-metadata', f'creation_time={iso(date)}'])
    inject(raw, dst, '--stereo=none', '--projection=equirectangular')


def vr180(src, dst, date, centre=0.60, seconds=8, fps=30, eye=1440):
    """VR180, eyes side by side: the front half of the panorama around `centre`, turning a little, each eye a square
    180° x 180° equirectangular picture; Spherical Video V1 with a crop of half the width"""
    full = np.asarray(load(src, width=eye * 2 * 2))  # the full panorama, twice the width of an eye pair
    w = full.shape[1]
    left_all, right_all = parallax(Image.fromarray(full), 0.006)
    def frames():
        for i in range(seconds * fps):
            c = centre + 0.012 * np.sin(2 * np.pi * i / (seconds * fps))
            x0 = int(round((c - 0.25) * w))
            cols = np.arange(x0, x0 + w // 2) % w
            le = Image.fromarray(left_all[:, cols]).resize((eye, eye), Image.BILINEAR)
            re = Image.fromarray(right_all[:, cols]).resize((eye, eye), Image.BILINEAR)
            yield np.concatenate([np.asarray(le), np.asarray(re)], axis=1)

    raw = Path(str(dst) + '.raw.mp4')
    ffmpeg_from_frames(frames(), (eye * 2, eye), fps, raw, ['-metadata', f'creation_time={iso(date)}'])
    inject(raw, dst, '--stereo=left-right', '--projection=equirectangular', f'--crop={eye}:{eye}:{eye * 2}:{eye}:{eye // 2}:0')


def film(src, dst, work):
    """The clip of the lighthouse at sunset as a film of FILM_SECONDS: 1280 x 720 H.264, played again and again"""
    clip = Path(work) / 'lighthouse-720p.mp4'
    run('ffmpeg', '-y', '-loglevel', 'error', '-i', src, '-an', '-vf', 'scale=1280:720:flags=lanczos,fps=24',
        '-c:v', 'libx264', '-preset', 'medium', '-crf', '31', '-pix_fmt', 'yuv420p', '-g', '48', '-tag:v', 'avc1',
        clip)
    dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0',
                                str(clip)], capture_output=True, text=True).stdout.strip())
    loops = int(FILM_SECONDS / dur) + 1
    run('ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', str(loops), '-i', clip, '-t', str(FILM_SECONDS),
        '-c', 'copy', '-movflags', '+faststart', '-metadata', 'creation_time=2026-08-21T20:30:00Z', dst)


def library_name(name, date, kind):
    """A name as a phone or a 360° camera writes it, from the date: PANO_ for a 360° photo (and _3D for the stereo
    one), VID_ for a video (_360, _VR180), IMG_ for a photo. `name` stays in the manifest."""
    stamp = date.replace(':', '').replace(' ', '_')
    return {'pano': f'PANO_{stamp}.jpg', 'stereo3d': f'PANO_{stamp}_3D.jpg', 'vr180': f'VID_{stamp}_VR180.mp4',
            'video360': f'VID_{stamp}_360.mp4', 'flat': f'IMG_{stamp}.jpg'}[kind]


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()[:16]


def credit(name):
    url, title, authors = SOURCES[name]
    return {'source': name, 'title': title, 'authors': authors, 'url': url,
            'licence': LICENCE_WM if name == 'lighthouse_webm' else LICENCE_PH}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out = Path(sys.argv[1])
    cache = sys.argv[sys.argv.index('--cache') + 1] if '--cache' in sys.argv else None
    dl = out / 'downloads'
    lib = out / 'library'
    nas = out / 'nas'
    for d in (dl, lib, nas / 'holidays', nas / 'films'):
        d.mkdir(parents=True, exist_ok=True)
    manifest = {'library': [], 'nas': [], 'film': None}
    for i, (name, src, date, kind, opt) in enumerate(LIBRARY):
        path = fetch(src, cache, dl)
        dst = lib / library_name(name, date, kind)
        if kind == 'pano':
            im = load(path, width=opt['width'])
            save_jpeg(im, dst, date, gpano_xmp(im.width, im.height, opt.get('heading'), opt.get('pitch')),
                      quality=92 if opt['width'] >= 8192 else 90)
        elif kind == 'flat':
            save_jpeg(load(path, longest=3000), dst, date)
        elif kind == 'stereo3d':
            stereo3d(path, dst, date)
        elif kind == 'vr180':
            vr180(path, dst, date)
        elif kind == 'video360':
            video360(path, dst, date)
        entry = {'file': dst.name, 'name': name, 'kind': kind, 'date': date, 'bytes': dst.stat().st_size, 'sha256_16': sha(dst)}
        entry.update(credit(src))
        if kind in ('pano', 'flat', 'stereo3d'):
            entry['size'] = list(Image.open(dst).size)
        manifest['library'].append(entry)
        print(json.dumps(entry), flush=True)
    for name, src, kind, date in NAS_HOLIDAYS:
        path = fetch(src, cache, dl)
        dst = nas / 'holidays' / name
        if kind == 'pano':
            im = load(path, width=2048)
            save_jpeg(im, dst, date, gpano_xmp(im.width, im.height))
        else:
            save_jpeg(load(path, longest=2400), dst, date)
        entry = {'file': f'holidays/{name}', 'kind': kind, 'date': date, 'bytes': dst.stat().st_size}
        entry.update(credit(src))
        manifest['nas'].append(entry)
    video = next(library_name(n, d, k) for n, _s, d, k, _o in LIBRARY if k == 'video360')
    shutil.copy(lib / video, nas / 'holidays' / 'VID_3615.mp4')
    manifest['nas'].append({'file': 'holidays/VID_3615.mp4', 'kind': 'video360', **credit('pink_sunrise')})
    film(fetch('lighthouse_webm', cache, dl), nas / 'films' / 'film.mp4', dl)
    manifest['film'] = {'file': 'films/film.mp4', 'seconds': FILM_SECONDS,
                        'bytes': (nas / 'films' / 'film.mp4').stat().st_size, **credit('lighthouse_webm')}
    shutil.rmtree(dl)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
    print(f"library {len(manifest['library'])} files, share {len(manifest['nas'])} files and the film")
    return 0


if __name__ == '__main__':
    sys.exit(main())
