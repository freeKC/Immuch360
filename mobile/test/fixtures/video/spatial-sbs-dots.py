# The side by side clip of integration_test/desktop_spatial_renderer_test.dart (spatial-sbs-dots-4s.mp4): each eye
# 640 x 360, a background of green dots at disparity 0, and a 160 x 180 square of red dots 24 pixels nearer (its left
# edge at x 332 in the left eye, at x 308 in the right one), dots of 4 x 4 pixels at two levels per colour. A frame is
# written raw, then encoded with FFmpeg:
#   python3 spatial-sbs-dots.py frame.rgba
#   ffmpeg -f rawvideo -pix_fmt rgba -s 1280x360 -i frame.rgba -frames:v 1 frame.png
#   ffmpeg -loop 1 -framerate 15 -i frame.png -t 4 -c:v libx264 -preset veryslow -crf 20 -g 60 -pix_fmt yuv420p \
#     -tune stillimage -movflags +faststart -an spatial-sbs-dots-4s.mp4
import sys

import numpy as np

W, H, D = 640, 360, 24
X0, SW, Y0, SH = 332, 160, 90, 180
rng = np.random.default_rng(20261022)
bg = rng.integers(0, 2, size=(H // 4, W // 4))
sq = rng.integers(0, 2, size=(SH // 4, SW // 4))


def eye(shift):
    img = np.zeros((H, W, 4), dtype=np.uint8)
    img[..., 3] = 255
    ys, xs = np.mgrid[0:H, 0:W]
    bits = bg[ys // 4, xs // 4]
    img[..., 0] = 20
    img[..., 1] = np.where(bits == 1, 200, 50)
    img[..., 2] = 20
    left = X0 - shift
    inside = (xs >= left) & (xs < left + SW) & (ys >= Y0) & (ys < Y0 + SH)
    sbits = sq[np.clip((ys - Y0) // 4, 0, SH // 4 - 1), np.clip((xs - left) // 4, 0, SW // 4 - 1)]
    img[..., 0] = np.where(inside, np.where(sbits == 1, 220, 70), img[..., 0])
    img[..., 1] = np.where(inside, 20, img[..., 1])
    return img


frame = np.concatenate([eye(0), eye(D)], axis=1)
frame.tofile(sys.argv[1] if len(sys.argv) > 1 else 'frame.rgba')
