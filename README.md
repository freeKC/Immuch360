<p align="center">
  <img src="mobile/assets/immich-logo.png" width="120" alt="Immuch360 icon">
</p>

<h1 align="center">Immuch360</h1>

<p align="center">
  A fork of the <a href="https://github.com/immich-app/immich">Immich</a> mobile app that adds what the official app does not have yet: 360° photos, 360° videos, gyroscope navigation, and an immersive view on the Meta Quest 3. It talks to your existing Immich server, nothing to change on the server side.
</p>

<p align="center">The name reads as "I am much 360".</p>

## What this fork adds compared to Immich

| Feature | Immich mobile app | Immuch360 | Status |
|---|---|---|---|
| 360° photos (equirectangular) shown as an interactive sphere | No, flat image only | **Yes**, drag to look around, pinch to zoom, partial panoramas handled (GPano crop) | Released, verified on a Galaxy S24+ and on the iOS simulator |
| 360° badge on thumbnails | No | **Yes** | Released |
| 360° button in the viewer top bar, zoom kept on the flat view, loading indicator | n/a | **Yes** | Released |
| Gyroscope navigation: look around by moving the phone | No | **Yes**, toggle in the 360 viewer (off by default) | Released, verified on a Galaxy S24+ |
| Initial view from GPano metadata, inertia after a drag, double tap zoom, sharper texture when zoomed in | No | **Yes** | Released, device feedback welcome |
| 360° videos played on a sphere with drag and head tracking | No, flat video only | **Yes on Android** (native Media3 player opened by the 360 button; plays the copy on the phone when there is one) | Released (Android), device feedback welcome; iOS later |
| Meta Quest 3 viewer with head tracking | No | **Yes**, the same APK opens 360 photos and videos in an immersive view (Meta Spatial SDK) | Released in the same APK, not yet verified on a headset |
| Native Insta360 files (.insp, .insv, .dng dual fisheye) | Shown flat or wrongly | Server side stitching under study | Study |

Everything else is Immich, unchanged: backup, timeline, albums, search, sharing, all synced with your server.

