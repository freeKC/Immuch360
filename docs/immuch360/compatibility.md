# Compatibility

What Immuch360 reads and plays on each platform, how it compares with the Immich app and other apps, what it was checked on, and its limits.

Back to the [README](../../README.md)

## Formats and sources, by platform

Immuch360 is a gallery, and it is also a free media player: it plays what the official app cannot, from the sources of the second list, in the player that fits the file.

- **Flat videos (MP4, MOV, MKV, what the device decodes)**
  - Android phones: Immich player, and a native player for network shares.
  - iPhone, iPad: same, except the MKV and AVI files of a share, which iOS does not open (on a server they play transcoded).
  - Meta Quest: in the window.
  - Android TV, Google TV: as on phones; from build 27 Left and Right go to the previous or next item, also while a video plays, OK shows the controls and a second OK pauses, the rewind and fast forward keys and the buttons of the controls jump 10 s, and a video that cannot play says why.
  - LG webOS TVs (the webOS app): the server's stream, played by the TV; Left and Right go to the previous or next item, the controls hide 5 s after the last key, and a video the TV cannot play gets a message.
  - Windows (from desktop build 2): the libmpv player, from every source of the second list; Enter pauses, left and right or J and L jump 10 s.
  - Linux (from desktop build 6): the same player with the libmpv of the system, drawn by the graphics chip, on X11 sessions too from desktop build 7; on Fedora, camera videos need the FFmpeg of RPM Fusion.
  - macOS (from desktop build 6): the same player with the project's libmpv inside the app; run on the CI's Mac only.
- **360° photos**
  - Android phones: sphere viewer, gyroscope.
  - iPhone, iPad: same.
  - Meta Quest: immersive, all around you.
  - Android TV, Google TV: sphere viewer turned with the arrows, zoomed with the channel keys.
  - LG webOS TVs: a WebGL sphere turned with the arrows, zoomed with the channel keys; "View as 360°" for 2:1 photos without tags.
  - Windows: sphere viewer, mouse and keyboard.
  - Linux: the same (desktop preview); macOS: the same code, never run on a Mac.
- **360° videos**
  - Android phones: native Media3 player on a sphere, gyroscope, seeking, audio track choice, buffering indicator.
  - iPhone, iPad: native SceneKit player on a sphere, gyroscope, audio track choice, buffering indicator; play and pause, no time bar yet.
  - Meta Quest: immersive, true 3D for stereoscopic files, time bar with 10 second skips, previous and next media.
  - Android TV, Google TV: the Media3 player of phones, turned with the arrows; from build 27 a video beyond the decoders of the TV asks first, and the player names the cause when it cannot play it.
  - LG webOS TVs: played flat for now, with a message.
  - Windows (from desktop build 3): the app's own 360° player (libmpv), turned with the mouse or the arrows, zoomed with the wheel, seeking, audio track choice, buffering indicator; smooth on a dedicated graphics chip, at most 2880 pixels wide and slower for 5.7K H.264 on an integrated one.
  - Linux and macOS (from desktop build 6): played flat, with a message; the 360° player is Windows only for now.
- **3D 360° (top and bottom, side by side)**
  - Android phones: left eye, layout button.
  - iPhone, iPad: same.
  - Meta Quest: each eye gets its own half of the frame.
  - Android TV, Google TV: left eye, layout button.
  - LG webOS TVs: photos, left eye, 3D button.
  - Windows: photos as on phones; videos from desktop build 3, left eye, layout button, smooth on a dedicated graphics chip, with limits on an integrated one.
- **VR180 (half sphere) photos and videos**
  - Android phones: half sphere, 360°/180° button.
  - iPhone, iPad: same.
  - Meta Quest: immersive half sphere.
  - Android TV, Google TV: half sphere, 360°/180° button.
  - LG webOS TVs: photos on a half sphere, 360°/180° button.
  - Windows: photos as on phones; videos from desktop build 3, half sphere, 360°/180° button, smooth on a dedicated graphics chip, with limits on an integrated one.
- **Spatial 2.5D (flat screen depth from a stereoscopic video)**
  - Android phones: native player, head tracking with the front camera.
  - iPhone, iPad: same.
  - Meta Quest: not offered.
  - Android TV, Google TV: not offered.
- **Apple spatial photos (HEIC stereo pairs, from build 19)**
  - Android phones: left eye, a details row says it is spatial.
  - iPhone, iPad: same.
  - Meta Quest: View in 3D: both eyes on a photo floating in the immersive view, 3D or 2D, resizable.
  - Android TV, Google TV: left eye, a details row.
- **Apple spatial videos (MV-HEVC, from build 19)**
  - Android phones: one eye (the base layer), with a notice.
  - iPhone, iPad: same.
  - Meta Quest: one eye in the window, with a notice.
  - Android TV, Google TV: one eye, with a notice.
- **Raw Insta360 .insp photos (from build 16)**
  - Android phones: stitched on the GPU before the sphere viewer, up to 8192x4096.
  - iPhone, iPad: same.
  - Meta Quest: immersive, from a stitched picture prepared for the headset.
  - Android TV, Google TV: as on phones.
- **Raw Insta360 .insv, both lenses in one track (from build 16)**
  - Android phones: stitched by a GPU effect in the Media3 player.
  - iPhone, iPad: stitched by a SceneKit shader.
  - Meta Quest: immersive, stitched by the same GPU effect.
  - Android TV, Google TV: as on phones.
  - Windows (from desktop build 3): stitched on the graphics chip in the app's 360° player, smooth on a dedicated chip, with limits on an integrated one.
