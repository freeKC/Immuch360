---
name: Bug report
about: Something does not work in Immuch360, on a phone, tablet, TV, Meta Quest, Windows, Linux or macOS
title: ''
labels: bug
assignees: ''
---

<!-- Thank you for the report. In English or French. A problem that also happens in the official Immich app belongs to the Immich project. -->

**Device and system**
Phone, tablet, TV, Quest, Windows, Linux or macOS: the model and the system version (for example Pixel 8 with Android 16, Chromecast with Google TV, Quest 3, a Windows 11 laptop).

**Build**
The App Version line at the bottom of the menu of the profile picture, at the top right (for example `3.3.0-rc.0 build.23`), or the file you installed and where it came from (Google Play, App Store, Horizon Store, GitHub). With an Immich server, its version too.

**Where the media comes from**
The device itself, an Immich server, an SMB, WebDAV or DLNA share, Plex, a Tapo camera, or a file opened with the program on a computer.

**The media**
Flat, panorama, 360°, 3D, VR180 or a raw camera file (.insp, .insv, .360, .osv); photo or video; the camera and the app that exported it, the resolution and the codec if you know them.

**What happens**
The steps, what you expected and what you got. A screenshot or a short video helps a lot.

**A stabilised 360° video (experimental)**
Only for a problem with the stabilisation: the camera and the file type (Insta360 .insv, GoPro MAX .360, DJI Osmo 360 .osv, or another), where the file was opened from (your Immich library, a share, a folder of the device), whether "Stabilized with the camera's gyroscope" showed, and whether the horizon is off from the first frame or drifts along the clip (after how many seconds). The device model goes in Device and system above. On the Logs page, the lines of `RawVideoStabilization`, `Stabilization` and the reader of the camera (`Insta360Motion`, `GoProMotion`, `DjiMotion`) help. A sample file shared by a link helps the most: only one GoPro MAX file was checked so far.

**Logs**
The Logs page, in the same menu, shares them (on a computer, "Save logs to a file"). On Android and the Quest, the `adb logcat` tags are in [Troubleshooting](https://github.com/freeKC/Immuch360/blob/immuch360/docs/immuch360/troubleshooting.md#logs). Remove your server address from them first.