The 360° photo viewer is based on the upstream pull request [immich-app/immich#31169](https://github.com/immich-app/immich/pull/31169) by dmitry-brazhenko, itself built on the prototype by bencefr in [#30192](https://github.com/immich-app/immich/pull/30192). Thanks to both. The long standing request is [discussion #6572](https://github.com/immich-app/immich/discussions/6572).

## Why a fork

The Immich team is small and focuses the mobile app on backup and library features. 360° support on mobile has been requested since January 2024 and is still not merged. This fork exists to ship it now, to gather real device feedback, and to send back to Immich, in small pull requests, whatever the maintainers are willing to take.

## Install

- **Android**: download the APK from the [Releases](https://github.com/freeKC/Immuch360/releases) page. The app installs next to the official Immich app (different package name `com.aprogsys.immuch360`), so you can keep both.
- **iOS**: the app builds and runs on the simulator (Codemagic); TestFlight distribution is being set up.
- **Meta Quest 3**: the same Android APK can be sideloaded. It runs as a window and opens 360° media in an immersive view with head tracking, see [Meta Quest 3](#meta-quest-3).

Log in with your usual Immich server URL and account. The app follows the Immich mobile releases; use a build whose version matches your server version.

## Meta Quest 3

The main Immuch360 APK also runs on Meta Quest headsets (Horizon OS v69 or later): it is the one to sideload. It is not in the Meta Horizon Store.

### Install

1. Enable developer mode once. In the Meta Horizon phone app, open Devices, select the headset, then Headset settings, then Developer mode. This needs a developer account, which is free at developers.meta.com.
2. Connect the headset to a computer with a USB-C cable. In the headset, accept "Allow USB debugging".
3. Install the APK:

   ```bash
   adb devices                      # the headset must be listed as "device"
   adb install -r Immuch360-<version>.apk
   ```

4. In the headset, open the Library, choose the "Unknown sources" filter, and start Immuch360.

### In the window

The whole app runs as a resizable 2D window: login, timeline, albums, search, the photo and video viewers. The gyroscope toggle of the 2D 360° viewer is hidden on the headset, because a window stays fixed in space.

### Immersive view

1. Open a 360° photo or video in the viewer.
2. Press the 360° button. The app switches to an immersive view where the media surrounds you and follows your head.
3. To go back to the window, press B or Y, or the Back button of the info panel.

| Action | Controllers | Hands |
|---|---|---|
| Back to the app | B or Y | Back button of the info panel |
| Play or pause a video | Trigger, when the info panel is hidden | Play or Pause button of the info panel |
| Show or hide the info panel | A, X, grip or menu | Menu gesture, or pinch when the panel is hidden |
| Turn the image by 90° | Thumbstick left or right | |

Photos show a preview first, then the original, downscaled to at most 8192x4096 (the texture limit of the headset). Videos play the copy on the headset when there is one, else the original on the server, or the server playback stream when the original cannot stream or play.

If the image does not face you the right way when it opens, turn it with the thumbstick until its center is in front of you: the log line `photo yaw is now ...` or `video yaw is now ...` gives the value to report, so that it can become the default.

### Limitations

- **Video codecs:** the H.264 hardware decoder of the Quest 3 (XR2 Gen 2) tops out around 4096x2304. A 5760x2880 H.264 video (level 6.0, about 200 Mbit/s, the usual Insta360 export) decodes at about 17 fps on the headset, with block artifacts, while the same file plays fine on a phone. The same video in HEVC (H.265) plays well on the headset. When the original is H.264 above that size, the immersive view switches to the server playback stream (the Immich transcode, when there is one), and if that one is still too large the info panel says so for 10 seconds. To give the headset a video it can decode, in Immich go to Administration, Settings, Video Transcoding Settings, and pick one of these:
  - **Every H.264 video re-encoded in HEVC:** set Video codec to HEVC and Target resolution to Original (the default 720p would shrink a 360° video to 1440x720), and keep only HEVC in Accepted video codecs. Every H.264 video of the library is transcoded, not only the 360° ones, and the headset gets HEVC at full resolution.
  - **Only what is larger than 1440p:** keep H.264 in Accepted video codecs, set Transcode policy to "Videos higher than target resolution or not in an accepted format" and Target resolution to 1440p, preferably with Video codec set to HEVC. Anything larger is transcoded and the headset gets 2880x1440. Regular 4K videos are transcoded to 1440p too.

  After changing these settings, the existing videos must be transcoded again: Administration, Job Queues (Jobs in older Immich versions), Transcode videos, All. Browsers without HEVC support (Firefox on most systems, Chrome without hardware HEVC decoding) will not play an HEVC transcode in Immich web.

  The alternative is to re-encode the export in HEVC before uploading it:

  ```bash
  ffmpeg -i VID_360.mp4 -c:v libx265 -crf 20 -preset medium -tag:v hvc1 -c:a copy -movflags +faststart VID_360_hevc.mp4
  exiftool -tagsFromFile VID_360.mp4 -XMP-GSpherical:all VID_360_hevc.mp4
  ```

  `-tag:v hvc1` labels the HEVC track the way Apple devices and browsers expect, `-c:a copy` keeps the audio as it is. ffmpeg drops the 360° tag of the export, the exiftool line copies it back; without it, Immich shows the video as a flat one.
- **Originals that cannot stream:** when the server ignores HTTP Range requests on the original and the MP4 index (moov) is at the end of the file, the whole file would have to download before the first frame, so the app falls back to the server playback stream. A reverse proxy in front of Immich that buffers the responses or strips the Range headers causes this.
- **Not in the store:** sideloading only.
- **Mono only:** stereo 3D media show both eyes in one sphere.
- **Not yet tested on a headset:** the starting orientation of photos and videos is an assumption (`SKYBOX_YAW_DEGREES` and `VIDEO_YAW_DEGREES` in `ImmersiveViewerActivity.kt`), adjustable with the thumbstick.
- **APK size:** the Spatial SDK adds about 56 MB of 64-bit ARM native code, on phones too, where it is never loaded.
- **License:** the immersive view uses the Meta Spatial SDK, distributed under the Meta Platform Technologies SDK License Agreement.

### Logs

The immersive view logs with the tag `Immuch360`:

```bash
adb logcat -c
# reproduce the problem, then
adb logcat -d -v time -s Immuch360
adb logcat -d -v time > quest-full.log      # everything, including crashes and decoder errors
```

## Build it yourself

The build chain is the one of Immich mobile (Flutter 3.47, managed with [mise](https://mise.jdx.dev)):

```bash
git clone https://github.com/freeKC/Immuch360.git
cd Immuch360/mobile
mise install
mise run install
mise run codegen
flutter build apk --release
```

iOS builds run on Codemagic (a hosted Mac) from the `codemagic.yaml` file of this repository, no Mac needed. Android release builds run on GitHub Actions (`.github/workflows/immuch360-release.yml`).

No secret lives in this repository: the Android signing key is stored as encrypted GitHub Actions secrets, and the Apple signing material is stored as encrypted variables on Codemagic. The workflow files only reference them by name.

## Branches

- `main`: mirror of Immich `main`, never modified.
- `immuch360`: Immich `main` plus the changes of this fork. Rebased on every Immich release.

## License and trademark

This project is a fork of Immich and stays under the [GNU AGPL v3](LICENSE). Immuch360 is not affiliated with, nor endorsed by, the Immich team or FUTO. The name and the icon are different on purpose. For the full documentation of Immich itself, see [immich.app](https://immich.app).
