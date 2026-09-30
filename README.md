<p align="center">
  <img src=".github/readme/banner.png" width="760" alt="Immuch360: 360° photos and videos for your Immich library, on Android, iOS and Meta Quest 3">
</p>

<p align="center">
  <b>The Immich mobile app, with 360° photos and videos you can look around in.</b><br>
  Android phones, iPhones and the Meta Quest 3. Same server, same account, no server plugin needed.<br>
  <sub>Unofficial fork, early pre-release. Not affiliated with Immich or FUTO.</sub>
</p>

<p align="center">
  <a href="https://github.com/freeKC/Immuch360/releases"><b>Android APK, install it today</b></a> &nbsp;·&nbsp;
  Google Play and App Store: <a href="#where-to-get-it">submitted, under review</a> &nbsp;·&nbsp;
  <a href="#meta-quest-3">Meta Quest 3</a>
</p>

## Who it is for

You back up your photos to an [Immich](https://github.com/immich-app/immich) server and some of them come from a 360° camera (Insta360, GoPro Max, Ricoh Theta, Samsung Gear 360) or from the photo sphere mode of a phone. In the official mobile app those pictures show up as a flat, stretched strip, and 360° videos play flat too. The web app can show a 360° photo as a sphere, the mobile app cannot (requested since January 2024 in [discussion #6572](https://github.com/immich-app/immich/discussions/6572)).

Immuch360 is that mobile app with the missing parts added. The name reads as "I am much 360".

Only stitched 360° files work: exports from the Insta360 app or Studio, GoPro Player, Ricoh Theta, and phone photo spheres. Raw camera files (.insp, .insv, dual fisheye .dng, GoPro .360) still show flat.

## What you get

| Regular viewer | 360° button |
|---|---|
| <img src=".github/readme/phone-flat.png" width="170" alt="The same photo in the regular viewer, flat"> | <img src=".github/readme/phone-sphere.png" width="170" alt="The photo as a sphere in Immuch360"> |
| A 360° photo shown flat | The same photo as a sphere you can turn, zoom, and follow with the phone's gyroscope |

| Library tab | 360° list |
|---|---|
| <img src=".github/readme/library-360.png" width="170" alt="The 360° entry of the Library tab"> | <img src=".github/readme/library-360-list.png" width="170" alt="Only the 360° photos and videos"> |
| A 360° entry next to Favorites | Only your 360° photos and videos, newest first |

- **360° photos** open as an interactive sphere: drag to look around, pinch to zoom, double tap, inertia, the initial view the camera recorded, sharper texture when zoomed in. Partial panoramas are handled.
- **Gyroscope**: turn the phone to look around (toggle in the viewer).
- **360° videos on Android and iOS**: a native spherical player with sound, drag and gyroscope; it plays the file stored on the phone when there is one, otherwise streams it from your server.
- **Meta Quest 3**: the same Android app runs on the headset as a window, and the 360° button switches to an immersive view where the photo or video is all around you, and you look around by turning your head.
- **Find them**: a 360° badge on thumbnails and a **360°** entry in the Library tab listing every 360° photo and video.
- **Everything else is Immich**, unchanged: backup, timeline, albums, search, sharing, partners, all synced with your server.

## Where to get it

The app has been submitted to Google Play and to the App Store and is waiting for their review. Until the listings are live, nothing stops you from installing it yourself:

| Platform | Today | Soon |
|---|---|---|
| Android phones and tablets | APK on the [Releases](https://github.com/freeKC/Immuch360/releases) page: take the `arm64-v8a` file for a phone, or the universal `-release.apk` if unsure. It installs next to the official Immich app (package `com.aprogsys.immuch360`). | Google Play, under review |
| iPhone and iPad | Waiting for Apple's review. The source builds with Xcode or on Codemagic, see [Build it yourself](#build-it-yourself). | App Store, under review |
| Meta Quest 3 | The universal `-release.apk`, sideloaded in developer mode, see [Meta Quest 3](#meta-quest-3). | Sideloading only |

The store links will be added here as soon as the listings are published. Log in with your usual Immich server URL and account. The current build is based on Immich 3.3.0-rc.0 (Immich `main`, not a stable release yet) and was tested with an Immich 3.2 server. The APK from GitHub does not update itself: watch the Releases page, and once you have installed the app from a store, take the updates from that store. Please report problems in [Issues](https://github.com/freeKC/Immuch360/issues), not to the Immich project.

## What this fork adds compared to Immich, in detail

| Feature | Immich mobile app | Immuch360 | Status |
|---|---|---|---|
| 360° photos (equirectangular) shown as an interactive sphere | No, flat image only | **Yes**, drag to look around, pinch to zoom, partial panoramas handled (GPano crop) | Pre-release; tested on a Galaxy S24+ and an iPhone 14 |
| 360° badge on thumbnails | No | **Yes** | Pre-release |
| 360° button in the viewer top bar, zoom kept on the flat view, loading indicator | n/a | **Yes** | Pre-release |
| Gyroscope navigation: look around by moving the phone | No | **Yes**, toggle in the 360 viewer (off by default) | Pre-release; tested on a Galaxy S24+ and an iPhone 14 |
| Initial view from GPano metadata, inertia after a drag, double tap zoom, sharper texture when zoomed in | No | **Yes** | Pre-release, device feedback welcome |
| 360° entry in the Library tab listing every 360° photo and video | No | **Yes** | Pre-release |
| 360° videos played on a sphere with drag and gyroscope | No, flat video only | **Yes on Android and iOS** (native player opened by the 360° button, Media3 on Android and SceneKit on iOS; plays the file stored on the phone when there is one, otherwise streams it from your server) | Pre-release; tested on a Galaxy S24+ and an iPhone 14 |
| Meta Quest 3 viewer with head tracking | No | **Yes**, the same APK opens 360 photos and videos in an immersive view (Meta Spatial SDK) | Pre-release, tested on a Quest 3 |
| Native Insta360 files (.insp, .insv, .dng dual fisheye) | Shown flat or wrongly | Server side stitching under study | Study |

The 360° photo viewer is based on the upstream pull request [immich-app/immich#31169](https://github.com/immich-app/immich/pull/31169) by dmitry-brazhenko, itself built on the prototype by bencefr in [#30192](https://github.com/immich-app/immich/pull/30192). Thanks to both.

## Why a fork

360° viewing on mobile has been requested since January 2024 and is not in the official app yet; the photo viewer is under review upstream in [#31169](https://github.com/immich-app/immich/pull/31169). This fork ships it now, gathers real device feedback, and will offer back to Immich, in small pull requests, whatever the maintainers want. The Meta Quest view relies on the Meta Spatial SDK, which is not open source, so it stays in this fork.

## Meta Quest 3

The main Immuch360 APK also runs on the Meta Quest 3 (Horizon OS v69 or later; other Quest models are untested). Sideload the universal file, the one ending in `-release.apk` with no ABI name. It is not in the Meta Horizon Store.

### Install

1. Enable developer mode once. In the Meta Horizon phone app, open Devices, select the headset, then Headset settings, then Developer mode. This needs a developer account, which is free at developers.meta.com. You also need adb (Android SDK Platform Tools) on the computer, or SideQuest.
2. Connect the headset to a computer with a USB-C cable. In the headset, accept "Allow USB debugging".
3. Install the APK:

   ```bash
   adb devices                      # the headset must be listed as "device"
   adb install -r Immuch360-v<version>-release.apk
   ```

4. In the headset, open the Library, choose the "Unknown sources" filter, and start Immuch360.

### In the window

The whole app runs as a resizable 2D window: login, timeline, albums, search, the photo and video viewers. The gyroscope toggle of the 2D 360° viewer is hidden on the headset, because a window stays fixed in space.

### Immersive view

1. Open a 360° photo or video in the viewer.
2. Press the 360° button. The app switches to an immersive view where the media is all around you, and you look around by turning your head.
3. To go back to the window, press B or Y, or the Back button of the info panel.

| Action | Controllers | Hands |
|---|---|---|
| Back to the app | B or Y | Back button of the info panel |
| Play or pause a video | Trigger, when the info panel is hidden | Play or Pause button of the info panel |
| Show or hide the info panel | A, X, grip or menu | Menu gesture, or pinch when the panel is hidden |
| Turn the image by 90° | Thumbstick left or right | |

Photos show a preview first, then the original, downscaled to at most 8192x4096 (the app's limit). Videos play the file stored on the headset when there is one; otherwise they stream from your server: the original, or the server's transcoded version when the original cannot stream or is too large for the headset.

If the image does not face you the right way when it opens, turn it with the thumbstick until its center is in front of you. The info panel then shows "Image turned to N degrees": please post that number in an [issue](https://github.com/freeKC/Immuch360/issues), with your camera model, so that it can become the default.

### Limitations

- **Video codecs:** the H.264 hardware decoder of the Quest 3 (XR2 Gen 2) tops out around 4096x2304. A 5760x2880 H.264 video (level 6.0, about 200 Mbit/s, the usual Insta360 export) decodes at about 17 fps on the headset, with block artifacts, while the same file plays fine on a phone. The same video in HEVC (H.265) plays well on the headset. When the original is H.264 above that size, the immersive view switches to the server playback stream (the Immich transcode, when there is one), and if that one is still too large the info panel says so for 10 seconds. To give the headset a video it can decode, in Immich go to Administration, Settings, Video Transcoding Settings, and pick one of these:
  - **Every H.264 video re-encoded in HEVC:** set Video codec to HEVC and Target resolution to Original (the default 720p would shrink a 360° video to 1440x720), and keep only HEVC in Accepted video codecs. Every H.264 video of the library is transcoded, not only the 360° ones, and the headset gets HEVC at full resolution.
  - **Only what is larger than 1440p:** keep H.264 in Accepted video codecs, set Transcode policy to "Videos higher than target resolution or not in an accepted format" and Target resolution to 1440p, preferably with Video codec set to HEVC. Anything larger is transcoded and the headset gets 2880x1440. Regular 4K videos are transcoded to 1440p too.

  These settings apply to the whole server, for every user and every app, and re-encoding a large library takes hours of CPU time and extra disk space; the originals are not modified. Browsers without HEVC support (Firefox on most systems, Chrome without hardware HEVC) will not play an HEVC transcode in the Immich web app. The easiest fix for new videos is to export in H.265 from the Insta360 app or Studio. After changing these settings, the existing videos must be transcoded again: Administration, Job Queues (Jobs in older Immich versions), Transcode videos, All.

  The alternative is to re-encode the export in HEVC before uploading it:

  ```bash
  ffmpeg -i VID_360.mp4 -c:v libx265 -crf 20 -preset medium -tag:v hvc1 -c:a copy -movflags +faststart VID_360_hevc.mp4
  exiftool -overwrite_original -tagsFromFile VID_360.mp4 -XMP-GSpherical:all VID_360_hevc.mp4
  exiftool -ProjectionType VID_360_hevc.mp4        # must print: equirectangular
  ```

  `-tag:v hvc1` labels the HEVC track the way Apple devices and browsers expect, `-c:a copy` keeps the audio as it is. ffmpeg drops the 360° tag of the export, the exiftool line copies it back; without it, Immich shows the video as a flat one.
- **Originals that cannot stream:** when the server ignores HTTP Range requests on the original and the MP4 index (moov) is at the end of the file, the whole file would have to download before the first frame, so the app falls back to the server playback stream. A reverse proxy in front of Immich that buffers the responses or strips the Range headers can cause this.
- **Not in the store:** sideloading only.
- **Mono only:** stereo 3D media show both eyes in one sphere.
- **Starting orientation not confirmed yet:** if a photo or video does not face you when it opens, turn it with the thumbstick and report the value (see above).
- **APK size:** the Spatial SDK adds about 56 MB of 64-bit ARM native code, on phones too, where it is never loaded.
- **License:** the immersive view uses the Meta Spatial SDK, distributed under the Meta Platform Technologies SDK License Agreement.

### Logs

The immersive view logs with the tag `Immuch360`:

```bash
adb logcat -c
# reproduce the problem, then
adb logcat -d -v time -s Immuch360
adb logcat -d -v time > quest-full.log      # everything, including crashes and decoder errors (it can contain your server address, check before sharing)
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
- `immuch360`: the changes of this fork on top of Immich. Each release says which Immich version it is based on.

## License and trademark

This project is a fork of Immich and stays under the [GNU AGPL v3](LICENSE). Every APK, the phone ones included, also contains the Meta Spatial SDK, which is not open source (Meta Platform Technologies SDK License Agreement) and is only used on Meta Quest headsets. Immuch360 is not affiliated with, nor endorsed by, the Immich team or FUTO. For the full documentation of Immich itself, see [immich.app](https://immich.app).
