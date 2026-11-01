#!/bin/sh
# portrait-blur-6s.mp4, the video of the splat scene tests on a real libmpv (video_frames_libmpv_test.dart): 6 s of
# 320 x 180 at 30 frames a second, H.264, stored lying as a phone stores a video filmed upright, with the rotation of
# the phones in the file (a display matrix of -90 degrees, the "rotate 90" of ffprobe's older tag). Played upright it
# is 180 x 320, a white band at its top. A texture of 4 pixel blocks moves along; every frame is blurred (gaussian,
# sigma 6) but those of 0.40 to 0.57 s of each second, and the whole of the fourth second is blurred.
#
# Made with FFmpeg 5.1 and libx264 on Debian 12 (2026-11-01); the same tools give the same bytes:
#   sh make_portrait_blur.sh && sha256sum portrait-blur-6s.mp4
set -eu
cd "$(dirname "$0")"
stored=$(mktemp --suffix=.mp4)
texture="geq=lum='if(lt(X,40),235,if(mod(floor((X+N)/4)+floor(Y/4),2),200,40))'"
blur="gblur=sigma=6:enable='not(between(mod(n,30),12,17))+between(t,3,4)'"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black:s=320x180:r=30:d=6,format=gray" \
  -vf "$texture,$blur,format=yuv420p" \
  -c:v libx264 -preset slow -crf 20 -g 30 -threads 1 -an -bitexact -map_metadata -1 "$stored"
ffmpeg -hide_banner -loglevel error -y -i "$stored" -c copy -metadata:s:v:0 rotate=270 -map_metadata -1 -bitexact \
  -movflags +faststart portrait-blur-6s.mp4
rm -f "$stored"
