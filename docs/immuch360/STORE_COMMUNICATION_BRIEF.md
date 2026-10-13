# Store communication brief

The context handed to whoever writes the store listings of Immuch360 (Google Play, the App Store, the Meta Horizon Store): the positioning, the promise, the benefits, the features by category, the platforms, the verified state of each distribution, the terms to use and the technical claims that may be made. It is a transmission of context, not a store listing: the listing texts themselves are written in a second step and must respect the length limits and the rules of each store.

Back to the [README](../../README.md). Written on 12 October 2026 (build 23, desktop build 4).

## 1. Positioning

Immuch360 is a free and open source multiplatform media app that lets people find, browse, play and explore their photos and videos, the ordinary ones and the panoramic, 360°, 3D and immersive ones, with or without a server.

What it is not: not only a mobile app, not only a VR app, not only an Immich client. What it never asks for: an Immuch360 account (there is none), a cloud, a server. The Immich server, the NAS, the media server, the Plex server and the cameras are options the user adds.

The flat media (the gallery, the albums, the ordinary photos and videos) are as visible as the immersive ones. The advanced features never hide the simple use: open the app, tap "Use without a server", watch.

Unofficial fork of the Immich mobile app: say it, once, where the store asks what the app is based on or in the long description, never as the opening argument. Not affiliated with Immich, FUTO, Meta, Plex, TP-Link, Google or Apple.

## 2. The promise

Headline: **Your media. Any screen. Every perspective.**

One sentence under it: Photos and videos, flat, panoramic, 360°, 3D and VR180, from your device, your NAS or your Immich server, on your phone, tablet, TV, headset and computer, without any account.

Why it is not a generic media player claim: no other app plays the raw files of a 360° camera, the 360° photos of a phone, the videos of a NAS, a Plex library and an Immich library in the same viewers, on a phone, a TV, a Quest and a computer, with no account and nothing copied.

## 3. The main user benefits, in the order to present them

1. **See your 360°, 3D and VR180 shots the way they were meant to be seen**: as a sphere you look around in, in 3D in a headset, instead of a flat strip or a doubled picture.
2. **Your own files, no account**: the photos and videos of the device, the folders of a computer, with every viewer, and nothing leaves the device.
3. **Play from where the files are**: a NAS, a computer, a media server, a Plex server, an Immich server, read in place, nothing downloaded; a phone or a computer shared with the headset at home.
4. **One app on every screen**: phones, tablets, Android TV with the remote, Meta Quest with the immersive view, Windows with mouse and keyboard.
5. **Raw camera files, without the camera's app**: Insta360, GoPro MAX and DJI Osmo 360 files stitched as they play.
6. **Your Immich library, plus**: everything the Immich app does, with the 360° list, the choice of the original or the transcoded stream per video, the technical details of a video, and files of a share sent to the server.
7. **Cameras next to your photos**: Tapo cameras live and their memory card recordings, on your network only, with a clip kept in Immich when you choose.
8. **Free, open source, private**: AGPL, no analytics, no advertising, passwords and tokens in the secure storage of the device.

## 4. Features by category

The complete inventory, with the build each feature arrived in and its state per platform, is in [features.md](features.md); the how to of each one is in the [user guide](user-guide.md). The categories to reuse in a listing:

- **Playback**: flat photos and videos; panoramas and partial panoramas; 360° photos as a sphere (drag, pinch, inertia, gyroscope, the camera's initial view); 360° videos in a native spherical player with sound, seeking, audio tracks and a buffering indicator; VR180 on a half sphere; stereoscopic 3D (top and bottom, side by side) read from the file or guessed; "View as 360°" for files without a projection tag; the technical details of a video and the list of the device's decoders.
- **3D and spatial**: true 3D in the Meta Quest; Apple spatial photos in 3D in the headset, recognised everywhere; Apple spatial videos recognised (one eye played); Spatial 2.5D, depth on a flat screen from a stereoscopic video with the front camera following the head (phones and tablets, experimental).
- **Sources**: the device itself without any account; the folders of a Windows computer; an Immich server with the whole Immich app (backup, timeline, albums, search, people, memories, sharing, partners); SMB, WebDAV and DLNA shares found on the network and played live; Plex Media Server without plex.tv, at home and away; a phone or a computer shared on the Wi-Fi for the headset; files of a share or of the device sent to Immich by hand; the 360° list with filters by period, source, kind and camera.
- **Cameras**: Tapo cameras live (Android, Android TV, Quest, Windows) and their memory card recordings (every platform), on the local network only, a clip sent to Immich when chosen.
- **Raw camera files**: Insta360 .insp photos and .insv videos (one or two lenses, one track, two tracks or two files), GoPro MAX .360, DJI Osmo 360 .osv, stitched on the device with the calibration of the file.
- **Interfaces**: touch and gyroscope on phones and tablets; the remote on Android TV and Google TV; controllers and hand tracking in the Quest; mouse and keyboard on Windows, with folders instead of a gallery and the computer shared with the headset.
- **Under the hood**: native players (Media3, SceneKit, AVFoundation, the Meta Spatial SDK, libmpv); hardware decoders with measured limits; the original or the transcoded stream chosen per device; a local bridge with byte ranges so nothing is copied; on Windows the 360° view drawn by the graphics chip from each decoded frame.

## 5. The platforms

| Platform | What it has | Distribution on 12 October 2026 |
|---|---|---|
| Android phones and tablets | the complete app | Google Play: build 20 live since 7 October 2026, build 23 sent for review on 10 October; GitHub: build 23 APKs |
| iPhone and iPad | the complete app; the 360° video player has play and pause only; no Tapo live view yet | App Store: version 3.3.0 waiting for Apple's review since 3 October (it carries the features of build 11); TestFlight: build 23 |
| Android TV and Google TV | the same APK, driven by the remote, as a viewer (no backup, uploads or editing) | GitHub: the universal APK of build 23, sideloaded; Google Play: the TV listing under Google's review since 9 October |
| Meta Quest 2, Pro, 3 and 3S | the app as a window plus the immersive view with true 3D | Meta Horizon Store: public since 7 October 2026 with build 14, build 21 in review, build 23 on the Alpha channel; GitHub: the Quest APK of build 23 |
| Windows 10 and 11 | a preview: folders, flat and 360° videos, raw files, shares, Plex, cameras, the computer shared with the headset | GitHub: desktop build 4 pre release ZIP of 10 October 2026 |
| macOS and Linux | the projects exist and are built by the CI; the app has not been started on those systems; no video player library yet | no download; never say "available" |

Levels to keep apart in any text: code present, feature implemented, build compiled by the CI, pre release on GitHub, public download, published in a store. The exact state per platform is in [platform-support.md](platform-support.md) and [release-status.md](release-status.md).

## 6. What stands out on each environment

- **Phones and tablets**: the gyroscope sphere, Spatial 2.5D, the phone shared with the headset, every source in the pocket.
- **Android TV and Google TV**: the 360° photos and videos, the shares, Plex and the cameras on the big screen with the remote; the only Immich app made for the remote.
- **Meta Quest**: the immersive view with head tracking, true 3D, previous and next, Turn; the files from the server, the headset, a NAS, a phone or Plex played in place; free where the store players are paid.
- **Windows**: the folders of the PC without any server, a video player of its own for flat and 360° videos with the view drawn by the graphics chip, raw files stitched, the PC shared with the headset.
- **iPhone and iPad**: the sphere viewer with the gyroscope, the SceneKit 360° player, Apple spatial photos recognised, the phone shared with the headset while the app is in front.

## 7. Reusable captures and visuals

All captures used in public must be real captures of the app showing CC0 or synthetic media (Poly Haven panoramas and backplates) or captures the owner published already. The provenance of each file is in [.github/readme/CAPTURES.md](../../.github/readme/CAPTURES.md).

- Phone (Android emulator, English, CC0 panoramas): `.github/readme/b19-sphere.jpg`, `b19-video.png`, `b19-library-no-server.png`, `b19-add-share.png`, `b19-share-folder.jpg`, `b19-360-list.png`, `b19-video-details.png`; the Google Play phone and seven inch screenshots in the research folder `store/play-images/en-US/`.
- Google TV (emulator, 1920x1080, CC0 media): the six TV screenshots of the Google Play listing and the copies in `.github/readme/tv-b21-*.jpg`.
- Meta Quest 3 (captures taken by the owner, French interface): `.github/readme/quest-immersive-360-photo.jpg`, `quest-immersive-360-video.jpg`, `quest-immersive-3d-360-video.jpg`, `quest-library-without-server.jpg`, `quest-network-shares.jpg`, and the store captures in `D:\DEV\immuch\metastore\quest-captures\`.
- Windows (desktop build 4, Windows 11, CC0 media): `.github/readme/desktop-b4-video.jpg` and `desktop-b4-photo.jpg` (the viewer and the video player; the 360° view could not be captured, see the known issues).
- Marketing visuals: the hero banner `.github/readme/hero-2026-10.jpg` (generated from the previous banner and the logo, with the headline), the multiplatform montage `.github/readme/platforms-2026-10.jpg` (real captures side by side), the Google Play feature graphic and TV banner, the Meta cover art (landscape, portrait, square), hero and logo in `D:\DEV\immuch\metastore\`.
- The store screenshots must stay real captures; marketing frames around them are fine; nothing generated may be presented as the app.

## 8. Terminology

- "Immuch360" (never "Immuch 360"); "the Immich app" for the official app; "Immich server" for the server.
- "360° photo", "360° video", "panorama", "partial panorama", "VR180", "3D" or "stereoscopic" (top and bottom, side by side), "Apple spatial photo", "spatial video", "Spatial 2.5D" (the flat screen depth player).
- "the sphere viewer" (photos), "the 360° player" (videos), "the immersive view" (Quest), "the Spatial 2.5D player".
- "raw 360° camera files" (Insta360 .insp and .insv, GoPro MAX .360, DJI Osmo 360 .osv), "stitched by the app".
- "network share" (SMB, WebDAV, DLNA), "media server" (DLNA), "Plex Media Server", "Tapo camera", "the phone share", "the computer share".
- "Use without a server" (the exact label), "the 360° list", "View as 360°", "Video source", "the original" and "the transcoded stream".
- "Android TV and Google TV", "Meta Quest 2, Quest Pro, Quest 3 and Quest 3S", "Immuch360 Desktop" (the Windows version), "preview" for the desktop.
- No buzzwords, no dash used as punctuation, no superlatives that a store could ask to prove.

## 9. Technical claims that may be made (verified)

- 360° photos as a sphere with the gyroscope, on Android and iOS: checked on a Galaxy S24+ and an iPhone 14.
- 360° videos in a native spherical player with sound and seeking (Android: Media3; iOS: SceneKit, play and pause only).
- True 3D in the Meta Quest for stereoscopic 360° and VR180 files: checked on a Quest 3 with real 3D samples; an Insta360 X4 8K HEVC video plays smoothly in the headset (a user's report).
- Raw Insta360 .insp photos stitched on the device against Insta360 Studio exports (same framing, level horizon); raw two lens videos stitched from real X4, X3 pair, GoPro MAX and Osmo 360 files (parsers and stitching checked; playback on a phone still to be reported).
- SMB and WebDAV shares played live: checked with a Freebox Server on a Galaxy S24+ and a Quest 3; DLNA against minidlna and Gerbera; Plex against a real Plex Media Server 1.42.1 from a computer.
- Tapo cameras: the protocol was written from captures of a C510W and checked against a simulated camera; a real camera check is still pending. Say "Tapo cameras" without numbers or models.
- Android TV: checked on the Google TV emulator in builds 21 and 22 (login, timeline, albums, a flat photo, a video, the 360° sphere viewer and the 360° video player, the 360° list, an SMB share, the share form, Settings, the remote navigation), not on a real TV yet; the Plex and camera pages were not opened on the emulator.
- Windows: desktop build 4 starts, plays a 1080p video and closes cleanly on a Windows 11 PC; the 360° player ran 4K, 5.7K and 8K synthetic clips on an Intel UHD and an RTX 4060 Laptop with no crash; 8K HEVC at 30 frames a second on the RTX, at most 2880 pixels wide on the Intel chip.
- Servers: build 22 and 23 tested against Immich 3.2.4 and Immich main of 10 October 2026, no API error.
- Nothing goes to the developer: no account, no analytics, no crash reporting service.

Claims not to make: that every codec or format plays (the device's decoders decide); that macOS or Linux are available; that the Quest 2 and Quest Pro are tested (they are listed, untested); that Tapo cameras were tested with real hardware; that the iPhone has the Tapo live view or a time bar in the 360° player.

## 10. Compatibility points that must stay visible in a listing

- The 360° video decoding limits of the headset: HEVC is the safe choice, H.264 stops around 4096x2304 on the Quest 3; the app offers the server's transcoded stream when the original is too large.
- Spatial 2.5D is experimental, phones and tablets only, needs the front camera (used on the device only).
- Tapo cameras: on the local network only, the camera account and the Third-Party Compatibility setting of the Tapo app are needed; battery cameras and hub cameras are not supported.
- Plex: a claimed server, a token pasted once, away from home through a port forwarding only, no plex.tv relay.
- Network shares: SMB 2 and 3 only; WebDAV Basic authentication; the local network permission on iOS.
- Android TV: a viewer; backup, uploads and editing are hidden; sign in with an email and a password (no OAuth on a TV).
- Windows: a preview without installer or automatic update, unsigned (SmartScreen asks once), a dedicated graphics chip recommended for 5.7K and 8K 360° videos.
- The Immich server and account are optional; "Use without a server" is on the login page.

Last updated: 12 October 2026 (build 23, desktop build 4).
