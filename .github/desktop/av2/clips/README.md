# A 1080p AV2 clip for the CI

`lighthouse-1080p30-8bit-60f.ivf` (376 066 bytes, SHA-256
`b539e391b7f65df9cd18fdc163aae280a2cd3fe0d5f6beef848bce9975b650f2`): the first 60 temporal units, one closed group of
pictures (2 s), of the 10 s test clip of lot AD0 (`fremantle-lighthouse-1080p30-av2.ivf`, 300 pictures, 1920x1080,
30 frames a second, 8 bit, encoded by avmenc of AVM), written again one temporal unit per IVF packet with the frame
count of its header set to 60. dav2d decodes it to the same 60 pictures as the first 60 of the whole clip (checked on
4 November 2026, film grain off and on); a cut inside a group of pictures would not do, its last pictures coming out
in another order.

Source: "Orbit around Fremantle South Mole Lighthouse at sunset.webm" by JamesBromberger, Wikimedia Commons, CC0 1.0
(public domain dedication), the source of the fixtures in `mobile/test/fixtures/av2` too (`FIXTURES.md`).

Used by the macOS job of `.github/workflows/immuch360-desktop.yml`: the libmpv of the app reads the serve of the
`av2-macos` archive on it, played five times in a row, with the options the app opens an AV2 video with
(`.github/desktop/libmpv-macos/check_y4m.py companion`).