- **Raw videos with one lens per track or per file (from build 18): Insta360 X4, X4 Air, X5, X6 .insv, X3 pairs, GoPro .360, DJI .osv**
  - Android phones: two hardware decoders at once, one per lens (from build 19 software ones on a device without a hardware decoder, up to 2048x2048 per lens), and a GL compositor that stitches into the sphere; one lens, then the transcoded stream, then the video unstitched, when the device cannot run two.
  - iPhone, iPad: a custom AVFoundation compositor with Metal.
  - Meta Quest: immersive, same two decoders and compositor (3840x1920 panel).
  - Android TV, Google TV: as on phones, when the TV runs two decoders at once.
  - Windows (from desktop build 3): from desktop build 5, two players, one per lens, decoded by the graphics chip (a DJI Osmo 360 file at 25 frames a second on the dedicated chip of the test laptop); then both lenses side by side in one player when the computer keeps up (measured on its own playback; on the test laptop, an X3 pair on its dedicated chip only), the only way for a GoPro .360; otherwise the phones' steps: one lens, the transcoded stream, the camera's low resolution LRV copy, the video unstitched.
- **Tapo camera live view (from build 20)**
  - Android phones: Media3 RTSP player: SD on the page, HD in full screen, sound button.
  - iPhone, iPad: not yet: a card says it comes later.
  - Meta Quest: in the window, in HD.
  - Android TV, Google TV: as on phones.
  - Windows (from desktop build 3): the libmpv player, SD on the page, HD in full screen, sound button.
- **Tapo camera recordings (from build 20)**
  - Android phones: fetched from the memory card into an H.264 video with its sound, then played with seeking.
  - iPhone, iPad: same.
  - Meta Quest: same, in the window.
  - Android TV, Google TV: same.
- **Spheres of DJI drones without 360° tags (from build 27)**
  - Every platform: a 2:1 photo whose EXIF names a DJI drone camera (the make DJI with an FC camera code, or a Hasselblad camera of a DJI drone) is a 360° photo, as the photos a GoPro or a DJI 360° camera stitched itself: badge, 360° list, sphere.
  - Android phones and tablets: sent to Immich with the 360° tags the server needs, in a sidecar file beside the unchanged photo, when you choose it in the upload sheet.

