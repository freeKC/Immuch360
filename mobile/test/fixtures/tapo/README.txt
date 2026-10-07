Tapo camera fixtures of the protocol layer tests (test/infrastructure/tapo/). Synthetic only: no camera was involved.

- spake2p_v4_vector.json: computed by the reference client of freeKC/tapo-v4-protocol (tapo_v4/tapo_v4.py, run with
  pycryptodome) from a synthetic password, fixed randoms and a fixed sequence number: the V4 login (SPAKE2+ shares,
  both confirmations, session key and nonce), an encrypted /ds body, and the media port crypto (Digest response, the
  AES-CBC of one part). The generator is appendix A of the Tapo design.
- testsrc_64x36.h264: two seconds of the ffmpeg test pattern, H.264 High in Annex B, one key frame every 30 frames, no
  B frames: `ffmpeg -f lavfi -i testsrc=size=64x36:rate=15 -t 2 -c:v libx264 -profile:v high -pix_fmt yuv420p -g 30
  -bf 0 -x264-params keyint=30:min-keyint=30:scenecut=0 -bsf:v h264_mp4toannexb -f h264 testsrc_64x36.h264`.
