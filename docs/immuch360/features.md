# Immuch360 features, by platform

This page is the full inventory of what Immuch360 does, by category, with the platforms where each item runs and its state on each of them. It was written from the code first, then from the release notes and the test records of the project.

State on 12 October 2026: build 23 (version 3.3.0-rc.0, build number 3030021) for phones, tablets, TVs and headsets, and desktop build 4 for Windows.

## Contents

- [How to read this page](#how-to-read-this-page)
- [1. Media playback](#1-media-playback)
- [2. 3D and spatial](#2-3d-and-spatial)
- [3. Sources and libraries](#3-sources-and-libraries)
- [4. Cameras](#4-cameras)
- [5. Interfaces](#5-interfaces)
- [6. Architecture and quality](#6-architecture-and-quality)
- [7. Where the README differs from the code](#7-where-the-readme-differs-from-the-code)
- [8. What this inventory could not verify](#8-what-this-inventory-could-not-verify)

## How to read this page

### Availability levels

- **Shipped**: in the public builds, and run on a device or on an emulator of that platform.
- **Shipped, not checked on a device**: in the builds, but covered by automated tests only, checked on a computer against a real server, or run on another platform only.
- **Experimental**: shipped behind a setting that says so.
- **Preview**: Immuch360 Desktop on Windows. The whole desktop app is a preview.
- **Builds on CI only**: the code is there and compiles on the project's CI, but the app was never started on that system.
- **Not available**: hidden or not offered on that platform.
- **Planned**: named in the roadmap, no code yet.

### Computer, emulator and device checks

- An Android emulator runs the screens and the logic of the app as a phone does, but it decodes video in software and draws with the computer's GPU. A video or GPU path checked there (the two lens raw videos, for example) shows that the pipeline works, not that the hardware decoders of a phone keep up.
- Some paths were checked on a computer only: the CPU reference stitcher of raw files against real camera files, the DLNA client against minidlna and Gerbera, the Plex client against a real Plex Media Server 1.42.1, the phone share against the headset's own WebDAV client, the Tapo code against a simulated camera. These are "not checked on a device".
- The TV was checked on the Google TV emulator (1920x1080), not on a real TV.
- Devices and systems of the records: a Samsung Galaxy S24+, an iPhone 14 (builds 1 to 3, then TestFlight), the iOS simulator (iPhone and iPad), a Meta Quest 3, the Android phone emulator, the Google TV emulator, and a Windows 11 laptop with an Intel UHD chip and an NVIDIA RTX 4060 Laptop GPU. One user reported Insta360 X4 8K HEVC playback on a Quest 3.

### Builds and stores on 12 October 2026

- **GitHub**: build 23 (`v3.3.0-rc.0-23`) with the universal, per ABI and Quest APKs and the AAB; desktop build 4 as a [pre-release ZIP](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-4).
- **Google Play, phones and tablets**: build 20 live since 7 October 2026; build 23 sent for review on 10 October.
- **Google Play, Android TV**: the TV listing is under Google's review since 9 October.
- **App Store**: version 3.3.0, with the features of build 11, waiting for review since 3 October. TestFlight has build 23.
- **Meta Horizon Store**: public since 7 October 2026 with build 14 ([store page](https://www.meta.com/experiences/immuch360/1384208401440714/)); build 21 in review; build 23 on the Alpha channel.
- **Linux and macOS**: no download.

A store copy can be older than the build described here: check the build number in the app.

### Marks in the tables

- `yes`: inherited from Immich, or there from the first build, and in use.
- `yes (b16)`: shipped from build 16 and run on that kind of device or its emulator.
- `untested (b19)`: in the builds from build 19, with no recorded run on that kind of device.
- `experimental (b5)`: shipped from build 5 behind an experimental setting.
- `preview (d3)`: in Immuch360 Desktop from desktop build 3.
- `CI build only`: compiled by the CI, never started on that system.
- `no`: not offered there. `n/a`: does not apply. `planned`: on the roadmap.

The marks follow the levels above: `yes` is shipped, `untested` is shipped but not checked on a device, `CI build only` is builds on CI only, `no` is not available. "Recorded" means written in the release notes, the README or the project's test journal. In the text, bN is build N and dN is desktop build N.

## 1. Media playback

- **Flat photos.** Immich's photo viewer: swipe, pinch, double tap. Every platform. On a computer (d1) the photos of the chosen folders: JPEG, PNG, GIF, WebP, BMP and ICO are decoded by the app; HEIC, AVIF, TIFF and camera raw files (DNG, CR2, NEF, ARW) show only when Windows has a decoder for them, and otherwise as a tile that names the format (`mobile/lib/desktop/library/local_image_codec.dart`). *(not in the README yet)* On a computer, a local photo is decoded at most 16384 pixels on its long side, as on Android (b22, d4).
- **Flat videos.** Phones and tablets: Immich's native player. A video of a share plays in a native player page of the app through its media bridge (b9), which says "Buffering" while it waits (b11). TV: the same players with the remote (b20). Quest: in the window. Windows (d2): libmpv for every source, with the audio track menu, a resume where a cut video stopped, one decoder reused when swiping, no playlist or stream description of a share ever followed, drawn at most 1440 lines high. iPhone and iPad do not open the MKV and AVI files of a share. Linux and macOS have no video library yet: videos show a placeholder.
- **360° photos as a sphere** (b1). Drag, pinch, double tap, inertia after a quick drag, the initial view of the GPano heading and pitch (as in the Immich web viewer), a sharper picture once zoomed in (the server's full size image), a texture of at most 8192x4096 (4096x2048, without the sharper picture, on a TV that Android calls low RAM). Where: the 360° button of the viewer's top bar; 360° photos carry a 360° badge. Checked on a Galaxy S24+, an iPhone 14 and the Google TV emulator. The TV turns it with the arrows and zooms with the channel keys or the Zoom in and Zoom out buttons (b20); Windows uses the mouse and the keyboard (d1). The Quest opens the immersive view instead.
- **Partial panoramas** (b1). The GPano crop tells which part of the sphere a photo covers: the viewer draws that part only, keeps it mono and hides the 360°/180° button. The headset's immersive view draws a full or a half sphere only: a crop of about half the width and the whole height becomes a half sphere, any other partial panorama is spread over the full sphere (code reading, `mobile/lib/domain/models/sphere_coverage.dart`). *(not in the README yet)*
- **Gyroscope** (b1). Photo viewer: a button at the top right, off by default, "No gyroscope on this device" when there is none. Android 360° video player: always follows the phone. iOS 360° video player: a toggle, on by default. Hidden on a TV and on computers.
- **360° videos** (b1 on Android, b3 on iOS). Native players: Media3 on a spherical surface on Android (drag, sensors, time bar, skip buttons); SceneKit with AVPlayer on iOS (drag, pinch, gyroscope, play and pause, no time bar). The player reads the copy on the device, the file of a share, or the server's original or transcoded stream as the Video source setting says. The viewer's own player stops meanwhile (the Spatial player and the immersive view hand their position back to it, the 360° players of phones do not). TV: the Media3 player, turned with the arrows (b20). Quest: the immersive view (b1). Windows: the app's own 360° player (d3), see [renderer C](#the-windows-360-renderer-renderer-c). No previous or next media in the 360° players of phones (planned).
- **VR180** (b5). A half sphere, the back left black. Recognised from the spherical bounds or mesh of a video, the older Spherical V1 XML, the GPano crop of a photo, or "vr180" or "180" in the name; a stereoscopic VR180 file with square eyes is read as side by side. The 360°/180° button ("360°, full sphere", "180°, half sphere (VR180)") is in the photo viewer, the Android and iOS 360° players, the Spatial player, the Quest panel and the Windows 360° player (d3). The choice is remembered on the device for the media of the library, not for a file of a share. Checked on the Android emulator and a Galaxy S24+ with synthetic media; no device run is recorded for the half sphere of iOS and of the Quest.
- **View as 360°** (b5). Viewer menu ⋮, "View as 360°", between Slideshow and Download, for a 360° file without projection metadata; "Stop treating as 360°" undoes it. Kept on the device, nothing changes on the server; for a file of a share, for that viewing only. On a Quest it opens the immersive view directly.
- **Projection metadata.** Read without downloading the whole file (byte ranges on the server and on the shares): the GPano XMP (projection, crop, initial heading and pitch) at the head or the tail of the file, the server's ProjectionType, the spherical video metadata V1 (XML) and V2 (st3d for the eyes, the bounds or mesh of sv3d for VR180), the Insta360 trailer; else the shape (2:1, square, 1:2, 4:1) and the name (360, pano, vr180, 3d, sbs, ou, tb, the raw extensions). The GPano initial view is used by the photo viewer only: the immersive view and the 360° video players do not read it (code reading). *(not in the README yet)*
- **Raw 360° camera files** (b16, b18). The app stitches the files of 360° cameras itself, with the calibration the camera writes in each file (Mei model of the V3 string first, then V6 for the X5 and X6, then the equidistant V1).
  - Insta360 .insp photos (b16): stitched on the GPU by a Flutter fragment shader before the sphere viewer, up to 8192x4096, with a CPU fallback at a smaller size, levelled with the accelerometer record of the camera. A label says "Raw 360° file, stitched by the app" and where the calibration came from: this file, the same camera (kept by serial number or model), or the nominal X3 values. Windows from d1.
  - Insta360 .insv with both lenses in one track (b16): a Media3 GL effect on Android and the Quest, a SceneKit shader on iOS, renderer C on Windows (d3).
  - Two lenses in two tracks or two files (b18): Insta360 X4, X4 Air, X5 and X6 (one square track per lens); X3 and older at 5.7K and above (two files, `_00_` and `_10_`, the second found next to the first on the device, the server or the share); GoPro MAX and MAX 2 .360 (two tracks of cube faces, the overlap blended); DJI Osmo 360 .osv (two square 10 bit tracks, Kannala-Brandt calibration). Android and the Quest: one decoder per lens, frames paired by time stamp, an OpenGL ES 3 compositor. iOS: an AVFoundation compositor in Metal. Windows: from d5 the fisheye pairs (Insta360 X4 and later, X3 pairs, DJI Osmo 360) play in two libmpv players, one per lens, each decoded by the graphics chip without a copy, 10 bit included, and renderer C draws the two frames of each moment together; both streams stacked in one libmpv core (d3, with the project's libmpv from d4) remain for GoPro .360 files and as the next step when two players do not keep up. 10 bit HLG and PQ sources are tone mapped.
  - When the device cannot run two decoders: one lens with half of the sphere black, then the server's transcoded stream, then the video unstitched, each with its message; software decoders where there is no hardware one, held to 2048x2048 per lens when two run (b19). Windows adds the camera's low resolution LRV copy before the unstitched video (d3).
  - Photos that a 360° camera stitched itself (GoPro .36P, DJI and GoPro JPEGs without GPano tags) count as 360° photos (b18).
  - Not supported: dual fisheye .dng (planned). GoPro and DJI videos are not levelled. No seam optimisation.
  - Checked: .insp photos against Insta360 Studio exports of X3 files, and a single track .insv, on the Android emulator; the two lens paths with the app's CPU reference stitcher on real X4, X3 pair, GoPro MAX and Osmo 360 files, and on the Android emulator with software decoders; on Windows with synthetic clips and real X3 and X4 files. A real DJI Osmo 360 file (two 3840x3840 HEVC Main 10 tracks at 25 frames a second) on 13 October 2026: on an Android 15 emulator from a WebDAV share, listed with the 360° badge but neither thumbnailed nor played, the emulator having no 10 bit HEVC decoder (a synthetic 8 bit clip of the same layout played stitched, both lenses paired); on the Windows test laptop with a CI build of desktop build 5, from a folder of the computer, listed with its date, length and thumbnail, and played in two players on the NVIDIA chip at 25 of 25 frames a second at full size, no frame dropped, every frame of the two lenses drawn together after the first seconds, the seams continuous in a capture taken while it played; the Intel chip was not run in the app, the PC being short of memory (two mpv players outside the app dropped 2 to 3 frames of 300 there). No run on a phone, a Quest or an iPhone is recorded for the two lens paths, and none on an iPhone for any raw file.
- **Zoom and inertia.** Phones: pinch and double tap. TV: channel keys and the Zoom buttons (b20). Windows: wheel, double click, the plus and minus keys on any keyboard layout, Page Up and Page Down in the 360° player (d1, d3). The view keeps turning a little after a quick drag on phones and in the Windows viewers; on a TV the arrows ease to a stop. The immersive view has no zoom: the headset's field of view applies.
- **Audio tracks** (b10). An "Audio track" button in the Android and iOS 360° and Spatial players for a video with two tracks or more; the language chosen is remembered and preferred next time. Windows: in the flat player (d2) and the 360° player (d3). Not in the flat player of phones (planned), and not in the immersive view. *(the immersive view: not in the README yet)*
- **Buffering** (b11). "Buffering NN%" in the Android and iOS 360° and Spatial players, "Buffering" in the share player; the time bar of the immersive view shows how much is buffered (b14); Windows in both players (d2, d3).
- **Video source and decoders** (b15). Before playing an original, the app reads its codec, size and frame rate and asks the decoders of the device; above them, the server's transcoded stream plays with "Playing the transcoded stream: the original (...) exceeds what this device decodes". Settings, Asset Viewer, Videos, "Video source": "The original when this device decodes it" (default), "Always the original", "Always the transcoded stream". H.264 on the Quest 3 is held to the measured 4096x2304. The native players also switch when the original fails. Windows (d3): the Direct3D 11 decoders of the GPU in use, corrected by what the app measured while playing.
- **Video decoders page** (b15, profiles b18, MV-HEVC b19). Settings, Advanced, "Video decoders of this device": codec, hardware or software, largest size, frame rate, profiles, and Copy for a bug report. Windows: from d3, as Direct3D 11 reports them. Linux and macOS have no GPU probe: a static rule answers there.
- **Technical details of a video** (b15, b18). Swipe up in the viewer (the info key on a TV): codec with its profile and codec string, size, frame rate, bit rate, picture (bit depth, SDR, HLG, PQ or Dolby Vision, colour space), "Decodes on this device", and the rows of Apple spatial media (b19).

| Media playback | Android phone and tablet | iPhone and iPad | Android TV and Google TV | Meta Quest | Windows | Linux and macOS |
|---|---|---|---|---|---|---|
| Flat photos | yes | yes | yes (b20) | yes | preview (d1) | CI build only |
| Flat videos | yes | yes | yes (b20) | yes | preview (d2) | no |
| 360° photo sphere | yes (b1) | yes (b1) | yes (b20) | n/a | preview (d1) | CI build only |
| GPano initial view | yes (b1) | yes (b1) | untested (b20) | no | preview (d1) | CI build only |
| Partial panoramas | yes (b1) | yes (b1) | untested (b20) | no | preview (d1) | CI build only |
| Gyroscope | yes (b1) | yes (b1) | no | n/a | no | no |
| 360° videos | yes (b1) | yes (b3) | yes (b20) | yes (b1) | preview (d3) | no |
| Time bar in the 360° player | yes (b1) | no | untested (b20) | yes (b14) | preview (d3) | no |
| Previous and next from a 360° media | planned | planned | no | yes (b14) | no | no |
| VR180 half sphere | yes (b5) | untested (b5) | untested (b20) | untested (b5) | preview (d1) | CI build only |
| View as 360° | yes (b5) | untested (b5) | untested (b20) | yes (b5) | preview (d1) | CI build only |
| Raw .insp photos | yes (b16) | untested (b16) | untested (b20) | untested (b16) | preview (d1) | CI build only |
| Raw .insv, one track | yes (b16) | untested (b16) | untested (b20) | untested (b16) | preview (d3) | no |
| Raw videos, two lenses | untested (b18) | untested (b18) | untested (b20) | untested (b18) | preview (d3) | no |
| Dual fisheye .dng | planned | planned | planned | planned | planned | no |
| Audio track choice | untested (b10) | untested (b10) | untested (b20) | no | preview (d2) | no |
| Buffering indicator | yes (b11) | untested (b11) | untested (b20) | yes (b14) | preview (d2) | no |
| Video source from the decoders | yes (b15) | untested (b15) | untested (b20) | untested (b15) | preview (d3) | no |
| Video decoders page | yes (b15) | untested (b15) | untested (b20) | untested (b15) | preview (d3) | CI build only |
| Video technical details | yes (b18) | untested (b18) | untested (b20) | untested (b18) | preview (d3) | CI build only |

## 2. 3D and spatial

- **3D layouts** (b4). Top and bottom or side by side, read from the st3d box of a video, else guessed from the shape (a square frame is top and bottom, 4:1 is side by side; partial panoramas stay mono). The 3D button cycles "Mono (not 3D)", "3D, top and bottom" and "3D, side by side" in the photo viewer, the Android and iOS 360° players, the Quest panel and the Windows 360° player (d3). A flat screen shows the left eye. The choice is not remembered when the viewer closes; the immersive view remembers the layout corrected on a media while you move through the others (b14). Checked on a Galaxy S24+ and a Quest 3 with real 3D 360° samples (VRTogether, Vuze, Kandao) and a 3D photo.
- **True 3D in the headset** (b4). Each eye gets its own half of the frame: the stereo mode of the skybox for photos, of the equirect layer for videos, on the full or the half sphere. A flat (not 360°) stereoscopic video plays in the window with both eyes visible.
- **Apple spatial photos** (b19). HEIC files (.heic, .heif, .hif) that hold a stereo pair are recognised by reading the head of the file (on the device, the server's original by a byte range, a share), and the answer is kept on the device. On a Quest, "View in 3D" in the top bar opens the photo on a flat frame 2 m in front of you, each eye its own picture, as wide as the camera's field of view (48° when the file does not say), with the disparity adjustment of the file. Thumbstick up and down resize it (30° to 90°, 6° steps), the right thumbstick brings it back in front, the panel's 3D button switches to "2D (left eye)". No previous or next from it yet. Elsewhere: the left eye and a details row ("Apple spatial photo, two views of ..."); a 3D badge in share folders, none on server photos in the timeline (planned). Checked by unit tests and on one sample file; no run of the headset view, nor of real iPhone files, is recorded.
- **Apple spatial videos** (b19). MV-HEVC videos are recognised (a second layer, both eyes declared) and play their base layer, one eye, on every platform, with "Spatial video: this device plays one eye" once per session and a details row (eye, baseline, field of view). The decoders page has an MV-HEVC entry. 3D in the Quest is planned, if its decoders allow it.
- **Spatial 2.5D** (b5, experimental). For stereoscopic videos on Android and iOS phones and tablets: the app estimates depth from the two eyes, follows your head with the front camera and draws the view in between, so that the screen behaves like a window on the scene. Settings, Asset Viewer, Videos, "Spatial 2.5D (experimental)", on by default; then the Spatial button of the viewer (in a share folder on stereoscopic files only, the ⋮ menu for the others). Controls: Audio track; the layout (Auto, Not stereoscopic, Side by side, Top and bottom, each also with the eyes swapped); 360°/180° on a 360° video; Recenter; Head sensitivity; a viewpoint slider from L to R. With Settings, Advanced, Troubleshooting on: an overlay with the frame times, the quality tier and the tracking state, and a "Disparity map" view. The view is drawn at the size of the eye images, at most 1920x1080 (b6), with three quality tiers chosen from the measured frame time. Faces are found by the system (Camera2 and FaceDetector on Android, AVFoundation on iOS); no camera image is stored or sent. Needs OpenGL ES 3.0 or Metal. Not on the Quest (no camera permission) nor on a TV; on Windows the button says it comes later (with the webcam, planned). Checked on a Galaxy S24+ and the Android emulator. On an iPhone, face tracking failed in a TestFlight build of 2 October and a fix followed; no later iPhone report is recorded.
- **Head tracking.** The immersive view follows the head (Meta Spatial SDK, Horizon OS v69 or later); Spatial 2.5D follows the face with the front camera.

| 3D and spatial | Android phone and tablet | iPhone and iPad | Android TV and Google TV | Meta Quest | Windows | Linux and macOS |
|---|---|---|---|---|---|---|
| 3D layouts, one eye shown | yes (b4) | untested (b4) | untested (b20) | n/a | preview (d1) | CI build only |
| True 3D (360° and VR180) | n/a | n/a | n/a | yes (b4) | no | no |
| Head tracked immersive view | n/a | n/a | n/a | yes (b1) | n/a | n/a |
| Apple spatial photos recognised | untested (b19) | untested (b19) | untested (b20) | untested (b19) | preview (d1) | CI build only |
| Apple spatial photos in 3D | no | no | no | untested (b19) | no | no |
| Apple spatial videos, one eye | untested (b19) | untested (b19) | untested (b20) | untested (b19) | preview (d2) | no |
| Apple spatial videos in 3D | no | no | no | planned | no | no |
| Spatial 2.5D | experimental (b5) | experimental (b5) | no | no | planned | no |

## 3. Sources and libraries

### Without a server (b8)

- "Use without a server" on the login page opens the app on the device's own photos and videos, with every viewer, the 360° list, the device albums and the network shares (Plex and Tapo from b20). Search and the server albums are greyed out; the menu says "This device only". A banner asks for the photo permission again when it was refused, with "Allow access" and "Open the settings" (b9). "Connect to a server", in the profile menu and at the top of Settings, runs the usual login.
- The 360° files of the device are found by a scan that reads the GPano or spherical metadata in a 128 KiB window at the head and at the tail of the candidates (a 2:1 shape, or 360, pano, vr180 or a raw extension in the name), a few hundred files per pass, newest first. On an iPhone, files stored only in iCloud are skipped until they are downloaded.
- Quest: the headset's own media, which open in the immersive view too (b8). TV: no media of its own: "This TV has no photos or videos of its own: open a network share from the Library." (b20).
- Computers (d1): "Choose the folders of your photos and videos", Pictures and Videos suggested; nothing is read outside them. Files kept online only by OneDrive are counted, not read, until "Download and include". A drive that comes back under another letter keeps its files (ids from the volume, never from the path). Local folders are watched on Windows; network folders and removable drives are not (Refresh, and a rescan when the window comes back after five minutes or more).
- Limits of b8, not re-checked since: every album of the device shows in the timeline (a hidden albums setting is planned), and immich:// deep links are not handled without a server.

### Immich server: what is kept

- Same server and account as the web app. The package `com.aprogsys.immuch360` installs next to the official app. Based on Immich `main` of 10 October 2026 (3.3.0-rc.0, b22); build 22 was checked against Immich 3.2.4 and 3.3.0-rc.0 servers on the Google TV emulator (login, timeline, albums, 360° photos, videos, the 360° list, an upload, no API error).
- Kept on phones and tablets: login with email and password or OAuth, timeline, albums, search, people, memories (birthday memories from b22), places and the map, favorites, archive, trash, locked folder, shared links, partners, activities, slideshow, editing, stacks, motion photos, Google Cast, foreground and background backup, free up space, server switching by Wi-Fi name, custom proxy headers, client certificates, read only mode, home screen widgets, sharing to the app from other apps, and on Android opening a file from another app.
- Two changes (b15): the "Force original video" switch became the Video source choice, and the device files uploaded by hand from an album count as backed up.
- TV (b20): a viewer. Share, upload, edit, add to an album, delete, multi select, Cast, the map, the gyroscope and the backup button are hidden. OAuth is replaced by "Signing in with (provider) opens a web page, which this TV cannot do. Sign in with an email and a password instead." Links show their address under "Open on another device".
- Quest: the whole app in a 2D window. No location permission, so no server switching by Wi-Fi name. The Quest build allows plain HTTP only to the headset itself and to home network names (.local, .lan, .home, .internal, .home.arpa) (b8).
- Computers (d1): timeline, albums, people, memories, search and full size photos; backup of the chosen folders while the app is open, closing asks first while uploads run; downloads into a folder you choose; "Delete from device" is not offered and Delete removes the server copy only. No map, OAuth, Cast, notifications, free up space or background backup. Client certificates are imported from a PKCS#12 file; the certificate authority of your own server is added as a PEM file (Settings, This computer). On Windows the share action opens the Windows share dialog; "Save to a folder" replaces it on Linux only (`mobile/lib/repositories/asset_media.repository.dart`). *(README outdated: it lists "Save to a folder" among the Windows features)*

### The 360° list (b1, filters b18, shares row b22)

- Library tab, 360° (next to Favorites with a server). With a server: the media the server flags as 360°, the raw Insta360 files by their name, the photos a 360° camera stitched itself, the ones you view as 360°, and what the device scan found; each once, newest first. Without a server: the device scan and the ones you view as 360°.
- Filters with counts: Date (All, a year, its months, Custom); where ("On the server", "On this device", or "On this computer", and "Shared with me"); Photos, Videos, 3D, VR180; the cameras, from the EXIF make and model, a raw file named after the brand of its extension, else "Unknown camera". Chips of one group add up, groups narrow the list. The Quest's previous and next follow the filtered list.
- "In the network shares" (b22): a row with the 360° files of the shares, learned when their folder is shown or a file is opened, kept from one start to the next, forgotten with the share. On a TV it is where the list fills. TV layout: a compact header and six whole tiles per row (b22).

### Network shares: SMB, WebDAV and DLNA

- **Where**: Library tab, Network shares, then + and "A network share (NAS, computer, media server)" (b20 asks which of three to add).
- **SMB** (b9): SMB 2 and 3, a vendored dart_smb2 0.1.3 that sends a user name with an empty password (a Freebox Server wants that), "Choose a share" lists the shares of the server. Large block reads, the file kept open, 16 MB read ahead, a second connection kept for the video being played (b10), up to six parallel connections for that video (b11; 4.5 MB/s to 19 MB/s on a Freebox Server, checked on a Galaxy S24+). No SMB 1.
- **WebDAV** (b9): Basic authentication, "Secure connection (HTTPS)"; a self signed certificate must be installed on the device (on a computer, added as a PEM file). Digest authentication is planned.
- **DLNA and UPnP** (b19): SSDP to the multicast group and to every address of the local /24 network, or the description address typed by hand; the ContentDirectory browsed page by page, files named by their titles, audio left out, album art as thumbnails, the original preferred to a converted copy, 20,000 entries per folder at most. On iPhone and iPad the unicast sweep only, until Apple grants the multicast entitlement. Checked against minidlna and Gerbera from a computer.
- **Finding servers** (b9, b19, b20): Bonjour (mDNS) and a scan of the local /24 network confirmed by a real SMB or WebDAV exchange, SSDP, GDM for Plex, the TP-Link discovery for cameras; listed under "Found on the network" in about six seconds, with "Scan again". A full address (`smb://nas/photos`, `\\nas\photos`, `https://nas:5006/photos`) fills the form. iOS asks for the local network permission. Computers (d1): mDNS through the DNS-SD functions of Windows, and a choice of network adapter (Settings, This computer).
- **Browse and play** (b9, b10): folders first, then a grid with thumbnails (a photo is decoded whole, none above 30 MB; a frame at 1 s for a video, two at a time, cached on the device up to 200 MB), the 360° badge, a 3D badge on Apple spatial media (b19), pull to refresh. Photo page: pinch, double tap, 360°. Video page: the native player with 360°, 3D, 360°/180° and on phones Spatial. "View as 360°" in the ⋮ menu. Previous and next file of the folder with the keys of a remote, a keyboard or a game pad (b20), and on a computer with the chevrons of the photo page (d1); no touch swipe yet (planned).
- **Media bridge** (b9): a server inside the app on the loopback address, with a random token per session and byte ranges, so that players seek and nothing is copied; the players and the headset never get the address of the share. On a computer the server's videos go through it too (d2), so libmpv never holds the session token.
- **A share that moved** (b19): a DLNA share or a phone share keeps the id its server announces; "Looking for (name) on the network", then a DLNA share moves at once and a share with a password asks "Use the new address?". A Plex server moves at once, since its certificate proves it is the same server (b20).
- **Passwords** stay in the Android Keystore or the iOS Keychain (on Windows, the data protection of Windows); the share list stays on the device. A form that was typed in asks "Discard the changes?" before it closes (b22).
- **Upload to Immich** (b15): long press or Select, tick files or "Select every photo and video of this folder", "Upload to Immich"; streamed from the share to the server one at a time, without a copy on the device, with the progress on each tile, "Sending 3 of 12" and Cancel. The server deduplicates; files sent before are marked "Sent to Immich earlier" and skipped (a record per server and account). The open file has the same entry in its menu. Plex files and Tapo clips too (b20). In the foreground only; not on a TV.

### Plex Media Server, without plex.tv (b20)

- Library tab, Network shares, + and "A Plex Media Server". The server is found with GDM and a unicast sweep, or typed; "Look up" checks its plex.direct certificate before anything is sent.
- The token is pasted once (the whole "View XML" address or the token alone, "Paste from the clipboard"), kept in the secure storage of the device and sent only in a request header to that server. A refused token offers "Paste a new token"; an end date is shown.
- Libraries: photos, movies and other videos, TV shows (music left out), by folder as on the disk (a photo library without a folder view shows its albums), with Plex's thumbnails; the original files play through the media bridge, so 360° and 3D metadata stay intact.
- Away from home: the address at home first, the address outside home 400 ms later (the one the server tells, or the one you type, which wins); a globe icon says "Connected through the address outside home". No relay. IPv4 only, claimed servers only, 20,000 entries per folder.
- Checked from a computer against a real Plex Media Server 1.42.1; no playback on a device is recorded.

### Share this phone, share this computer (b19, d1)

- Library tab, Network shares, first tile "Share this phone on the network": a read only WebDAV server on port 8360 (or a free one), user `phone` and four digits, an eight character password, copy buttons, "New password", the devices connected in the last minute and the last file served. Folders `Albums`, `By month` and `360`; on an iPhone a live photo gives its still, an edited photo its edited version, iCloud only files are left out.
- Android: a foreground service with a notification and Stop, the Wi-Fi and the processor kept awake, so it runs with the screen off. iPhone and iPad: only while the app is in front, the screen kept awake. It stops after 60 minutes without a request and when the app closes, and never starts by itself. It listens on the Wi-Fi, Ethernet and hotspot addresses only, answers local addresses only, asks the user name and password (HTTP Basic, over plain HTTP), and blocks a device for a minute after ten wrong passwords.
- Not on the Quest, which reads the share instead, nor on a TV. The Android side ran on the emulator with a client reading a video (the demonstration video of b19); a phone serving a Quest, and the iPhone side, have no recorded run.
- Computers (d1): "Share this computer on the network", the same server on the folder library, announced through Windows DNS-SD on the network it serves. It does not start on a network Windows marks as public unless you choose "Share for this session", and says that the Windows firewall may ask. Windows only: macOS and Linux have no share (`computerShareAvailable`, `mobile/lib/desktop/network/computer_share.dart`). *(not in the README yet)*

| Sources and libraries | Android phone and tablet | iPhone and iPad | Android TV and Google TV | Meta Quest | Windows | Linux and macOS |
|---|---|---|---|---|---|---|
| Use without a server | yes (b8) | untested (b8) | yes (b20) | yes (b8) | preview (d1) | CI build only |
| Immich timeline and albums | yes | yes | yes (b20) | yes | preview (d1) | CI build only |
| Search, people, memories | yes | yes | untested (b20) | untested | preview (d1) | CI build only |
| Backup and uploads | yes | yes | no | untested | preview (d1) | CI build only |
| Sharing, editing, deleting | yes | yes | no | untested | preview (d1) | CI build only |
| Map and places | yes | yes | no | untested | no | no |
| OAuth sign in | yes | yes | no | untested | no | no |
| Google Cast | yes | yes | no | untested | no | no |
| 360° list | yes (b1) | yes (b1) | yes (b20) | untested (b1) | preview (d1) | CI build only |
| 360° list filters | yes (b18) | untested (b18) | yes (b22) | untested (b18) | preview (d1) | CI build only |
| SMB shares | yes (b9) | untested (b9) | yes (b20) | yes (b9) | preview (d1) | CI build only |
| WebDAV shares | yes (b9) | untested (b9) | untested (b20) | untested (b9) | preview (d1) | CI build only |
| DLNA media servers | untested (b19) | untested (b19) | untested (b20) | untested (b19) | preview (d1) | CI build only |
| Plex Media Server | untested (b20) | untested (b20) | untested (b20) | untested (b20) | preview (d1) | CI build only |
| Upload from a share or an album | yes (b15) | untested (b15) | no | untested (b15) | preview (d1) | CI build only |
| Share this device on the network | yes (b19) | untested (b19) | no | no | preview (d1) | no |

## 4. Cameras

- **Tapo cameras** (b20). Library tab, Network shares, + and "A Tapo camera". Found by the TP-Link discovery protocol and by their RTSP port confirmed by their certificate. In the Tapo app first: a camera account (Advanced Settings, Camera Account) and Third-Party Compatibility (Me, Tapo Lab). "Test the camera" reports the model, the firmware, the memory card, the live video and sound.
- **Live view** (b20) with the camera account: Android phones and tablets, Android TV and the Quest (in the window, in HD) through the Media3 RTSP player; SD on the page, HD in full screen, the sound off at first. Windows (d3): libmpv over RTSP in TCP, a lost stream tried again for about a minute and a half with the last picture kept, a refused account not tried again. iPhone and iPad: "The live view comes to iPhone and iPad in a later version." (planned).
- **Recordings** (b20) with the TP-Link account password, on every platform: the days with recordings by month, the clips of a day under the hours of the camera with their kind (Motion, Person, Pet, Vehicle, Baby crying, Animal, Continuous, Event) and the camera's thumbnail for an event. A clip is fetched with its progress and Cancel, turned into an H.264 video with its sound, played with seeking, marked "On this device", kept in a cache of 1 GB at most for all cameras (least recently played first out), and sent to Immich from its menu (not on a TV). H.265 recordings are refused with a message. One download at a time per camera; a camera busy with the Tapo app is asked again after 4, 8 and 12 seconds. Windows: the list and fetching from d1, playback from d2.
- **Safety**: the local network only, never the servers of TP-Link, read requests only, the camera's certificate pinned, a camera found again by its MAC address with the same certificate, a refused password never sent again by itself, the passwords in secure storage and never in the logs.
- **Not supported**: battery cameras, cameras behind a hub, access away from home.
- **Checked**: the protocol follows captures of a C510W with firmware 1.3.4 and was checked against a simulated camera; the Windows live view against a test RTSP server that signs in as the cameras do (Digest). No run with a real camera is recorded.

| Cameras | Android phone and tablet | iPhone and iPad | Android TV and Google TV | Meta Quest | Windows | Linux and macOS |
|---|---|---|---|---|---|---|
| Tapo live view | untested (b20) | planned | untested (b20) | untested (b20) | preview (d3) | no |
| Tapo recordings | untested (b20) | untested (b20) | untested (b20) | untested (b20) | preview (d2) | CI build only |
| Tapo clip sent to Immich | untested (b20) | untested (b20) | no | untested (b20) | preview (d2) | CI build only |

## 5. Interfaces

- **Touch** on phones and tablets: drag, pinch, double tap, long press to select.
- **TV remote** (b20, fixes b22 and b23): a focus frame moved by the arrows, OK opens, Back goes from a tab to the side menu, then to Photos, then out of the app; channel keys scroll a page; text fields open the keyboard of the TV in a dialog ("Press OK to type"). Viewers: OK pauses a video; left and right jump 10 seconds while it plays and go to the previous or next item while it is paused; the arrows turn a 360° photo (faster while held) and a 360° video; the channel keys zoom a 360° photo; media keys work; the info key shows the details. Layout: about six tiles per row inside the screen margins, thumbnails asked at twice the size of their tile and the server's preview size (b23), the focus frame above the label of a text field (b23), the panes of Settings inside the margins (b23), a first item focused on each page (b22), radio buttons that OK picks (b22).
- **Remote control layout** (b20): Settings, Preferences, "Remote control layout": Automatic (on on Android TV and Google TV), On (a tablet driven by a keyboard or a game pad), Off. Android only; it stays on Automatic, so off, on the Quest. A change applies to the open page at once (b22).
- **Keyboard and game pad** (b20): the arrows, OK and the media keys work in the viewers on any Android device, whatever the setting.
- **Quest controllers and hands** (b1, b14, b16, b17): B or Y back to the window; A, X, the grip or the menu show the info panel; the trigger plays or pauses while the panel is hidden; the left thumbstick goes to the previous or next media; up and down seek 10 seconds in a video and turn a photo by 90°; the right thumbstick turns the view by 30° per push and keeps turning while held; a one line overlay shows the time, the angle or the title for about 1.5 s. Hands: the panel's buttons and time bar, the menu gesture. Previous and next look at most 400 media ahead in a timeline and 50 files in a share folder, for 12 seconds at most; back in the app, the viewer lands on the media last shown, and a video resumes where the immersive view stopped (b14).
- **Mouse and keyboard on a computer** (d1 to d3). Photos: drag, wheel, double click, the plus and minus keys, arrows, F or F11 for full screen, Escape, Home and End, I for the details; chevrons at the edges while the mouse moves. Flat videos: Enter or the play key, left and right or J and L for 10 seconds, the arrows to the previous or next video while paused. 360° player: drag (with inertia), wheel, the plus and minus keys, Page Up and Page Down, arrows, Space, J and L, Home, M for the sound, F, F11 or a double click for full screen, Escape, Tab between the controls, which hide with the cursor after 3 seconds of play. Letters typed in the description field stay in the text.
- **The computer window** (d1): one copy runs per user. A second start, or a file opened with the program ("Open with", a file dropped on `immuch360.exe`, a path on the command line), hands the files to the running window, which opens them in the viewer (`mobile/lib/desktop/platform/desktop_view_intent_api.dart`, `mobile/windows/runner/main.cpp`). *(not in the README yet)* Closing asks first while uploads run or the computer is shared. The Logs page has "Save logs to a file", with the reports of the last crashes (small minidumps) when there are some.

| Interfaces | Android phone and tablet | iPhone and iPad | Android TV and Google TV | Meta Quest | Windows | Linux and macOS |
|---|---|---|---|---|---|---|
| Touch | yes | yes | n/a | n/a | n/a | n/a |
| TV remote | n/a | n/a | yes (b20) | n/a | n/a | n/a |
| Remote control layout setting | untested (b20) | no | yes (b20) | n/a | no | no |
| Keyboard and game pad in viewers | untested (b20) | untested | yes (b20) | n/a | preview (d1) | CI build only |
| Controllers and hands | n/a | n/a | n/a | yes (b1) | n/a | n/a |
| Mouse, keys and window | n/a | n/a | n/a | n/a | preview (d1) | CI build only |

## 6. Architecture and quality

- **Flutter and native modules.** One Flutter app (Dart) for every platform. The fork's native parts are reached through Pigeon interfaces: the 360° video player, the Spatial player, the immersive view, the phone share, the TV detection, the video decoders, the video thumbnails and the camera live view. On computers each of these interfaces has a Dart implementation of its own (`mobile/lib/desktop/platform/`), and a CI gate checks that none is missing.
  - Android (Kotlin): Media3 (ExoPlayer) players, OpenGL ES 3 stitching and compositing, Camera2 for the Spatial player, a foreground service for the phone share.
  - Quest: the same APK with the Meta Spatial SDK (Horizon OS v69 or later) for the immersive activity; about 56 MB of 64 bit ARM code, in the phone APKs too, where it is never loaded.
  - iOS (Swift): SceneKit and AVPlayer for 360° video, Metal for the Spatial player and the two lens compositor, AVFoundation for faces and decoders.
  - Windows (C++): a patched media_kit_video plugin with renderer C (below) over ANGLE (OpenGL ES on Direct3D 11), `immuch_desktop_video` for the Direct3D 11 decoder probe, a runner with one instance per user and crash dumps.
  - Vendored packages: dart_smb2 (the empty password), background_downloader (its "trust every certificate" code replaced, b8), media_kit (without its web asset, with a COM reference fix), flutter_secure_storage_windows (the data protection of Windows without the ATL component).
  - From b22, Immich's native core in Rust (thumbhash, raw photo rotation, 10 bit conversion); computers keep a Dart thumbhash decoder.
- **Codecs and decoders.** Phones, tablets, TVs and the Quest play what their decoders take, hardware first; the app checks before playing (b15) and lists them (Settings, Advanced). Two lens raw videos ask for two decoders at once; a software decoder is held to 2048x2048 per lens (b19). Windows: libmpv with FFmpeg decodes in software what the GPU refuses (H.264 above 4096 pixels wide, for example) and uses Direct3D 11 decoding for the rest.
- **GPU rendering.** The photo sphere is a textured mesh drawn by Flutter; .insp photos are stitched by a Flutter fragment shader; 360° videos are drawn by Media3's spherical surface, SceneKit, the Spatial SDK layers or renderer C; Spatial 2.5D synthesises its view on the GPU (OpenGL ES 3 or Metal).
- **Direct playback of originals.** Server originals play when the device decodes them (Video source); shares and Plex give their original files through the media bridge, so the 360°, 3D and VR180 metadata reach the players. The server's transcoded stream is the fallback; when the server ignores byte ranges and the MP4 index sits at the end of the file, the app takes the transcoded stream.
- **Fisheye stitching.** The calibration of the file (lens model, centres, orientations, canvas size); Mei, equidistant and Kannala-Brandt models; the cube faces of GoPro EAC tracks; levelling from the camera's accelerometer record, averaged, once per video, not stabilised. The Windows pass takes the uniforms that the Android stitch computes, so that both draw the same picture.
- **Large files.** Photos are capped at 8192x4096 for the sphere (the usual GPU limit); share thumbnails skip photos above 30 MB; SMB reads in blocks with read ahead and parallel connections; videos seek through byte ranges. Windows: a pool of players bounds the libmpv instances (a demuxer cache of up to 256 MiB each) and reuses them; flat videos and the 360° view are drawn at most 1440 lines high; on the test laptop, 8K HEVC and 5.7K H.264 played with no dropped frame on the RTX 4060 (d2, d3).
- **Network and on demand reading.** Nothing is copied to play a file of a share, a Plex server or the server: only the bytes the player asks for are read. The exception is a Tapo recording, which is fetched whole before it plays.
- **Metadata preservation.** The app writes nothing to a share (read only) and nothing to the server for the 360°, 3D or 180° choices, which stay on the device. An upload sends the file's own bytes, so the server receives the original with its metadata. A Tapo clip is a new MP4 file made from the camera's stream.
- **Local processing and privacy.** Stitching, depth, face tracking, the 360° detection and the TV detection run on the device. No analytics, no advertising, no crash reporting service of the developer. On a computer, a file's id is an HMAC of its path with a secret of the installation, so no path reaches the server; libmpv never gets a token, a cookie or the server's address, opens no reference a file contains, and gets each address in memory, never in a temporary file; tokens, passwords and the camera account are removed from the logs.
- **Platform optimisations.** The Quest flavour: 64 bit only, target SDK 34, only the photos, videos and notifications permissions, the plain HTTP policy, the supported devices listed (Quest 2, Pro, 3, 3S from b21). The phone builds drop the desktop code at compile time (constants of the compiler), and CI gates check the APK sizes, the plugin lists and that nothing changed under `mobile/android` and `mobile/ios` for the desktop work. TVs: low RAM caps and larger thumbnails. Spatial 2.5D: quality tiers. Windows: the player pool and the renderer tiers.
- **Builds.** GitHub Actions builds the Android APKs and AAB (`immuch360-release.yml`), the Windows ZIP with the desktop tests, the Linux build and the macOS compile (`immuch360-desktop.yml`), and libmpv for Windows x64 and arm64 (`immuch360-libmpv.yml`). Codemagic builds iOS for TestFlight and runs simulator checks (`codemagic.yaml`). Only x64 Windows ZIPs are made.
- **Languages.** English and 88 translations for every text of the phone, tablet, TV and headset app; the texts that only Immuch360 Desktop shows are in English for now.
- **Logs.** `adb logcat` tags of the native code: `Immuch360`, `VideoDecoders`, `DualFisheyeEffect`, `TwoLensPlayer`, `TwoLensCompositor`, `LensVideoRenderer`, `PhoneShareService`, `PhoneShareApi`, and also `SphericalVideoActivity`, `SpatialVideoActivity`, `SpatialHeadTracker`, `RawProjection`, `VideoDecoderApi`, `SphericalVideoApi` and `SpatialVideoApi`. *(the last seven: not in the README yet)* The app's own log (Logs, in the profile menu) has the Dart tags.

### The Windows 360° renderer (renderer C)

Renderer C draws the 360° view on Windows from desktop build 3. It is written in C++ and GLSL ES 3.00 inside the project's patched media_kit_video Windows plugin (`mobile/packages/media_kit_video/windows/projection_renderer.cc`, `projection_shaders.h`), on top of libmpv, with a Dart layer in `mobile/lib/desktop/video/`. From desktop build 4 the ZIP carries the project's own 2026 build of libmpv, which stacks the two lenses of raw files and lets the decoded frames reach the renderer without a copy back to memory.

- **Two steps per frame.** libmpv decodes each frame and draws it, as for a flat video, into an intermediate RGBA 8 bit texture of the video's size, capped by a tier: full size, at most 4096 wide, or at most 2880 wide. mpv tone maps HDR before that step. Then one fragment pass of the plugin, over a single triangle covering the output, turns each output pixel into a ray of the view (yaw, pitch, vertical field of view), finds where that ray meets the sphere, and reads the frame there.
- **Three projections.** An equirectangular frame: mono, or one eye of a top and bottom or side by side frame, over the whole sphere or its front half for VR180, black outside. A pair of fisheye lenses (Mei, equidistant or Kannala-Brandt, with the calibration of the file): .insv, X3 pairs, .osv. The two cube face tracks of a GoPro .360 (EAC).
- **Filtering.** Bilinear while the view moves; a Catmull-Rom bicubic filter (nine bilinear reads) once it rests; four reads per pixel when the view shrinks the frame (above 1.25 texels per pixel), against shimmer.
- **The view.** It is drawn into the texture Flutter already shows, at most 1440 lines high, then scaled to the window. Turning the view changes uniforms of the pass only, at most once per Flutter frame: mpv's own passes are never rebuilt during a drag, and a paused video is redrawn from the kept texture without mpv. Five pixels of each new view (the centre and the middle of each edge) are read back to check that the pass draws.
- **The Dart layer.** It starts at the tier of the GPU kind (full on a dedicated GPU, 2880 wide on one built into the processor, as Windows reports it), measures the first seconds of each video (frames drawn against the video's frame rate, draw time, process memory while dragging), then keeps the tier, goes one tier down, or falls back to the flat player with a message. A video limited by its decoding rather than its drawing switches to the server's transcoded stream instead. Verdicts are kept per GPU, app version and kind of video (codec, size, frame rate, decoding path) in `desktop_video_renderer.json`, in the app's support folder.
- **Raw files with two streams.** From desktop build 5 a fisheye pair plays in two libmpv players, one per lens, each decoded by the GPU without a copy: their OpenGL ES contexts share their textures, and the first player draws the view from both frames of the same time, waiting a few milliseconds for the later one and moving the second player's speed by up to 20% until its frames come with the first one's (the plugin's patch 7). Otherwise one libmpv core decodes both streams and stacks them side by side with FFmpeg's hstack filter, which pairs the frames by time stamp, and renderer C stitches the stacked frame; stacking needs frames in memory (software decoding or a Direct3D 11 copy back). Each way is measured and kept per GPU and kind of video, and a way found too slow is tried again after 14 days.
- **Settings.** Settings, Advanced, with Troubleshooting on: "360° video renderer" (Automatic, Plugin full size, at most 4096 wide, at most 2880 wide, Flat without the 360° view) and "Measured last". Picking Automatic forgets the measures.
- **Why.** The first design passed the view to an mpv user shader. Each view change rebuilt mpv's passes, kept 40 to 200 MB of GPU memory per change on an RTX 4060 until the PC ran out of memory, and gave 11 frames a second on an Intel UHD (measures of 9 October 2026). The full design notes: [the desktop 360° video renderer](desktop-360-video-renderer.md).

| Architecture and quality | Android phone and tablet | iPhone and iPad | Android TV and Google TV | Meta Quest | Windows | Linux and macOS |
|---|---|---|---|---|---|---|
| Hardware video decoding | yes | yes | untested (b20) | yes | preview (d2) | no |
| GPU drawing of 360° video | yes (b1) | yes (b3) | yes (b20) | yes (b1) | preview (d3) | no |
| GPU stitching of raw files | yes (b16) | untested (b16) | untested (b20) | untested (b16) | preview (d3) | no |
| Play from shares, nothing copied | yes (b9) | untested (b9) | yes (b20) | yes (b9) | preview (d2) | no |
| Parallel SMB reads | yes (b11) | untested (b11) | untested (b20) | untested (b11) | preview (d1) | CI build only |
| Measured renderer tiers | n/a | n/a | n/a | n/a | preview (d3) | no |
| Project's own libmpv | n/a | n/a | n/a | n/a | preview (d4) | no |

## 7. Where the README differs from the code

Statements of the README of 12 October 2026 that the code or the records contradict, and features it does not describe yet.

- **TV checks** (Watch on your TV, Limits; the status of each line; Formats and sources; Roadmap): the README says the TV support was checked by automated tests only and never ran on a TV emulator. *(README outdated: builds 21 and 22 ran on the Google TV emulator: login, timeline, albums, flat photos and videos, the 360° sphere and video player, the 360° list, an SMB share, the add menu and the share form, Settings and the remote navigation fixes. Still not on a real TV.)*
- **libmpv of the Windows ZIP** (360° videos and the graphics chip; Build it yourself on Windows; Roadmap): the README still points to the limits of media-kit's 2024 libmpv and says the ZIPs carry it until the project's build is switched on. *(README outdated: from desktop build 4 the project's 2026 libmpv is the default, `mobile/packages/media_kit_libs_windows_video/windows/CMakeLists.txt`.)*
- **Linux and macOS** (On a Windows computer, Not there yet): "they have not been built or tried on those systems yet". *(README outdated: the CI builds the Linux app and compiles the macOS app at each desktop build; neither has been started, and there is no video library nor download for them.)*
- **Save to a folder** (What the preview does): listed as a Windows feature. *(README outdated: on Windows the share action opens the Windows share dialog; "Save to a folder" replaces the share sheet on Linux only.)*
- **The 360° player on a computer** (Known problems): "the 360° player works on the whole frame instead". *(README outdated in part: it reads the whole frame, or its tier, but draws the view at most 1440 lines high, as for flat videos.)*
- **Google Play in the Roadmap**: it says build 20 is live and that build 21 changes nothing on phones and tablets. *(README outdated: build 23 was sent for review on 10 October, as the table at the top of the README says.)*
- **Desktop build numbers**: the install steps say "To replace desktop build 2" and the checksum example names the desktop build 3 ZIP; the test counts quoted are those of desktop build 3. *(README outdated.)*
- **Spatial 2.5D on a TV**: the README says it is hidden on a TV. The button is hidden; the setting still shows in Settings, Asset Viewer, Videos (`mobile/lib/widgets/settings/asset_viewer_settings/video_viewer_settings.dart`). On Windows the button and the setting show, and the button says it comes later.
- **The caption of the 360° video picture** names previous and next buttons; they are the default buttons of the Media3 controller, and the player has no previous or next media, as the README's own limits say.
- **Not in the README yet**: HEIC, AVIF, TIFF and camera raw photos in the folders of a computer; files opened with the program on Windows; the computer share being Windows only; partial panoramas in the headset; the GPano initial view used by the photo viewer only; no audio track choice in the immersive view; seven log tags of the native players.

## 8. What this inventory could not verify

- **iPhone and iPad**: no recorded run on an iPhone or an iPad after build 3, apart from the iOS simulator (login, a 360° photo, the iPad screens of the 360° list and the sphere) and the TestFlight builds. The left eye of 3D files, the VR180 half sphere in SceneKit, every raw file, the shares (SMB, WebDAV, DLNA, Plex), the phone share server, uploads, audio tracks, the decoders page and Spatial 2.5D after the face tracking fix of 2 October have no recorded iPhone run. Whether the keys of a keyboard or a game pad work in the iOS viewers is not stated anywhere.
- **TV**: the journal of 11 October says the TV fixes of build 23 (thumbnail size, the focus frame above labels, the margins of Settings) were checked by automated tests, and only the bottom margin fix of the Photos tab was seen on the emulator. Still to confirm on a real TV: the direction in which the arrows turn a 360° video, the TV keyboard in the text dialog, the OK key of infrared remotes, the banner on the home screen (the Google TV emulator without an account shows no banners), what the TV decoders play. Whether the Backup section of Settings, still listed on a TV, does anything there was not checked.
- **Quest**: the owner reported "it works" on the headset with build 16 after a test list that included a raw video in the immersive view; the record does not say which file. No recorded headset run for the VR180 half sphere, two lens raw videos, WebDAV, DLNA, a phone share, Plex, the Tapo live view in HD, Apple spatial photos in 3D, the Video source switch of build 15, nor the inherited map, Cast, backup and OAuth in the window. The Quest 2 and the Quest Pro have never run the app. Whether the plain HTTP policy of the Quest build leaves DLNA and phone shares untouched on the headset is still to be confirmed, as the README says.
- **Android phones**: no recorded device run of the two lens raw videos, DLNA, Plex, audio track choice, Apple spatial detection, or Tapo. The Remote control layout set to On on a tablet has no recorded run.
- **Tapo**: no real camera, and no model other than the C510W with firmware 1.3.4 behind the protocol.
- **Windows**: by hand, desktop build 4 was started, played a local 1080p video and closed cleanly; its 360° player with the project's libmpv is covered by automated tests. A CI build of the two players played a real DJI Osmo 360 file on the test laptop (13 October 2026). Other real camera files (360°, 3D, VR180), two screens, sleep and resume and a real Tapo camera are not checked by hand. Which HEIC and camera raw photos show depends on the codecs installed in Windows. The inherited locked folder, editing, partners and shared links have no recorded desktop run. There is no Windows on ARM build.
- **Linux and macOS**: never started. No video library, no computer share, no GPU decoder probe; the single instance and file hand over of the Windows runner are not written for them.
- **Inherited Immich features**: they are counted as kept from the code (routes, actions, settings) and from the server checks of build 22, not checked one by one on each platform.
- **Store states**: taken from the README and the project's records of 12 October 2026, not from the stores themselves.