The Android TV and Google TV entries, from build 20, were tried in part on the Google TV emulator (builds 21 and 22: flat photos and videos, the 360° sphere viewer and the 360° video player; build 27: the videos with the remote and a 360° video beyond the decoders); build 25 or 26 ran once on a real Android TV on 21 October 2026, before the TV fixes of build 27, see [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv). The LG webOS entries are those of the webOS app, a first test build that has not run on a real LG TV yet, see [LG webOS TVs](platform-support.md#lg-webos-tvs). The camera entries have not been checked with a real camera yet.

On Windows, the Immuch360 Desktop preview shows the photos, flat and 360°, raw Insta360 .insp photos included, with the mouse and the keyboard. From desktop build 2 it plays flat videos, from the server, the folders of the PC, the shares, Plex and the Tapo recordings, and from desktop build 3 it plays 360°, 3D, VR180 and raw 360° videos from the same sources in its own 360° player, and the Tapo live view. The 360° player is smooth on a dedicated graphics chip and has limits on an integrated one (see [On a Windows computer](user-guide.md#on-a-windows-computer-immuch360-desktop-preview)). The early previews for Linux and macOS show the same photos and, from desktop build 6, play flat videos; their 360°, 3D, VR180 and raw videos play flat, see [macOS and Linux](platform-support.md#macos-and-linux).

- **Your Immich server**: the original or the server's transcoded stream, as Settings, Asset Viewer, Video source says (see [Video details and decoders](user-guide.md#video-details-decoders-and-why-a-video-stutters)). Same account as the web app.
- **The phone or headset itself**: "Use without a server" on the welcome page (on the login page up to build 23), or the On this device entry of the Library tab.
- **A NAS or a computer**: SMB and WebDAV shares, and from build 19 DLNA media servers, found on the network, read live (an SMB video over up to six connections), nothing copied; from build 15 the files you pick can be sent to your Immich account.
- **Another phone (from build 19)**: "Share this phone on the network" on that phone: the headset, or any WebDAV client of the network, reads its albums, months and 360° media.
- **A Plex Media Server (from build 20)**: its photo, movie and TV show libraries by folder, the original files read live over HTTPS checked against the server's own certificate, at home or through the address outside home, on every platform; see [Plex Media Server, without plex.tv](user-guide.md#plex-media-server-without-plextv).
- **A Tapo camera (from build 20)**: the live view with the camera account (Android, Android TV, the Quest, and Windows from desktop build 3), and the recordings of its memory card with the TP-Link account password (every platform), on the local network only; see [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- **The folders of a computer (desktop preview)**: the folders you choose in Immuch360 Desktop, read in place of a phone's gallery; a Windows computer can also share them with the headset, see [On a Windows computer](user-guide.md#on-a-windows-computer-immuch360-desktop-preview).
- **A DJI drone, its controller or a card (from build 27, Android phones and tablets, experimental)**: plugged into the phone with a USB-C cable and read through the folder picker of the system, as a USB drive or a device in File transfer mode; the photos and videos by day, sent to your Immich account or kept in the gallery of the phone; see [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).

## Compared with the Immich app

### Why this fork exists, in one table

| | Immich mobile app | Immuch360 |
|---|:---:|:---:|
| 360° photos as a sphere you look around in (drag, pinch, double tap, inertia, the camera's initial view, partial panoramas) | ❌ flat strip | ✅ |
| Gyroscope: look around by moving the phone | ❌ | ✅ |
| 360° videos in a spherical player, with sound, seeking, audio track choice and a buffering indicator | ❌ flat video | ✅ Android and iOS (no time bar on iOS yet) |
| 3D (stereoscopic) 360° photos and videos | ❌ doubled picture | ✅ left eye on phones, true 3D on the Quest |
| VR180 (half sphere) photos and videos | ❌ stretched around the sphere | ✅ half sphere, 360°/180° button |
| Apple spatial photos (HEIC stereo pairs) and spatial videos (MV-HEVC) | ❌ a flat photo or video, nothing says it is spatial | ✅ from build 19: photos in 3D in the Quest, one eye and a details row elsewhere |
| Meta Quest immersive view with head tracking, a time bar, previous and next, and Turn | ❌ | ✅ same app, as a headset build or the phone APK |
| 360° badge on thumbnails, and a 360° list with raw files and filters (period, source, type, camera) | ❌ | ✅ filters from build 18 |
| "View as 360°" for files the server does not flag | ❌ | ✅ remembered on the phone |
| Turn a photo by 90° with one key: a button, R, the yellow and blue keys of a TV remote | ❌ the photo editor only: Edit, rotate, Save, for your own photos | ✅ from build 27, every platform: through Immich's editor for your own photos on Immich 2.6 and later, on the device for the others; never on 360°, 3D or raw files |
| Spatial 2.5D: depth on a flat screen from a stereoscopic video | ❌ | ✅ experimental, phones and tablets |
| Use without any server, on the device's own gallery | ❌ login required | ✅ |
| SMB and WebDAV shares found on the network and played live, nothing downloaded | ❌ | ✅ every viewer, phones and Quest |
| DLNA media servers as a share type | ❌ | ✅ from build 19 |
| Send the files of a share to Immich; device files sent by hand counted as backed up | ❌ device files only | ✅ from build 15 |
| Import from a DJI drone or a card over USB, its videos placed on the map from their flight data | ❌ the phone's gallery only, where the copies of DJI Fly arrive without the place of a Neo 2 video | ✅ from build 27, Android phones and tablets, experimental |
| Share this phone on the network, for the headset | ❌ | ✅ from build 19, Android and iOS |
| Plex Media Server libraries played from the original files, at home and away, without plex.tv | ❌ | ✅ from build 20, every viewer, on phones, tablets, the Quest and TVs |
| Tapo cameras: the live view, and the recordings of the memory card sent to Immich when you choose | ❌ | ✅ from build 20: recordings everywhere, live on Android, Android TV, the Quest and, from desktop build 3, Windows |
| Android TV and Google TV, driven by the remote, in the same APK | ❌ not a TV app | ✅ from build 20, dark by default from build 27 |
| LG webOS TVs | ❌ no TV app | ✅ a first test build of an app of its own (webOS 0.1.0), built on Immich TV for webOS by Seeky91 |
| The same app on a computer | ❌ phones and tablets only | ✅ preview on Windows: photos, flat and 360° videos (desktop build 7); early previews on Linux and macOS: photos and flat videos |
| Raw Insta360 .insp photos and single track .insv videos | ❌ flat | ✅ from build 16 |
| Raw videos with one lens per track or per file (Insta360 X4, X4 Air, X5, X6, X3 pairs, GoPro .360, DJI .osv) | ❌ flat or wrong | ✅ from build 18 |
| Dual fisheye .dng | ❌ flat | ❌ not yet |
| Server videos: the original when the device decodes it, else the transcoded stream; list of the device's video decoders | ❌ one "Force original video" switch | ✅ from build 15 |
| Technical details of a video: bit rate, picture, profile, whether this device decodes it | ❌ codec only | ✅ from build 18 |
| A free player for flat, 360°, 3D and VR180 videos, from the server, the phone or a NAS | ❌ flat only | ✅ (the Quest 3 store players are paid) |
| Same server, same account, installs next to the official app | | ✅ |

<details>
<summary><b>Status of each line</b>: how it was tested</summary>

- **360° photos as a sphere**: tested on a Galaxy S24+ and an iPhone 14.
- **Gyroscope**: tested on a Galaxy S24+ and an iPhone 14.
- **360° videos**: tested on a Galaxy S24+ and an iPhone 14.
- **3D 360° photos and videos**: tested on a Galaxy S24+ and a Quest 3, with real 3D 360° samples (VRTogether, Vuze, Kandao) and a 3D photo; reports from other cameras welcome.
- **VR180**: tested on an Android emulator and a Galaxy S24+ with synthetic media; device feedback welcome.
- **Apple spatial photos and videos**: detection checked on a sample photo written by Apple's image library and on synthetic files; the headset view and real iPhone files are the device test of build 19.
- **Meta Quest immersive view**: tested on a Quest 3 (controls of build 14, adjusted in build 16 after a user's feedback), and by a user with Insta360 X4 8K HEVC videos.
- **360° badge and 360° list**: done.
- **View as 360°**: done.
- **One-key rotation**: run on the Google TV emulator against an Immich 3.3.0-rc.0 server (a turn saved through the photo editor and undone, the yellow and blue keys, a 360° photo left alone), and covered by widget tests on every platform; not run by hand on a phone, an iPhone, a Quest or a computer yet.
- **Spatial 2.5D**: tested on a Galaxy S24+; iPhone feedback welcome.
- **Without any server**: tested on a Galaxy S24+, a Quest 3 and an Android emulator.
- **SMB and WebDAV shares**: tested with a Freebox Server (SMB) on a Galaxy S24+ and a Quest 3, and against Samba and WebDAV test servers on an Android emulator; other NAS and WebDAV feedback welcome.
- **DLNA media servers**: checked against minidlna and Gerbera in Docker; Plex, Jellyfin, a NAS, the Freebox Server, an iPhone and the Quest are the device test of build 19.
- **Send the files of a share to Immich**: tested on an Android emulator against a Samba test server and an Immich 3.2 server.
- **DJI drone import**: run on an Android phone emulator with synthetic CC0 files against an Immich 3.3.0-rc.0 server (the listing, the upload with the 360° sidecar of a sphere and the place of a video from its .SRT, Keep on the device, the Immich trash); not with a real drone, a USB drive or a device in File transfer mode yet.
- **Share this phone on the network**: unit tests and end to end tests with the headset's WebDAV client, on a computer; a phone serving a Quest, and the iPhone side, are the device test of build 19.
- **Plex Media Server**: checked from a computer against a real Plex Media Server 1.42.1 (pairing, folders, byte ranges, thumbnails, the address outside home); not yet checked on a device.
- **Tapo cameras**: checked against a simulated camera; not yet checked with a real camera.
- **Android TV and Google TV**: checked by automated tests, and on the Google TV emulator in builds 21 and 22 (login, timeline, albums, a flat photo, a video, the 360° sphere viewer and video player, the 360° list, an SMB share, the add menu, the share form, Settings and the remote navigation, but not the Plex and Tapo pages); of the TV fixes of build 23, only the bottom margin of the Photos tab was seen on the emulator; the search filters, the search type and the album sort of build 26 were run there with the remote, and so were the videos, the dark theme, the details, the filters and the rotation of build 27; build 25 or 26 ran once on a real Android TV on 21 October 2026, whose reports led to build 27; build 27 not yet checked on a real TV.
- **LG webOS TVs**: the unit tests of its own layers, the tests it inherits from Immich TV for webOS and the check of its package run in the CI; not run on a real LG TV nor in LG's simulator yet.
- **The same app on a Windows computer**: desktop build 3 passed 855 of its 863 automated desktop tests on Windows (8 skipped by design) and the whole test suite of the app; on a Windows 11 PC it started, opened a saved session on an Immich server, synced, played a video and closed cleanly, and its 360° player was run with synthetic 4K, 5.7K and 8K clips on both graphics chips of a laptop with no crash. Desktop build 4 is covered by the project's CI (the desktop tests on Windows and the whole test suite of the app), and was started, played a 1080p video and closed cleanly by hand; desktop builds 5 and 6 are built and tested by the same CI. The test of each function by hand, with real 360° files and a real Tapo camera, is still to do. Linux ran under WSLg and in the CI's containers only, macOS on the CI's Mac only.
- **Raw Insta360 .insp photos and single track .insv videos**: photos checked against Insta360 Studio exports of X3 files, videos on an Android emulator with a low resolution X3 file; not run on an iPhone yet.
- **Raw videos with one lens per track or per file**: parsers and stitching checked on real X4, X3 pair, GoPro MAX and Osmo 360 files; playback is the device test of builds 18 and 19. A real Osmo 360 file was played on Windows in two players (the NVIDIA chip of the test laptop, 25 frames a second, no frame dropped; not in 360° on the Intel chip, the PC being short of memory) and, on an Android 15 emulator, was listed from a WebDAV share but could not play, the emulator having no 10 bit HEVC decoder.
- **Dual fisheye .dng**: planned.
- **Server videos and the video decoders**: tested on an Android emulator; the Quest 3 H.264 limit was measured on the headset.
- **Technical details of a video**: done.

</details>

## Other apps people use for this

- **The Immich web app**
  - What they run into: it shows a 360° photo as a sphere, but takes a raw .insp for a finished panorama and wraps its two circles around the sphere; a VR view is still a request ([discussion #14768](https://github.com/immich-app/immich/discussions/14768)).
  - What Immuch360 does: stitches raw files on the device, and opens an immersive view in the Quest.
- **The Insta360 app or Studio**
  - What they run into: needed to turn the raw files of the card into a 360° picture before watching.
  - What Immuch360 does: opens the raw .insp and .insv files directly, and the GoPro .360 and DJI .osv files.
- **Plex, Jellyfin, Synology Photos**
  - What they run into: 360° photos and videos shown flat or not recognised, as threads on their forums describe (a Plex request has been open since 2017).
  - What Immuch360 does: reads the Plex library itself from build 20, or the same folders over SMB, WebDAV or DLNA, and plays them as a sphere, without changing anything on the server.
- **The Tapo app**
  - What they run into: a separate app, signed in to your TP-Link account, with the clips apart from your photos.
  - What Immuch360 does: shows the camera next to your photos, talks to it on your network only, and keeps a clip as a video you can send to Immich (from build 20).
- **The Immich mobile app on a TV**
  - What they run into: not a TV app: a user reports that it works with a mouse, not with the remote.
  - What Immuch360 does: the same app, made for the remote (from build 20).
- **Immich TV for webOS**
  - What they run into: a good Immich app for LG TVs, by Seeky91, which shows 360° photos flat.
  - What Immuch360 does: its webOS app is built on it and adds the 360° sphere, the 360° badge, "View as 360°", the keys of the Android TV app and the languages of Immuch360 (a first test build).
- **DJI Fly and its album**
  - What they run into: the clips of a DJI Neo 2 reach the phone's album, then Immich, without their place, which sits in the flight data file the drone writes beside each video; the spheres of most DJI drones show flat in Immich.
  - What Immuch360 does: reads the drone or its card over USB, sends the originals to Immich and places each video on the map from its flight data (from build 27, Android, experimental).
- **Copying files to the headset**
  - What they run into: each file copied over a cable before you can watch it.
  - What Immuch360 does: plays in place from Immich, a NAS, a media server or a phone.
- **The 360° and 3D players of the Quest store**
  - What they run into: paid.
  - What Immuch360 does: free and open source (AGPL).

## Servers and devices checked

What each function was checked on, gathered in one place from the sections of the [user guide](user-guide.md). A device or a server that is not named here has not been tried yet: reports from other ones are welcome in [Issues](https://github.com/freeKC/Immuch360/issues), with the lines of the [logs](troubleshooting.md#logs).

### Devices

| Device | What was checked on it |
|---|---|
| Samsung Galaxy S24+ (Android) | 360° photos as a sphere, the gyroscope and 360° videos; 3D 360° photos and videos with real samples (VRTogether, Vuze, Kandao) and a 3D photo; VR180 with synthetic media; Spatial 2.5D; the mode without a server; an SMB share of a Freebox Server |
| iPhone 14 | 360° photos as a sphere, the gyroscope and 360° videos |
| Meta Quest 3 | Build 25, with its welcome page, by hand on 18 October 2026; the immersive view (the controls of build 14, adjusted in build 16 after a user's feedback); 3D 360° photos and videos with the same samples; the mode without a server; an SMB share of a Freebox Server; the H.264 limit of its decoder, measured on the headset (about 4096x2304); Insta360 X4 8K HEVC videos, played by a user; the headset captures |
| Android emulator | VR180 with synthetic media; the mode without a server; Samba and WebDAV test servers; the files of a Samba share sent to an Immich 3.2 server; the server videos and the video decoders; a single track raw video (a low resolution X3 file); the phone captures; from build 27, a phone emulator for the DJI drone page, with synthetic CC0 files in a folder of its storage (a drone sphere with its five source shots, a 4000x3000 photo, a 10 second video with its .LRF, .m4a and .SRT, an .OSV) |
| Google TV emulator | Builds 21 and 22: the login, the timeline, the albums, a flat photo, a video, the 360° sphere viewer and the 360° video player, the 360° list, an SMB share, the add menu with its network share, Plex and camera choices, the share form, Settings and the remote navigation fixes, but not the Plex and Tapo pages themselves; build 23: the bottom margin of the Photos tab, its other TV fixes being covered by automated tests; build 24: the welcome page with the remote; build 26: the search filters (People, Media Type, Display options, Star Rating, Tags, Camera, Location, quick date), the search type and the album sort with the remote; build 27: the videos with the remote (Left and Right while a video plays, the controls hiding after 5 seconds, no loop), the dark first start on a TV set to light, the Location, Camera and date filters and the sheets with Clear and Apply beside the choices, the details with the Menu key and a held OK, the message of a 5.7K H.264 360° video beyond the decoders of the emulator, a held arrow over 1000 photos without a freeze, and the one-key rotation against an Immich server; the TV captures |
| A real Android TV (model not recorded) | Build 25 or 26, on 21 October 2026, by the owner: photos and 360° photos went well; a video playing in a loop that Left and Right could not leave, the controls over the picture, 360° videos that never played, white pages and one freeze while photos scrolled, which led to the TV fixes of build 27 |
| Windows 11 laptop with an Intel UHD chip and an NVIDIA RTX 4060 Laptop | Desktop build 3 passed 855 of its 863 automated desktop tests (8 skipped by design) and the whole test suite of the app, and started, opened a saved session on an Immich server, synced, played a video and closed cleanly; desktop build 4, whose tests run in the project's CI, was started, played a 1080p video and closed cleanly by hand; the 360° player with synthetic 4K, 5.7K and 8K clips on both graphics chips; raw two lens videos from synthetic clips and real X3 and X4 files; the measurements of [the desktop 360° video renderer](desktop-360-video-renderer.md); the Windows captures; with CI builds of 13 October 2026 and CC0 media, files opened from the command line (before a session and with a saved one), by second starts and by drops sent to the window by a test script (360° photos and a 360° video opened in their 360° view, a flat photo and "View as 360°" on it, folders and files of two folders on the page of opened files, several starts at once with a file each on one page) |
| WSLg on the same laptop (the Linux of Windows 11) | Desktop build 5: the .deb in an Ubuntu 24.04 container, the login page, the mode without a server, the timeline of the Pictures and Videos folders, a 360° photo as a sphere; the video work of desktop build 6: a folder given on the command line with its video thumbnails, a 20 second video played, a 360° video and a raw .insv file played flat with their message; for desktop build 7, a test program of the X11 fix of the video plugin with the graphics chip of the laptop |
| The Linux containers of the CI | Each package installed with its dependencies on Ubuntu 22.04 and 24.04, Debian 12, Fedora 40 and Fedora 44, every library found, and from desktop build 6 a short clip played with the distribution's libmpv; from desktop build 7, that clip on the hardware path under X11, drawn by Mesa's software rasterizer, without a secret service, and the libsmb2 notice, texts and source archive in each package |
| The macOS runner of the CI (a virtual Mac) | Desktop build 5: "Open with" in Launch Services for 19 file types, a first start; desktop build 6: the self check of the app (a folder and a video on the command line, a photo through Launch Services, a video handed to the app that runs, the login keychain, 5 seconds of video drawn in software) |
| A computer, with unit and end to end tests | The phone share with the headset's own WebDAV client and media bridge; the detection of Apple spatial photos, on a sample written by Apple's image library and on synthetic files, and their 3D composition; the two track and two file raw stitching, with the app's CPU reference stitcher on real X4, X3 pair, GoPro MAX and Osmo 360 files; raw photos against Insta360 Studio exports of X3 files |

### Servers and sources

| Server or source | What was checked against it |
|---|---|
| Immich 3.2.4 | Build 22, on the Immich base of the current build 27: login, timeline, albums, 360° photos and videos, video playback and uploads, with no API error |
| Immich `main` of 10 October 2026 (3.3.0-rc.0) | The same checks, on a server built from the Immich `main` the current build is based on; from build 27, the one-key rotation through the photo editor (an edit saved and removed, from the Google TV emulator) and the uploads of the DJI drone page (a sphere flagged 360° by its sidecar with its bytes unchanged, a video placed from its .SRT) |
| Immich 3.2 | The files of a Samba share sent to the server, from an Android emulator |
| Freebox Server | SMB shares on a Galaxy S24+ and a Quest 3, read over one connection (4.5 MB/s) and six (19 MB/s); its disks want the user name `freebox` and no password |
| Samba and WebDAV test servers | SMB and WebDAV shares on an Android emulator |
| minidlna and Gerbera | DLNA media servers, in Docker |
| Plex Media Server 1.42.1 | From a computer: the pairing, the folders, the byte ranges of a video, the thumbnails, a wrong token and the address outside home; photo and TV show libraries against a simulated server only |
| A simulated Tapo camera | The protocol, written from captures of a C510W with firmware 1.3.4 (the V4 login of mid 2026), checked against a simulated camera in the app's tests; on Windows, the live view against a test RTSP server that signs in the way the cameras do (Digest), cut and refused on purpose |

### Not checked on a device yet

- **Tapo cameras**: no real camera yet, on any platform, see [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- **Plex**: playback on a phone, in the Quest, on an iPhone and on a TV, and the switch to the address outside home, see [Plex Media Server](user-guide.md#plex-media-server-without-plextv).
- **Raw videos with one lens per track or per file**: playback on a phone, a Quest and an iPhone; raw files have not run on an iPhone at all, see [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **Share this phone on the network**: a phone serving a Quest 3, and the iPhone side, see [Share this phone on the network](user-guide.md#share-this-phone-on-the-network).
- **DLNA**: discovery on a real network, and Plex, Jellyfin, a NAS, the Freebox Server, an iPhone and the Quest, see [DLNA media servers](user-guide.md#dlna-media-servers).
- **Apple spatial photos and videos**: the headset view and real iPhone files, see [Apple spatial photos and videos](user-guide.md#apple-spatial-photos-and-videos).
- **Meta Quest 2, Quest Pro and Quest 3S**: not tested, see [Meta Quest](platform-support.md#meta-quest).
- **Android TV and Google TV**: build 27 not on a real TV (build 25 or 26 ran once on one), and the Plex and Tapo pages not even on the emulator, see [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **LG webOS TVs**: not on a real LG TV, nor in LG's simulator, see [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **DJI drones**: no real drone, USB drive or device in File transfer mode yet, see [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- **One-key rotation**: not by hand on a phone, an iPhone, a Quest or a computer, see [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).
- **Spatial 2.5D**: not on an iPhone, see [Spatial 2.5D](user-guide.md#depth-on-a-flat-screen-spatial-25d-experimental).
- **Windows**: the test of each function by hand, with real 360° and 3D files, both screens of a laptop, sleep and resume, and a real camera, see [Known problems](user-guide.md#known-problems).
- **Linux and macOS**: a real Linux PC and a real Mac, see [macOS and Linux](platform-support.md#macos-and-linux).

## Limits by feature

Every limit the [user guide](user-guide.md) gives, in one list. Each item links to the section that explains it.

### 360° photos and videos

- The iOS 360° video player has play and pause only, no time bar yet: [360° photos and videos](user-guide.md#360-photos-and-videos-as-a-sphere).
- The 360° players of phones do not move to the previous or next media yet; the Quest immersive view does: [360° photos and videos](user-guide.md#360-photos-and-videos-as-a-sphere).
- A photo is shown at 8192x4096 at most, so a larger panorama is downscaled: [360° photos and videos](user-guide.md#360-photos-and-videos-as-a-sphere).
- Dual fisheye .dng files still show flat: [360° photos and videos](user-guide.md#360-photos-and-videos-as-a-sphere).
- The initial view the camera recorded (GPano) is used by the sphere viewer of phones only, not by the Quest immersive view nor by the 360° video players: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- On phones, the 360° video players do not hand their playback position back to the flat player when they close; the Spatial player and the immersive view do: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).

### One-key rotation

- Flat photos only: videos, 360°, 180° and 3D photos, Apple spatial photos, raw files, 2:1 photos of Insta360 cameras (even when the server does not flag them 360°), photos of the trash and of the locked folder never turn, and a photo whose kind is not known yet gets the button once it is: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).
- Saved on the server only for your own photos on Immich 2.6.0 or later, through its photo editor (a crop or a mirror made before is kept); the photos of a partner or of a shared album, motion photos, GIF and SVG files, an older server, the read only mode and the files of shares and of the device are turned on this device only: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).
- A turn kept on the device is not shown by the slideshow, the memories, the thumbnails and casting: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).

### Without a server

- On an iPhone, the scan for 360° files skips those stored only in iCloud until they are downloaded: [Without a server](user-guide.md#without-a-server-or-an-account).
- Without a server, the 360° list holds what the scan of the device found and the files viewed as 360°: [Without a server](user-guide.md#without-a-server-or-an-account).

### Network shares

- SMB 2 and 3 only, no SMB 1: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- WebDAV: Basic authentication only, no Digest yet; a self signed HTTPS certificate must be installed on the device: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- Finding servers: the local /24 network only, the local network permission on iOS, and on iPhone and iPad unicast requests only, which some servers do not answer (minidlna on Linux): [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- DLNA: a server that only offers a converted copy gives that copy; a folder lists 20,000 entries at most: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- Thumbnails: a photo thumbnail decodes the whole file, and photos over 30 MB get none: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- Players: no audio track choice in the flat player, no swiping from one file of a folder to the next on a phone, and the 3D or 180° choice made on a network file is not remembered: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- Uploads run only while the app is open, and a file the server already has is sent in full before the server reports it as a duplicate: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).

### Plex Media Server

- Claimed servers only, which have their plex.direct certificate: [Plex](user-guide.md#plex-media-server-without-plextv).
- IPv4 only: [Plex](user-guide.md#plex-media-server-without-plextv).
- The token gives full access to the server; removing the server in the app does not revoke it, and a token with an end date cannot be renewed by the app: [Plex](user-guide.md#plex-media-server-without-plextv).
- Away from home only through a port forwarding, there is no relay: [Plex](user-guide.md#plex-media-server-without-plextv).
- Music is not shown, a folder lists 20,000 entries at most, and a restricted user may not read the libraries: [Plex](user-guide.md#plex-media-server-without-plextv).
- Raw 360° camera files show only if Plex lists them: [Plex](user-guide.md#plex-media-server-without-plextv).
- A server whose local network discovery (GDM) is off is not found; iPhone and iPad send unicast requests only; the DLNA side of the same server can show in the list too: [Plex](user-guide.md#plex-media-server-without-plextv).
- Not checked on a device yet: playback on a phone, in the Quest, on an iPhone and on a TV, and the switch to the address outside home: [Plex](user-guide.md#plex-media-server-without-plextv).
- Immuch360 is not affiliated with Plex.

### Share this phone on the network

- On iPhone and iPad the share runs only while the app is in front: [Share this phone](user-guide.md#share-this-phone-on-the-network).
- It stops after 60 minutes without any request and when the app is closed, and never starts by itself: [Share this phone](user-guide.md#share-this-phone-on-the-network).
- Local network only, and the password travels unencrypted on the Wi-Fi (plain HTTP): [Share this phone](user-guide.md#share-this-phone-on-the-network).
- Not checked on a device yet: a phone serving a Quest 3, and the iPhone side: [Share this phone](user-guide.md#share-this-phone-on-the-network).

### Tapo cameras

- Not checked with a real camera yet: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Live view on Android phones and tablets, Android TV, the Quest and Windows, not on iPhone and iPad yet; two HD and two SD streams at most at once per camera, and Tapo Care, the memory card and an RTSP or ONVIF recorder cannot all run at once: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Battery cameras and cameras behind a Tapo hub are not supported: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Recordings: one download at a time per camera, H.265 recordings not converted yet, no thumbnail for continuous recordings, and a clip plays once it is fully fetched: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Passwords: each wrong one counts, and the camera locks for a while after a few: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Space: fetched clips stay in the cache of the app, 1 GB at most for all the cameras together: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Not reachable from outside your network: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- Immuch360 is not affiliated with TP-Link.

### DJI drones and the DJI Neo 2

- Experimental, on Android phones and tablets only, behind Settings, Advanced, "DJI drones (experimental)"; not in the Quest build, not with the remote control layout of a TV, not on iPhone, iPad or computers: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- Not checked with a real drone yet: an Android phone emulator with synthetic files stood in for it, so a USB drive, a device in File transfer mode (MTP) and an unplug in the middle of a large file are untested: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- What the app knows of the DJI Neo 2, from DJI's specifications and manual and from owners' reports, not checked on the drone yet:
  - No panorama or sphere mode: its photos are JPEG files of 12 MP, 4000x3000 (4:3) or 4000x2250 (16:9), without RAW; the recognition of drone spheres serves the other DJI drones, and spheres stitched by hand from Neo 2 shots.
  - Videos: MP4, H.264 or H.265, up to 80 Mb/s, up to 3840x2880 (4:3) or 3840x2160.
  - EXIF: the make "DJI" and the model "FC9470", the code of its camera, not the name of the drone.
  - The place of a video: the Neo 2 records its position in a track of the MP4 that ExifTool, which the Immich server uses, does not decode yet (ExifTool 13.59); the only place the app can read is the .SRT flight data file, which the drone writes beside each video only when "Video Subtitles" is on in DJI Fly (Settings, Camera, in video mode).
  - Storage: 49 GB inside the drone, exFAT, no card slot. By DJI's manual it is read with a cable while switched off, and most likely shows as a USB drive; how a phone sees it is to be confirmed.
  - Sound: the drone has no microphone; the sound recorded by the phone or a DJI Mic is kept in a separate .m4a file, which DJI Fly merges when it downloads the clip.
  - QuickTransfer, the Wi-Fi copy to the phone of DJI Fly, is not supported: its protocol is not published.
  - Its controllers store no media, apart from the DJI RC 2, which shows as a device in File transfer mode.
- Never sent and never listed: the proxies (.LRF, .LRV), the flight data (.SRT), .THM and .m4a files. Files Immich refuses (.osv, .360, .36p) are marked "Not accepted by Immich" and can be kept in the Download folder: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- The 360° tags of a drone sphere go to the server in a sidecar file only when you turn the option on, off by default; a sphere the server already has keeps no sidecar, so it stays flat in the Immich web app: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- A video gets the place of the first position of its .SRT, set through the Immich API after the upload, only when the server found none in the video; when the server has not read the video within 90 seconds, the place is set later, when a share or the drone page opens: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- The Immich API has no resumable upload: a video cut half way is sent again from its start; the files sent before are marked and skipped: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- Immuch360 is not affiliated with DJI.

### Raw 360° camera files

- Seams: the stitch uses the camera's calibration only, without seam optimisation: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- Horizon: a video is levelled once, from the start of the recording, and not stabilised; GoPro and DJI files are not levelled: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- Files without their calibration block use the calibration of the same camera or model, or the nominal X3 values: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- Playback on a phone, a Quest and an iPhone is still the device test of builds 18 and 19: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- The Immich server refuses .360 and .osv uploads, so those files only exist on shares and on computers: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- Raw files copied to an Android device are not in its gallery: Android files them as other files, not as photos or videos: [Watch a raw file](user-guide.md#watch-a-raw-file).
- A device that cannot run two decoders plays one lens, the transcoded stream or the unstitched video: [Raw 360° camera files](user-guide.md#when-the-device-cannot-play-both-lenses).
- No progress indicator yet while a raw photo is prepared for the headset: [Raw 360° camera files](user-guide.md#watch-a-raw-file).

### 3D and VR180

- A phone, a TV and a computer show the left eye of a 3D file: [3D and VR180](user-guide.md#3d-and-vr180-photos-and-videos).
- The 3D choice is not remembered when the viewer closes; the 360°/180° choice is, for the media of the library, not yet for a file of a network share: [3D and VR180](user-guide.md#3d-and-vr180-photos-and-videos).

### Spatial 2.5D

- Experimental, phones and tablets only, needs OpenGL ES 3.0 or Metal; the depth is an estimate, best in landscape with your face well lit; checked on a Galaxy S24+ only: [Spatial 2.5D](user-guide.md#formats-privacy-and-limits).
- A half width file is only recognised by its name, and the layout chosen is not remembered for a file of a network share: [Spatial 2.5D](user-guide.md#formats-privacy-and-limits).
- Not offered on the Meta Quest, which has no camera an app may use: [Spatial 2.5D](user-guide.md#formats-privacy-and-limits).

### Apple spatial photos and videos

- Previous and next are not available from a spatial photo yet: [Apple spatial](user-guide.md#see-a-spatial-photo-in-3d-in-the-headset).
- The 3D view shows the original file, without the edits made in Immich: [Apple spatial](user-guide.md#see-a-spatial-photo-in-3d-in-the-headset).
- Spatial videos play one eye, their base layer, in every player: [Apple spatial](user-guide.md#everywhere-else).
- Server photos carry no badge in the timeline: the app finds out when one is opened: [Apple spatial](user-guide.md#everywhere-else).
- Not checked on a device yet: the headset view and real iPhone photos and videos: [Apple spatial](user-guide.md#not-checked-on-a-device-yet).

### Meta Quest

- Previous and next look at most 400 media ahead in a timeline and 50 files in a share folder, for 12 seconds at most: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- A video whose source does not answer byte range requests cannot be sought: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- A flat stereoscopic video plays in the window with both eyes visible: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- The immersive view draws a full or a half sphere only, so a partial panorama is spread over the full sphere unless its GPano crop covers about half the width and the whole height: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- No audio track choice in the immersive view: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- HEVC is the safe codec; H.264 stops around 4096x2304: [Limitations on the headset](platform-support.md#limitations-on-the-headset).
- The headset build reaches plain HTTP only at names of the home network and the headset itself: [Meta Quest](platform-support.md#meta-quest).
- The store version is build 23 since 18 October 2026; build 25, with the welcome page, is in Meta's review: [Limitations on the headset](platform-support.md#limitations-on-the-headset).
- No storage, audio, location or camera permission, so no Wi-Fi name based server switching: [Limitations on the headset](platform-support.md#limitations-on-the-headset).
- The Spatial SDK adds about 56 MB of 64-bit ARM native code to every APK: [Limitations on the headset](platform-support.md#limitations-on-the-headset).
- The immersive view uses the Meta Spatial SDK, under the Meta Platform Technologies SDK License Agreement: [Limitations on the headset](platform-support.md#limitations-on-the-headset).
- Only the Quest 3 is tested; the Quest 2, Quest Pro and Quest 3S are not tested yet: [Meta Quest](platform-support.md#meta-quest).

### Android TV and Google TV

- A viewer: backup, uploads, editing (apart from the one-key rotation, from build 27), deleting, sharing, selecting several items, Cast, the Spatial 2.5D button, the gyroscope, the map and Places, the DJI drone page and the phone share are hidden, although the Settings page still shows the setting of Spatial 2.5D and, with a server, the Backup section: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- Signing in with OAuth is not possible, an email and a password are: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- Links show their address instead of opening a browser: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- On a TV with little memory, 360° photos are shown at 4096x2048 at most; from build 27 a TV with 3 GB of memory or less counts as one: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- The decoders of a real TV are not measured yet, and a video beyond them does not play: from build 27 the app says why instead of loading forever: [When a video does not play](user-guide.md#when-a-video-does-not-play).
- From build 27, Left and Right go to the next item while a video plays and OK shows the controls first, where Google's quality guidelines for TV apps ask that they seek and pause: [Known issues](known-issues.md#android-tv-and-google-tv).
- Tried on the Google TV emulator (builds 21, 22, 26 and 27, without the Plex and Tapo pages, and one fix of build 23); build 25 or 26 ran once on a real TV, build 27 not yet: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- Google Play on TVs waits for Google's review; until then, the APK: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- Fire TV is not tested, and there is no Apple TV version: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).

### LG webOS TVs

- A first test build of an app of its own, for webOS 4.0 and later, installed in Developer Mode; not run on a real LG TV yet: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- A viewer of an Immich server only: no uploads, no photo editor apart from the quarter turn, no network shares, Plex or Tapo cameras, no Cast: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- 360° videos play flat for now; 360° photos turn on a WebGL sphere: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- On webOS before 25, the reverse proxy in front of Immich must send CORS headers: [Install it on an LG TV](platform-support.md#install-it-on-an-lg-tv).
- The texts only the TV app has are in English until the next webOS release: [Known issues](known-issues.md#lg-webos-tvs).

### Server videos and decoders

- A row of the video details shows only once the file has been read, and only for what the file tells: [Video details](user-guide.md#read-the-details-of-a-video).
- An original whose server ignores Range requests, with its index at the end of the file, plays the server's playback stream instead: [Originals that cannot stream](user-guide.md#originals-that-cannot-stream).

### Windows

- Two lens raw videos play in two players from desktop build 5 (checked on a dedicated chip with Osmo 360, X4 and X3 files), and stacked in one player only when the computer keeps up: [Not there yet](user-guide.md#not-there-yet).
- 3D on the screen only, the left eye; no gyroscope and no headset view: [Not there yet](user-guide.md#not-there-yet).
- No Spatial 2.5D, map, Places, OAuth sign in, Google Cast or notifications yet: [Not there yet](user-guide.md#not-there-yet).
- No signed build and no automatic updates yet; the installer since desktop build 5: [Install it on a computer](user-guide.md#install-it-on-a-computer-windows-linux-and-macos).
- The first start of a new build is slow, 8K HEVC needs a dedicated graphics chip, videos are drawn at most 1440 lines high, flat or in the 360° player, and a file being played cannot be renamed, moved or deleted: [Known problems](user-guide.md#known-problems).
- The libmpv workflow builds an arm64 archive too, but there is no Windows on ARM app yet: [Windows](platform-support.md#windows).
- A folder opened with the program or dropped on its window shows its own photos and videos, not those of its subfolders, at most 5000, without the files OneDrive keeps online only; files opened that way stay out of your folders (from desktop build 5): [Use it on a computer](user-guide.md#use-it-on-a-computer).
- On an integrated graphics chip, the 360° view works on frames at most 2880 pixels wide: [360° videos and the graphics chip](user-guide.md#360-videos-and-the-graphics-chip).

### macOS and Linux

- Packages from desktop build 5 (a .deb, an .rpm, a macOS app), built by the project's CI, early previews: [macOS and Linux](platform-support.md#macos-and-linux).
- From desktop build 6, flat videos play; 360°, 3D, VR180 and raw dual lens videos play flat with a message, since the 360° player is Windows only: [macOS and Linux](platform-support.md#macos-and-linux).
- No computer share, no probe of the graphics chip's decoders, and on Linux no watching of folders: [macOS and Linux](platform-support.md#macos-and-linux).
- Linux: without a secret service the app keeps its secrets for the session only (from desktop build 7 without the waits of 25 seconds of earlier builds); the graphics chip draws the videos on X11 sessions from desktop build 7, checked in the CI only; on Fedora, camera videos need the FFmpeg of RPM Fusion: [Linux](user-guide.md#linux).
- Linux has run under WSLg and in the CI's containers only, macOS on the CI's Mac only; on both, the Immich server gallery, the shares, Plex, the Tapo cameras, Apple spatial photos and the upload to Immich are in the sources and built by the CI, not checked there yet; the macOS app is not signed nor notarized: [Known issues](known-issues.md#macos-and-linux).

Last updated: 22 October 2026 (build 27, desktop build 7, webOS 0.1.0)
