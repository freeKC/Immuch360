UPnP / DLNA fixtures of the DLNA client tests (test/infrastructure/network/upnp/).

Captured with curl and a UDP socket from servers run in Docker, serving only synthetic media made with ffmpeg test
patterns (testsrc, testsrc2, smptebars, mandelbrot, a sine tone):
- minidlna_*: minidlna 1.3.3 (image vladgh/minidlna).
- gerbera_*: Gerbera 3.3.0 (image gerbera/gerbera). The kernel version in the SERVER header of
  gerbera_ssdp_answer.txt was replaced by a generic one.
- *_browse_patterns.xml: the Browse answer of a folder with a video (mov, mp4), a JPEG and an MP3.
- *_browse_701.xml: the answer to an unknown object id. minidlna answers UPnP error 701, Gerbera 501.

browse_sample.xml: the Browse answer of the design document (minidlna style, hand-written).

Hand-written after the layout of real descriptions, to be replaced by captures: plex_DeviceDescription.xml,
jellyfin_description.xml (media server as an embedded device), urlbase_description.xml, no_content_directory.xml.
