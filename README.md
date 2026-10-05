<p align="center">
  <img src=".github/readme/banner.png" width="760" alt="Immuch360: 360°, 3D and VR180 photos and videos, from Immich, your phone or a NAS. Android, iOS and Meta Quest 3, with or without a server">
</p>

<p align="center">
  <b>The Immich mobile app, with 360° photos and videos you can look around in, and a free media player for flat, 360°, 3D and VR180 photos and videos.</b><br>
  Android phones and tablets, iPhones and iPads, and the Meta Quest 3 and 3S. From your Immich server, your phone or a NAS share. Same server, same account, no server plugin needed.<br>
  <sub>Unofficial fork. Not affiliated with Immich or FUTO.</sub>
</p>

<p align="center">
  <a href="https://play.google.com/store/apps/details?id=com.aprogsys.immuch360"><b>Google Play</b></a> &nbsp;·&nbsp;
  <a href="https://github.com/freeKC/Immuch360/releases">Android APK</a> &nbsp;·&nbsp;
  App Store: <a href="#where-to-get-it">under review</a> &nbsp;·&nbsp;
  Meta Quest 3: <a href="#meta-quest-3">APK</a>, Horizon Store under review
</p>

<table align="center">
  <tr>
    <td align="center" width="33%"><h3>🌐 Native 360°</h3>Photos and videos as a sphere you look around in, with the gyroscope, raw Insta360 files included (from build 16). A free video player too: flat, 360°, 3D, VR180</td>
    <td align="center" width="33%"><h3>👓 Native 3D</h3>Stereoscopic 360° and VR180, top/bottom or side by side: true 3D in the headset, one eye on a phone</td>
    <td align="center" width="33%"><h3>🎥 Native 2.5D</h3>Depth on a flat screen from a stereoscopic video, the view follows your head (experimental, phones and tablets)</td>
  </tr>
  <tr>
    <td align="center"><h3>📱 Android, iOS, Meta Quest 3</h3>One app, three platforms, true 3D in the headset</td>
    <td align="center"><h3>🔌 With or without a server</h3>Your Immich server, or the phone's own gallery, no account needed</td>
    <td align="center"><h3>🗄️ Network shares</h3>Samba (SMB) and WebDAV found on the network and read live, nothing downloaded, and sent to Immich when you choose (from build 15)</td>
  </tr>
</table>

## Why this fork exists, in one table

Everything the official Immich mobile app does is here, with two small changes from build 15: the "Force original video" switch became a **Video source** choice that can check what the device decodes, and photos and videos you upload by hand from a device album now count as backed up. On top of it, Immuch360 adds what the official app still lacks for 360° and 3D media:

| | Immich mobile app | Immuch360 |
|---|:---:|:---:|
| 360° photos as a sphere you can look around in | ❌ flat strip | ✅ drag, pinch, double tap, inertia |
| Gyroscope: look around by moving the phone | ❌ | ✅ |
| 360° videos in a spherical player (Android and iOS) | ❌ flat video | ✅ with sound and gyroscope |
| 3D (stereoscopic) 360° photos and videos | ❌ doubled picture | ✅ left eye on phones, true 3D on the Quest 3 |
| VR180 (half sphere) photos and videos | ❌ stretched around the sphere | ✅ half sphere, 360°/180° button |
| Meta Quest 3 immersive view with head tracking, a time bar and previous/next | ❌ | ✅ same app, as a headset build or the phone APK |
| 360° badge on the thumbnails of 360° photos, and a 360° list of photos and videos in the Library tab | ❌ | ✅ |
| "View as 360°" for files the server does not flag | ❌ | ✅ remembered on the phone |
| Spatial 2.5D for stereoscopic videos: depth on a flat screen, the view follows your head (front camera, on device, phones and tablets) | ❌ | ✅ experimental |
| Works without any server, on the phone's own gallery | ❌ login required | ✅ "Use without a server" on the login page |
| Network shares (SMB, WebDAV): photos and videos of a NAS played live, nothing downloaded | ❌ | ✅ in every viewer, phones and Quest 3 |
| Send the photos and videos of a network share to your Immich account | ❌ | ✅ from build 15 |
| Raw camera files stitched on the device: Insta360 .insp and .insv (one or two tracks, or a pair of files), GoPro .360, DJI Osmo 360 .osv | ❌ two circles side by side, flat | ✅ from build 16, every layout from build 18 |
| Server videos: the original when the device decodes it, else the server's transcoded stream; list of the device's video decoders | ❌ one "Force original video" switch | ✅ from build 15 |
| A video player for flat, 360°, 3D and VR180 files, from the server, the phone or a NAS, free | ❌ flat only | ✅ (the Quest 3 store players are paid) |
| Same server, same account, installs next to the official app | | ✅ |

## Who it is for

You back up your photos to an [Immich](https://github.com/immich-app/immich) server and some of them come from a 360° camera (Insta360, GoPro Max, Ricoh Theta, Samsung Gear 360) or from the photo sphere mode of a phone. In the official mobile app those pictures show up as a flat, stretched strip, and 360° videos play flat too. The web app can show a 360° photo as a sphere, the mobile app cannot (requested since January 2024 in [discussion #6572](https://github.com/immich-app/immich/discussions/6572)).

Immuch360 is that mobile app with the missing parts added. The name reads as "I am much 360".

Stitched 360° files work everywhere: exports from the Insta360 app or Studio, GoPro Player, Ricoh Theta, and phone photo spheres. From build 16 the raw Insta360 files work too, without the Insta360 app: .insp photos and the .insv videos that keep both lenses in one track are stitched by the app itself, and from build 18 so are the .insv videos with two tracks (X4, X4 Air, X5, X6), the pairs of files of the X3 and older at 5.7K and above, the GoPro .360 of the MAX and MAX 2 and the DJI Osmo 360 .osv (see [Raw 360° camera files](#raw-360-camera-files)). Dual fisheye .dng still shows flat.

## What you get

| Regular viewer | 360° button |
|---|---|
| <img src=".github/readme/phone-flat.png" width="170" alt="The same photo in the regular viewer, flat"> | <img src=".github/readme/phone-sphere.png" width="170" alt="The photo as a sphere in Immuch360"> |
| A 360° photo shown flat | The same photo as a sphere you can turn, zoom, and follow with the phone's gyroscope |

| Library tab | 360° list | On an iPad | 360° list on an iPad |
|---|---|---|---|
| <img src=".github/readme/library-360.png" width="170" alt="The 360° entry of the Library tab"> | <img src=".github/readme/library-360-list.png" width="170" alt="Only the 360° photos and videos"> | <img src=".github/readme/ipad-sphere.jpg" width="200" alt="A 360° photo as a sphere on an iPad"> | <img src=".github/readme/ipad-library-360.jpg" width="200" alt="The 360° list on an iPad"> |
| A 360° entry next to Favorites | Only your 360° photos and videos, newest first | The sphere viewer on an iPad (iOS build) | The 360° list on an iPad |

- **360° photos** open as an interactive sphere: drag to look around, pinch to zoom, double tap, inertia, the initial view the camera recorded, sharper texture when zoomed in. Partial panoramas are handled.
- **Gyroscope**: turn the phone to look around (toggle in the viewer).
- **360° videos on Android and iOS**: a native spherical player with sound, drag and gyroscope (a time bar on Android; play and pause only on iOS for now). It plays the file stored on the phone, or the file of a network share, when there is one. Otherwise it streams from your server: the transcoded stream by default, or the original if you ask for it in Settings, Asset Viewer (the **Video source** choice from build 15, the **Force original video** switch before).
- **View as 360°**: some 360° files carry no projection tag, so the server shows them flat. The viewer menu can force the 360° view for a photo or a video; the choice is remembered on the phone and changes nothing on the server. On a file of a network share it applies to that viewing only.
- **3D (stereoscopic) 360° photos and videos**: top and bottom or side by side layouts are recognised from the file (or guessed from its shape) and can be changed with the 3D button in every viewer. A phone shows the left eye; the Meta Quest 3 shows each eye its own half, in real 3D.
- **Raw camera files (from build 16, every layout from build 18)**: Insta360 .insp photos and .insv videos (one track, two tracks or a pair of files), GoPro .360 and DJI Osmo 360 .osv straight from the camera's card open as a 360° sphere, stitched on the device from the calibration the camera writes in the file. See [Raw 360° camera files](#raw-360-camera-files).
- **VR180 (half sphere)**: files that cover only the front half are drawn on a half sphere, with the back black instead of a stretched picture. Recognised from the file (spherical bounds or mesh, GPano crop) or from a "vr180" or "180" in the name, and switchable with a 360°/180° button in every viewer; the choice is remembered on the phone, but not yet for the files of a network share.
- **Meta Quest 3 and 3S**: the same Android app runs on the headset as a window, and the 360° button switches to an immersive view where the photo or video is all around you, and you look around by turning your head. There, a video has a time bar with 10 second skips, previous/next moves through the 360° media of the place you came from without leaving the immersive view, and the right thumbstick turns the view so that you can look behind without turning your head. See [Immersive view](#immersive-view).
- **Find them**: a 360° badge on the thumbnails of 360° photos (in a network share folder, on 360° videos too), and a **360°** entry in the Library tab. From build 18 that list holds, with a server, the photos and videos the server flags as 360°, the raw Insta360 files by their name, the camera stitched photos of a 360° camera and the ones you chose to view as 360°, plus what the device scan found; without a server, what the device scan found. Filters at the top: period (year, month, custom range), source (server, device, shared with you), type (photos, videos, 3D, VR180) and camera (from the EXIF make and model, with counts). The previous/next of the Quest immersive view follows the filtered list.
- **Use without a server**: on the login page, "Use without a server" opens the app on the phone's own gallery, with the 360°, 3D, VR180 and Spatial viewers and the 360° list, no Immich account needed. The server features stay hidden until you connect a server from the settings; nothing leaves the device.
- **A video player, free**: flat, 360°, 3D (side by side, top and bottom) and VR180 videos play in the native players with sound, seeking (the iOS 360° player has play and pause only for now), the audio track of your choice (languages, commentary, in the 360° and Spatial players), a buffering indicator, gyroscope and head tracking, whether they come from the Immich server, the phone's own gallery or a network share. From build 15, Settings, Asset Viewer, **Video source** chooses which file of a server video plays: the original when the device decodes it, always the original, or always the server's transcoded stream; Settings, Advanced, **Video decoders of this device** lists what the device decodes. On the Meta Quest 3 this replaces the paid players of the store for your own files.
- **Network shares**: Library tab, "Network shares": the app finds the SMB and WebDAV servers of your network, you add a share, browse its folders and play its photos and videos live in the same viewers (360°, 3D, VR180, Spatial 2.5D, Quest immersive view), with or without an Immich server, nothing downloaded. When a server is connected, the photos and videos you select are sent to your Immich account (from build 15). See [Network shares](#network-shares).
- **Everything else is Immich**: backup, timeline, albums, search, sharing, partners, all synced with your server. The two differences, from build 15: a **Video source** choice in place of the "Force original video" switch, and photos and videos uploaded by hand from a device album counted as backed up.

## A media player too

Immuch360 is a gallery, and it is also a free media player: it plays what the official app cannot, from three sources, in the player that fits the file. On the Quest 3 the store players for 360° and 3D video are paid; this one is free and open source.

| What | Android phones | iPhone, iPad | Meta Quest 3 |
|---|---|---|---|
| Flat videos (MP4, MOV, MKV, what the device decodes) | Immich player, and a native player for network shares | Same, except the MKV and AVI files of a share, which iOS does not open (on a server they play transcoded) | In the window |
| 360° photos | Sphere viewer, gyroscope | Same | Immersive, all around you |
| 360° videos | Native Media3 player on a sphere, gyroscope, seeking, audio track choice, buffering indicator | Native SceneKit player on a sphere, gyroscope, audio track choice, buffering indicator; play and pause, no time bar yet | Immersive, true 3D for stereoscopic files, time bar with 10 second skips, previous and next media |
| 3D 360° (top and bottom, side by side) | Left eye, layout button | Same | Each eye gets its own half of the frame |
| VR180 (half sphere) photos and videos | Half sphere, 360°/180° button | Same | Immersive half sphere |
| Spatial 2.5D (flat screen depth from a stereoscopic video) | Native player, head tracking with the front camera | Same | Not offered: a flat (not 360°) stereoscopic video plays in the window with both eyes visible; the immersive 3D view is for 360° and VR180 media |
| Raw Insta360 .insp photos (from build 16) | Stitched on the GPU before the sphere viewer, up to 8192x4096 | Same | Immersive, from a stitched picture prepared for the headset |
| Raw Insta360 .insv (both lenses in one track, from build 16) | Stitched by a GPU effect in the Media3 player | Stitched by a SceneKit shader | Immersive, stitched by the same GPU effect |
| Raw videos with one lens per track or per file (from build 18): Insta360 X4, X4 Air, X5, X6 .insv, X3 pairs, GoPro .360, DJI .osv | Two hardware decoders at once, one per lens, and a GL compositor that stitches into the sphere; one lens, then the transcoded stream, when the device cannot run two | A custom AVFoundation compositor with Metal | Immersive, same two decoders and compositor (3840x1920 panel) |

| From | How |
|---|---|
| Your Immich server | The original or the server's transcoded stream, as Settings, Asset Viewer, **Video source** says (from build 15): the original when this device decodes it, always the original, or always the transcoded stream. Until you pick one, a phone keeps what the former "Force original video" switch said (off by default: the transcoded stream, which is the original itself when the server did not transcode it), and the Quest plays the original when the headset decodes it. A player that cannot decode the original switches to the transcoded stream with a message. Same account as the web app |
| The phone or headset itself | "Use without a server" on the login page, or the "On this device" entry of the Library tab |
| A NAS or a computer | Samba (SMB) and WebDAV shares, found on the network, read live (an SMB video over up to six connections), nothing copied; from build 15 the files you pick can be sent to your Immich account |

From build 15, Settings, Advanced, **Video decoders of this device** lists what the phone or headset decodes (codec, largest size, frame rate, and from build 18 the profiles: Main, Main 10, HDR10), with a Copy button for bug reports. The technical details of a video show its codec and profile, from build 18 its bit rate, its picture (bit depth, HDR transfer such as HLG or PQ, colour space) and whether this device decodes that profile; the check before playing a raw two lens video asks for two decoders at once.

| 360° photo in the headset | 360° video in the headset | 3D 360° video in the headset |
|---|---|---|
| <img src=".github/readme/quest-immersive-360-photo.jpg" width="300" alt="A 360° photo all around you in the Quest 3, with the info panel: layout, 360° and Back buttons"> | <img src=".github/readme/quest-immersive-360-video.jpg" width="300" alt="A 360° video of a lake playing in the Quest 3, with the info panel: layout, 360°, Pause and Back buttons"> | <img src=".github/readme/quest-immersive-3d-360-video.jpg" width="300" alt="A stereoscopic 360° video in the Quest 3, the info panel reading 3D, top and bottom"> |
| The immersive view of a photo, with the info panel (layout, 360°/180°, Back) | A video playing, with Pause | A top and bottom stereoscopic video, each eye served (the Kandao Obsidian sample) |

These captures were taken with the app in French, before build 14. The panel now also has a time bar between two 10 second skip buttons, Previous and Next, and Turn, and the thumbstick seeks in a video or moves to the previous or next media, all without leaving the immersive view (the 360° media of the timeline, the 360° list, an album, a share folder or the headset's own media). See [Immersive view](#immersive-view).

## Raw 360° camera files

Insta360 cameras write two fisheye circles side by side (an .insp is a JPEG, an .insv an MP4) and the official way to get a 360° picture out of them is the Insta360 app or Studio. The Immich web app takes any .insp for an equirectangular picture and wraps the two circles around the sphere; the mobile app shows them flat. From build 16 Immuch360 stitches those files itself, on the phone, the tablet or the headset, with nothing to install on the server.

- **What the app reads**: the calibration block the camera appends to every file (lens model, centres, orientation of each lens, size of the calibration canvas) and the accelerometer record, used to level the horizon. The Mei (unified camera) model of the calibration string V3 is used first, V6 (X6 and later firmware) with its first terms next, the older equidistant string V1 last. Nothing is guessed from the camera model when the file has its calibration.
- **Where it works**: the server (original file, read with a range request for its last bytes), the device's own gallery, SMB and WebDAV shares. Raw files of the server get the 360° button, and raw photos the badge, but they are not in the 360° list of the Library tab yet, which only lists what the server flags as 360°. Photos are stitched by a Flutter fragment shader before the sphere viewer, at up to 8192x4096, with a CPU fallback at a smaller size. Videos go to the native players with the calibration: a Media3 GL effect on Android and the Quest, a SceneKit shader on iOS. The Quest immersive view gets a stitched temporary picture for photos and the GL effect for videos. If the GPU effect cannot run on a device, the video plays unstitched, the two circles on the sphere.
- **What the label says**: the sphere viewer of a raw photo shows "stitched by the app" with the source of the calibration: this file, a calibration kept from another file of the same camera (by its serial number, or by its model for a file that only names its model), or the nominal values of an X3 when nothing better is available (seams may show then). The video players and the headset show no label.
- **Two lenses in two tracks or two files (from build 18)**: the .insv videos of the X4, X4 Air, X5 and X6 hold one square track per lens, the X3 and older write two files (`_00_` and `_10_`) at 5.7K and above, the GoPro MAX and MAX 2 .360 hold two tracks of three cube faces each (with the overlap columns blended), and the DJI Osmo 360 .osv two square 10 bit tracks with a Kannala-Brandt calibration in the file. The players decode both tracks at once, one hardware decoder per lens, paired by time stamp, and a GPU compositor stitches them into the sphere (Android and the Quest with ExoPlayer and OpenGL ES 3, iOS with an AVFoundation compositor in Metal). The other file of a pair is found next to the first one, on the device, on the server or in the share folder. Before playing, the app asks the device whether it can run two decoders of that size and rate; when it cannot (two 2880x2880 H.264 lenses on a Quest 3, for example), it plays one lens and says so (half of the sphere stays black), then the server's transcoded stream if there is one. 10 bit HLG and PQ sources are tone mapped to the 8 bit sphere. The Insta360 X5 and X6 calibration (V6, indexed trailer) and the X4 video window are read from the file; GoPro and DJI files are not levelled (the camera's horizon is kept).
- **Known limits**: the stitch uses the camera's calibration only, without seam optimisation, so objects close to the camera can show a seam, as in the camera's own preview. Levelling uses the accelerometer the camera records in the file, averaged; a video is levelled once, from the start of the recording, and is not stabilised, so a handheld video keeps its shakes and its horizon may lean a little. A photo taken with the camera lying flat may open facing an odd direction: drag it on a phone, or use the Turn button in the headset. A file without its calibration block (the members `_008` and `_009` of an X3 HDR group) uses the calibration the app kept from another file of the same camera or the same camera model, or the nominal X3 values if it has seen none. The check against Insta360 Studio was done on X3 photos (same framing, level horizon, a yaw offset under a degree). The two track and two file paths were checked on real X4, X3 pair, GoPro MAX and Osmo 360 files with the app's CPU reference stitcher (level, continuous seams) and on the Android unit tests; playback on a phone, a Quest and an iPhone is the device test of build 18, feedback welcome. The Immich server refuses .360 and .osv uploads, so those two formats only exist on the device and on shares.

## Spatial 2.5D (experimental)

A stereoscopic video can gain depth on a flat screen. The two eyes of the video give the depth, the front camera follows your head, and the app synthesises the view in between, so the screen behaves like a window on the scene: move your head and nearby objects shift against the background.

- **Formats**: side by side and top and bottom, also with the eyes swapped, full or half width, flat, 360° and VR180. The layout is read from the file, else guessed from the frame shape or the file name (sbs, ou, tb and the like; a half width file is only recognised by its name), and can be chosen by hand in the player. The choice is remembered for a video of the library, not for a file of a network share.
- **How to enable**: it is on by default; the switch is in Settings, Asset Viewer, Videos, "Spatial 2.5D (experimental)" (phones and tablets only). While it is on, the viewer shows a Spatial button on every video; in a network share folder only stereoscopic files get the button, the others have it in the ⋮ menu. The camera is only used once you press that button.
- **Camera**: the front camera permission is asked only when you use the mode. Images are processed on the device only, never stored and never sent anywhere. The Quest 3 build has no camera permission at all (the headset has no camera an app may use), and the Spatial player is not offered there: its button and its setting are hidden on the headset.
- **Limitations**: experimental, phones and tablets only (not on the Meta Quest), needs OpenGL ES 3.0 or Metal. The depth is an estimate. It works best in landscape with your face well lit.
- **Fallback**: if anything goes wrong (no camera, unsupported device, unreadable layout), you are back in the normal player.

## Network shares

The photos and videos of a NAS, a computer or any server that speaks SMB (Samba, Windows) or WebDAV can be browsed and played straight from the share, with or without an Immich server, on phones and on the Meta Quest 3.

- **Add a share**: Library tab, **Network shares**, then the + button. The form first looks for the servers of your network by itself (Bonjour/mDNS and a scan of the local network, confirmed by a real SMB or WebDAV exchange) and lists them under **Found on the network**: tap one and the type, server, port and path are filled. Otherwise pick SMB or WebDAV, give the server (a name or an address; a full address such as `smb://nas/photos`, `\\nas\photos` or `https://nas:5006/photos` fills the other fields), the port if it is not the usual one, the share name (SMB) or the path (WebDAV), an optional start folder, the user name and password, and TLS for WebDAV. For SMB, **Choose a share** lists the shares of the server once the user name and password are typed. **Test the connection** checks it before you save.
- **Browse**: folders first, then the photos and videos as a grid with thumbnails (a frame of each video too, cached on the device); the ones recognised as 360° carry the badge. Pull down to refresh.
- **Play**: a photo opens full screen (pinch, double tap), and its **360°** button opens the sphere viewer; a video plays in the native player (play, pause, seeking), with a **360°** button that opens the 360° player and its **3D** and 360°/180° buttons, and on a phone a **Spatial** button for stereoscopic files; on the Quest 3 the 360° button opens the immersive view. **View as 360°** is in the ⋮ menu of the files without a 360° tag, and on a phone **Spatial 2.5D** is in the menu of the videos that are not stereoscopic. 360°, 3D and VR180 are recognised from the GPano or spherical metadata of the file, read with range requests, and VR180 also from the file name; from build 16 raw Insta360 files are recognised too (an .insp photo by its name or the camera's calibration block, an .insv video by its name and its frame) and stitched.
- **Nothing is downloaded**: the players read the bytes they need through a bridge inside the app (loopback address only, random token per session, byte ranges), so seeking in a video works and nothing is copied to the device. For smooth playback the share is read in large blocks, the file stays open between reads, up to 16 MB are read ahead of the player, and the video being played is read over up to six SMB connections in parallel (a Freebox Server answers each read slowly: one connection gives 4.5 MB/s, six give 19 MB/s, enough for a 5.7K export at 132 Mbit/s), separate from the connection that serves thumbnails and listings. While the player waits for data, the 360° and Spatial players show "Buffering" with the fill of their playback buffer; the flat player shows "Buffering" without a percentage while the video loads or stalls.
- **Upload to Immich** (from build 15): when you are connected to a server, long press a photo or video of a share folder (or use **Select** in the toolbar), tick what you want, **Select every photo and video of this folder** if you like, then **Upload to Immich**. The files are streamed from the share to your server, one at a time, with the progress on each tile; the server keeps its own copy and deduplicates files it already has. Keep the app open while it sends. Files sent earlier carry a mark and are skipped the next time. The open photo or video has the same entry in its menu. Photos and videos of the device are sent the same way from the Library tab (**On this device**, an album, select, **Upload to Immich**), including those of albums that are not in the backup selection; once sent they are counted as backed up.
- **Privacy**: the share list is kept on the device and never sent to a server; passwords go to the device keychain or keystore.
- **Freebox and other boxes**: a user name with an empty password is sent as such (a Freebox Server wants `freebox` and no password for its disks).
- **Limitations**: SMB 2 and 3 only (no SMB 1); WebDAV with Basic authentication (Digest is not supported yet); a self signed HTTPS certificate must be installed on the device; the network scan looks at the local /24 network only and needs the local network permission on iOS; photo thumbnails decode the whole file (none for photos over 30 MB); the audio track choice is not available in the flat player yet; on a phone there is no swiping from one file of a folder to the next yet (the Quest immersive view has previous and next for the 360° files of the folder); the 3D or 180° choice made on a network file is not remembered; uploads run only while the app is open, and a file the server already has is sent in full before the server reports it as a duplicate.

## Where things are, in pictures

Screenshots from the Android build on an emulator, with synthetic test media. The settings page is a current capture; the other pictures come from build 5, before the 360°/180° and Audio track buttons were added. The text below describes the current build.

| In the viewer | In the ⋮ menu |
|---|---|
| <img src=".github/readme/video-viewer-spatial-button.png" width="220" alt="The viewer top bar of a stereoscopic video: the Spatial button (a rotating 3D icon) next to the favourite button and the menu"> | <img src=".github/readme/menu-view-as-360.png" width="220" alt="The viewer menu with the View as 360 degrees entry between Slideshow and Download"> |
| The top bar of a stereoscopic video. From the left: back, date, the **Spatial** button (rotating 3D icon, on every video while the setting is on, phones and tablets only), favourite, and the ⋮ menu. On a 360° photo or video the **360°** button comes first; a 360° video shows both. | The ⋮ menu of a photo the server does not flag as 360°: **View as 360°** sits between Slideshow and Download. Once chosen, the entry becomes **Stop treating as 360°** and the 360° button appears in the top bar. The rest of the menu is stock Immich. |

| The sphere viewer | The settings |
|---|---|
| <img src=".github/readme/sphere-3d-button.png" width="220" alt="The sphere viewer: close at the top left, the 3D layout button and the gyroscope button at the top right"> | <img src=".github/readme/settings-spatial.png" width="220" alt="The Asset Viewer settings page: Looping, the Spatial 2.5D (experimental) switch and the three Video source choices"> |
| A 360° photo opened as a sphere: close at the top left; at the top right the **360°/180°** button (full sphere or VR180 half sphere, not shown on partial panoramas), the **3D** button (cycles mono, top and bottom, side by side; its tooltip names the current layout) and the **gyroscope** toggle (off by default). A raw Insta360 photo has only the gyroscope, and a label at the bottom says it was stitched by the app. The Android and iOS 360° video players have the 360°/180° and 3D buttons too; the iOS one has a gyroscope toggle, on by default, and the Android one always follows the phone. | Settings, Asset Viewer, Videos: **Spatial 2.5D (experimental)**, on by default (phones and tablets only), then **Video source** (the original when this device decodes it, always the original, or always the transcoded stream). Turning Spatial off removes the Spatial button everywhere. The troubleshooting overlay of the Spatial player follows Settings, Advanced, Troubleshooting. |

<img src=".github/readme/spatial-player.png" width="760" alt="The Spatial player in landscape with the troubleshooting overlay: layout and Recenter buttons at the top right, the viewpoint slider and the head sensitivity at the bottom">

The Spatial player, here with the troubleshooting overlay on (Settings, Advanced, Troubleshooting). Top right: **Audio track** when the video has two or more, the current **layout** (tap for the list: auto, not stereoscopic, side by side, top and bottom, each of the last two also with the eyes swapped), **360°/180°** on a 360° video, and **Recenter** (takes your current head position as the centre). Bottom: play, the timeline, then the **head sensitivity** (while your head is tracked), the **viewpoint slider** from L to R (moves the viewpoint by hand; it shows when head tracking is off or has lost your face, and always with the overlay) and, with the overlay only, the **Disparity map** check box that shows the estimated depth instead of the picture. The overlay at the top left lists the render and disparity rates, the quality tier, the viewpoint and the tracking state. Close with the cross or the system back.

## Where to get it

The app is on Google Play; the App Store version is waiting for Apple's review, and the Meta Horizon Store version for Meta's. The GitHub release is always the newest build:

| Platform | Today | Soon |
|---|---|---|
| Android phones and tablets | [Google Play](https://play.google.com/store/apps/details?id=com.aprogsys.immuch360), or the APK on the [Releases](https://github.com/freeKC/Immuch360/releases) page: `Immuch360-v<version>-arm64-v8a-release.apk` for a phone (the universal `Immuch360-v<version>-release.apk` works everywhere, `-armeabi-v7a` is for older 32 bit phones, and the `.aab` file is for Google Play, not for sideloading). The GitHub build is usually ahead of the store. Either way it installs next to the official Immich app (package `com.aprogsys.immuch360`). | Google Play: builds 15 and 16 sent for Google's review on 4 October 2026 (the last build confirmed live there is build 11) |
| iPhone and iPad | Waiting for Apple's review. The version under review carries the features of build 11: the upload to Immich and the Video source choice (build 15) and the raw Insta360 files (build 16) will come with a later App Store update. The source builds with Xcode or on Codemagic, see [Build it yourself](#build-it-yourself). | App Store, under review |
| Meta Quest 3 and 3S | The `-quest-release.apk` file of the [Releases](https://github.com/freeKC/Immuch360/releases) page (the universal `-release.apk` works too), sideloaded in developer mode, see [Meta Quest 3](#meta-quest-3). The store build and the GitHub APK are signed with different keys: to switch from one to the other, uninstall the app first (its settings and saved shares go with it). | Meta Horizon Store: build 14 under Meta's review since 3 October 2026; build 16 is on the store's alpha channel (testers only) |

The App Store and Meta Horizon Store links will be added here as soon as the listings are published. Log in with your usual Immich server URL and account, or tap **Use without a server** on the login page to start on the device's own photos and videos. The current build is based on Immich 3.3.0-rc.0 (Immich `main`, not a stable release yet) and was tested with an Immich 3.2 server. The APK from GitHub does not update itself: watch the Releases page, and once you have installed the app from a store, take the updates from that store. Please report problems in [Issues](https://github.com/freeKC/Immuch360/issues), not to the Immich project.

## What this fork adds compared to Immich, in detail

| Feature | Immich mobile app | Immuch360 | Status |
|---|---|---|---|
| 360° photos (equirectangular) shown as an interactive sphere | ❌ No, flat image only | ✅ **Yes**, drag to look around, pinch to zoom, partial panoramas handled (GPano crop) | Tested on a Galaxy S24+ and an iPhone 14 |
| 360° badge on the thumbnails of 360° photos (and of 360° videos in a network share folder) | ❌ No | ✅ **Yes** | Done |
| 360° button in the viewer top bar, zoom kept on the flat view, loading indicator | ❌ n/a | ✅ **Yes** | Done |
| Gyroscope navigation: look around by moving the phone | ❌ No | ✅ **Yes**: toggle in the 360° photo viewer (off by default) and in the iOS 360° video player (on by default); the Android 360° video player always follows the phone | Tested on a Galaxy S24+ and an iPhone 14 |
| Initial view from GPano metadata, inertia after a drag, double tap zoom, sharper texture when zoomed in | ❌ No | ✅ **Yes** | Tested on a Galaxy S24+ and an iPhone 14, device feedback welcome |
| 360° entry in the Library tab listing the photos and videos the server flags as 360° (without a server, the 360° files found on the device and those marked View as 360°) | ❌ No | ✅ **Yes** | Done |
| 3D (stereoscopic) 360° photos and videos, top and bottom or side by side | ❌ No | ✅ **Yes**: layout read from the file (st3d) or guessed from its shape, 3D button to change it; left eye on phones, true 3D on the Quest | Tested on a Galaxy S24+ and a Quest 3 with real 3D 360° sample videos (VRTogether, Vuze, Kandao) and a 3D photo; other camera feedback welcome |
| 360° videos played on a sphere with drag and gyroscope | ❌ No, flat video only | ✅ **Yes on Android and iOS** (native player opened by the 360° button, Media3 on Android and SceneKit on iOS; plays the file stored on the phone, a file of a network share, or your server's original or transcoded stream) | Tested on a Galaxy S24+ and an iPhone 14 |
| Video source chosen from what the device decodes: the original, or the server's transcoded stream when the original is beyond the hardware decoders (H.264 above 4096x2304 on a Quest 3, for example); **Video source** setting and a **Video decoders of this device** page | ❌ A "Force original video" switch only | ✅ **Yes** from build 15, for every server video (flat player, 360° and Spatial players, Quest immersive view), with a message when it switches | Tested on an Android emulator; the Quest 3 H.264 limit was measured on the headset |
| Meta Quest 3 viewer with head tracking | ❌ No | ✅ **Yes**: the Quest build (or the universal phone APK) opens 360° and VR180 photos and videos all around you, in true 3D for stereoscopic files (Meta Spatial SDK) | Tested on a Quest 3, and by a user with Insta360 X4 8K HEVC videos |
| Spatial 2.5D for stereoscopic videos (head coupled depth on a flat screen) | ❌ No | ✅ **Yes**, experimental, on by default, switch in the settings | Experimental; tested on a Galaxy S24+, iPhone feedback welcome |
| "View as 360°" for photos and videos the server does not flag as 360° | ❌ No | ✅ **Yes**, in the viewer menu, remembered on the phone | Done |
| VR180 (half sphere) photos and videos | ❌ No, stretched around the sphere | ✅ **Yes**: spherical bounds, mesh, GPano crop or file name, 360°/180° button in every viewer, remembered on the phone (not yet for network share files) | Tested on an Android emulator and a Galaxy S24+ with synthetic media; device feedback welcome |
| Use without an Immich server (local gallery, 360° detection on the device, all viewers) | ❌ No | ✅ **Yes**, from the login page; connect a server later from the settings | Tested on a Galaxy S24+, a Quest 3 and an Android emulator |
| Network shares: SMB (Samba) and WebDAV browsed and played live, nothing downloaded; servers found by themselves on the network | ❌ No | ✅ **Yes**: from the Library tab, every viewer, with or without a server, phones and Quest 3 | Tested with a Freebox Server (SMB) on a Galaxy S24+ and a Quest 3, and against Samba and WebDAV test servers on an Android emulator; other NAS and WebDAV feedback welcome |
| Upload to Immich from a network share, and device files sent by hand counted as backed up | ❌ No, device files only | ✅ **Yes** from build 15: select files of a share folder (or the whole folder), then **Upload to Immich**; streamed to the server one at a time, duplicates detected, files sent earlier marked and skipped | Tested on an Android emulator against a Samba test server and an Immich 3.2 server |
| Media player controls: seeking, audio track choice and a buffering indicator in the 360° and Spatial players (the iOS 360° player has no time bar yet); seeking and buffering in the flat player of network shares; time bar, 10 s skips, previous/next media and a Turn button in the Quest immersive view | ❌ n/a | ✅ **Yes**, Android, iOS and Quest 3 | Immersive controls tested on a Quest 3 (build 14); build 16 adjusts them after a user's feedback, headset feedback welcome |
| Raw Insta360 files (.insp photos, single track .insv videos) | ❌ Shown flat (the web app wraps the two circles around a sphere) | ✅ **Yes** from build 16: stitched on the device from the calibration in the file, levelled with the camera's accelerometer, no server change | Photos checked against Insta360 Studio exports of X3 files, videos on an Android emulator with a low resolution X3 file; not run on an iPhone yet, feedback welcome |
| Raw videos with one lens per track or per file: Insta360 .insv of the X4, X4 Air, X5 and X6, X3 pairs at 5.7K and above, GoPro .360 (MAX, MAX 2), DJI Osmo 360 .osv | ❌ Shown flat or wrongly (the server refuses .360 and .osv) | ✅ **Yes** from build 18: two decoders at once and a GPU compositor on Android, the Quest and iOS; one lens or the transcoded stream when the device cannot run two | Parsers and stitching math checked on real X4, X3 pair, GoPro MAX and Osmo 360 files; playback is the device test of build 18, feedback welcome |
| Dual fisheye .dng | ❌ Shown flat | ❌ Not yet | Planned |
| 360° list of the Library with the raw and camera stitched files and filters (period, source, type, camera) | ❌ No such list | ✅ **Yes** from build 18 | Done |
| Technical details of a video: bit rate, bit depth and HDR transfer, profile, whether this device decodes it; decoder profiles in the decoders page | ❌ Codec only | ✅ **Yes** from build 18 | Done |

The 360° photo viewer is based on the upstream pull request [immich-app/immich#31169](https://github.com/immich-app/immich/pull/31169) by dmitry-brazhenko, itself built on the prototype by bencefr in [#30192](https://github.com/immich-app/immich/pull/30192). Thanks to both.

## Why a fork

360° viewing on mobile has been requested since January 2024 and is not in the official app yet; the photo viewer is under review upstream in [#31169](https://github.com/immich-app/immich/pull/31169). This fork ships it now, gathers real device feedback, and will offer back to Immich, in small pull requests, whatever the maintainers want. The Meta Quest view relies on the Meta Spatial SDK, which is not open source, so it stays in this fork.

## Meta Quest 3

Immuch360 also runs on the Meta Quest 3 and 3S (Horizon OS v69 or later; the Horizon Store build is listed for these two only; the universal `-release.apk` should also install on a Quest 2 or Quest Pro, untested). The headset build only talks to servers over HTTPS, or over plain HTTP to names of the home network (`.local`, `.lan`, `.home`, `.internal`, `.home.arpa`) and to the headset itself, as the Horizon Store requires. A server typed as a plain HTTP address with an IP, such as `http://192.168.1.10:2283`, is refused by that build: use HTTPS, a home network name (`nas.local`), or the universal `-release.apk`, which keeps the open policy of the phones. Sideload the `-quest-release.apk` file of a release (built for the headset: 64 bit, target SDK 34, only the permissions the headset uses, see [Limitations](#limitations)), or the universal `-release.apk`. The Horizon Store listing is waiting for Meta's review, submitted with build 14; until it is approved, sideload the APK as below.

### Install

1. Enable developer mode once. In the Meta Horizon phone app, open Devices, select the headset, then Headset settings, then Developer mode. This needs a developer account, which is free at developers.meta.com. You also need adb (Android SDK Platform Tools) on the computer, or SideQuest.
2. Connect the headset to a computer with a USB-C cable. In the headset, accept "Allow USB debugging".
3. Install the APK:

   ```bash
   adb devices                      # the headset must be listed as "device"
   adb install -r Immuch360-v<version>-quest-release.apk   # for example Immuch360-v3.3.0-rc.0-16-quest-release.apk
   ```

4. In the headset, open the Library, choose the "Unknown sources" filter, and start Immuch360.
5. A sideloaded APK does not update itself: install the next release the same way (`adb install -r` keeps the login and the settings). The Horizon Store version and the GitHub APK are signed with different keys, so the headset refuses one over the other: to switch, uninstall the app first, which loses the login, the settings and the list of network shares.

### In the window

The whole app runs as a resizable 2D window: login, timeline, albums, search, the Library tab (360° list, On this device, Network shares), the settings, and the photo and video viewers, where flat photos and videos play. On the headset the 360° button, and View as 360° in the ⋮ menu, open the immersive view directly instead of the sphere viewer of phones, and the Spatial 2.5D button and its setting are not shown.

### Immersive view

1. Open a 360° photo or video in the viewer.
2. Press the 360° button. The app switches to an immersive view where the media is all around you, and you look around by turning your head.
3. To go back to the window, press B or Y, or the Back button of the info panel.

| Action | Controllers | Hands |
|---|---|---|
| Back to the app | B or Y | Back button of the info panel |
| Play or pause a video | Trigger, when the info panel is hidden | Play or Pause button of the info panel |
| Show or hide the info panel | A, X, grip or menu | Menu gesture, or pinch when the panel is hidden |
| Turn the view, to look behind without turning your head (from build 17) | Right thumbstick left or right: 30° per push, and it keeps turning while held (a one line overlay shows the angle) | Turn button of the info panel (90°) |
| Previous or next media | Left thumbstick left or right (either stick before build 17; from build 16 a one line overlay names the media, the info panel stays hidden) | Previous and Next buttons of the info panel |
| 10 seconds back or forward in a video | Thumbstick down or up (from build 16 a one line overlay shows the time, the info panel stays hidden) | The two skip buttons, or drag the time bar of the info panel |
| Turn the image by 90° | Thumbstick down or up on a photo (from build 16 the one line overlay shows the angle); on a video, the Turn button of the info panel | Turn button of the info panel |
| Change the 3D layout (mono, top and bottom, side by side) | 3D button of the info panel | 3D button of the info panel |
| Full sphere or half sphere (VR180) | 360°/180° button of the info panel | 360°/180° button of the info panel |

With controllers, the buttons and the time bar of the info panel work too: point at them with the ray and press the trigger.

The info panel of a video has a time bar (position, duration, how much is buffered) between two 10 second skip buttons; below it come Previous, Play or Pause and Next, then Turn, 3D, 360°/180° and Back (a photo has the same rows without the time bar and Play). Previous and next move through the 360° media of the place you came from, without leaving the immersive view: the timeline, the 360° list, an album, a folder of a network share, or the headset's own media (On this device); flat photos and videos are skipped. When you go back to the app from the timeline, an album or the 360° list, it lands on the media you were looking at (a share folder page stays on the file you opened), and the video you opened the immersive view on resumes where it left it. The 3D layout and the 360°/180° choice are on the panel's buttons only.

From build 17 the right thumbstick turns the view, the way the right thumbstick turns in most headset apps: a push turns by 30°, holding it keeps turning, so what is behind you comes in front without turning your head or your chair; previous and next are on the left thumbstick. From build 16, following a user's feedback on the headset, a thumbstick seek, turn or previous/next shows a one line overlay (the time, the angle or the title of the media) that fades after 1.5 seconds instead of bringing the info panel up; the panel still comes with A, X, the grip or the menu button. The same build keeps the panel toggle working when the controllers sleep, wake up or give way to hand tracking, and logs those transitions, see [Logs](#logs).

### In pictures

Captures taken in the headset with the capture button (Meta button and trigger), on a Quest 3, with the app in French; the Library tab is shown in the mode without a server.

| The timeline | View as 360° |
|---|---|
| <img src=".github/readme/quest-timeline-360.jpg" width="380" alt="The Immuch360 window in the headset showing a month of 360° photos"> | <img src=".github/readme/quest-view-as-360.jpg" width="380" alt="A top and bottom 3D photo with the viewer menu open on View as 360°"> |
| The app window floating in the room, a month of 360° photos | A stereoscopic photo the server does not flag as 360°: the ⋮ menu offers View as 360° |

| Without a server | Network shares |
|---|---|
| <img src=".github/readme/quest-library-without-server.jpg" width="380" alt="The Library tab without a server: On this device and Network shares"> | <img src=".github/readme/quest-network-shares.jpg" width="380" alt="The Network shares page with a Freebox Server SMB share"> |
| The Library tab in the mode without a server: the headset's own media and the network shares | A Samba share of a Freebox Server, read live from the headset |

Photos show a preview first, then the original, downscaled to at most 8192x4096 (the app's limit). Videos play the file stored on the headset when there is one, and a file of a network share through the app's local bridge; otherwise they stream from your server as the **Video source** setting says (from build 15; by default the original, and the server's transcoded version when the original cannot stream or is above the headset's decoders). Raw Insta360 files open here too from build 16, stitched by the app, see [Raw 360° camera files](#raw-360-camera-files); the 3D and 360°/180° buttons are hidden for a raw video, which is one full sphere.

If the image does not face you the right way when it opens, turn it with the right thumbstick (or the Turn button of the info panel) until its center is in front of you. The angle shows as "Image turned to N degrees", on the panel or on the one line overlay when the panel is hidden: please post that number in an [issue](https://github.com/freeKC/Immuch360/issues), with your camera model, so that it can become the default.

### Limitations

- **Video codecs:** HEVC (H.265) is the safe choice: an Insta360 X4 8K HEVC video (7680x3840, 29.97 fps, 210 Mbit/s, Main profile level 6.1, 8 bit) plays smoothly in the immersive view, at its native resolution and without transcoding (reported by a user on a Quest 3). The H.264 hardware decoder of the Quest 3 (XR2 Gen 2) tops out around 4096x2304. A 5760x2880 H.264 video (level 6.0, about 200 Mbit/s, the usual Insta360 export) decodes at about 17 fps on the headset, with block artifacts, while the same file plays fine on a phone. The same video in HEVC (H.265) plays well on the headset. From build 15 the app checks what the device decodes (codec, size and frame rate read from the file, against the hardware decoders; H.264 on the Quest 3 is held to the measured 4096x2304). In the headset the immersive view starts the original and, at its first frames, switches to the server's transcoded stream when the original is above the decoders, saying so on the info panel; when there is no transcoded stream, when it is still too large, or when the file comes from the headset or a network share, the info panel says so for 10 seconds, with what to change. The setting **Video source** (Settings, Asset Viewer, Videos) can force the original or the transcoded stream, and **Video decoders of this device** (Settings, Advanced) lists what the headset or phone decodes, with a Copy button for bug reports. Build 14, the one submitted to the Horizon Store, checks only H.264 above 4096x2304, and then tries the server's playback stream the same way. To give the headset a video it can decode, in Immich go to Administration, Settings, Video Transcoding Settings, and pick one of these:
  - **Every H.264 video re-encoded in HEVC:** set Video codec to HEVC and Target resolution to Original (the default 720p would shrink a 360° video to 1440x720), and keep only HEVC in Accepted video codecs. Every H.264 video of the library is transcoded, not only the 360° ones, and the headset gets HEVC at full resolution.
  - **Only what is larger than 1440p:** keep H.264 in Accepted video codecs, set Transcode policy to "Videos higher than target resolution or not in an accepted format" and Target resolution to 1440p, preferably with Video codec set to HEVC. Anything larger is transcoded and the headset gets 2880x1440. Regular 4K videos are transcoded to 1440p too.

  These settings apply to the whole server, for every user and every app, and re-encoding a large library takes hours of CPU time and extra disk space; the originals are not modified. Browsers without HEVC support (Firefox on most systems, Chrome without hardware HEVC) will not play an HEVC transcode in the Immich web app. The easiest fix for new videos is to export in H.265 from the Insta360 app or Studio. After changing these settings, the existing videos must be transcoded again: Administration, Job Queues (Jobs in older Immich versions), Transcode videos, All.

  The alternative, and the only one for files of a network share or of the headset (they have no transcoded stream), is to re-encode the export in HEVC before uploading it or copying it to the share:

  ```bash
  ffmpeg -i VID_360.mp4 -c:v libx265 -crf 20 -preset medium -tag:v hvc1 -c:a copy -movflags +faststart VID_360_hevc.mp4
  exiftool -overwrite_original -tagsFromFile VID_360.mp4 -XMP-GSpherical:all VID_360_hevc.mp4
  exiftool -ProjectionType VID_360_hevc.mp4        # must print: equirectangular
  ```

  `-tag:v hvc1` labels the HEVC track the way Apple devices and browsers expect, `-c:a copy` keeps the audio as it is. ffmpeg drops the 360° tag of the export, the exiftool line copies it back; without it, Immich shows the video as a flat one.
- **Originals that cannot stream:** when the server ignores HTTP Range requests on the original and the MP4 index (moov) is at the end of the file, the whole file would have to download before the first frame, so the app falls back to the server playback stream. A reverse proxy in front of Immich that buffers the responses or strips the Range headers can cause this.
- **Store:** the Horizon Store listing is waiting for Meta's review, submitted with build 14 (the alpha test channel already has build 16). Until it is approved, sideload the APK. The store version starts at build 14: the features marked "from build 15" and "from build 16" in this section come with its next update, and the GitHub APK has them now.
- **Permissions:** the headset build asks only for photos and videos (the mode without a server) and notifications (backup progress). It has no storage, audio, location or camera permission, unlike the phone build; the Wi-Fi name based server switching is therefore not available on the headset.
- **3D layouts:** top and bottom and side by side media, 360° and VR180, are shown in 3D, each eye getting its own half of the frame. The layout comes from the file when it declares one (videos), otherwise it is guessed from its shape (square: top and bottom, 4:1: side by side); when it is wrong, use the 3D button of the info panel. That choice is not remembered when the viewer closes; the 360°/180° choice is, for the media of the library.
- **Starting orientation not confirmed yet:** if a photo or video does not face you when it opens, turn it with the right thumbstick or the Turn button and report the value (see above).
- **Previous and next:** they look at most 400 media ahead in a timeline and 50 files in a share folder, for 12 seconds at most; past that the panel says there is no previous or next 360° media. A share folder is checked file by file, so the first 360° file after many flat ones can take a few seconds to find.
- **Seeking:** a video whose source does not answer byte range requests cannot be seeked; the panel says so.
- **APK size:** the Spatial SDK adds about 56 MB of 64-bit ARM native code, on phones too, where it is never loaded.
- **License:** the immersive view uses the Meta Spatial SDK, distributed under the Meta Platform Technologies SDK License Agreement.

### Logs

The immersive view logs with the tag `Immuch360`, the decoder checks with `VideoDecoders`, the stitching of a side by side raw video with `DualFisheyeEffect` and the two lens playback of build 18 with `TwoLensPlayer`, `TwoLensCompositor` and `LensVideoRenderer`:

```bash
adb logcat -c
# reproduce the problem, then
adb logcat -d -v time -s Immuch360 VideoDecoders DualFisheyeEffect TwoLensPlayer TwoLensCompositor LensVideoRenderer
adb logcat -d -v time > quest-full.log      # everything, including crashes and decoder errors (it can contain your server address, check before sharing)
```

## Roadmap

What is not done yet, the most likely first. Nothing here is a promise, and feedback on the [issue tracker](https://github.com/freeKC/Immuch360/issues) helps decide what comes first.

- **Google Play**: builds 15 and 16 were sent for Google's review on 4 October 2026 and go live once approved; the last build confirmed live there is build 11.
- **App Store**: version 3.3.0 is waiting for Apple's review; it carries the features of build 11, so the upload to Immich and the video decoder check (build 15) and the raw Insta360 files (build 16) come with the next App Store update. The link will be added here when it is live.
- **Meta Horizon Store**: the listing was submitted for Meta's review on 3 October 2026 with build 14, and build 16 is on the store's alpha channel for the next update. Once the listing is approved, the Quest 3 no longer needs sideloading and the store link will be added here; a sideloaded copy has to be uninstalled first (see [Install](#install)).
- **Store listings**: the Google Play and App Store texts still describe the first builds (360° photos and videos, raw files shown flat); they will present the 3D, VR180 and Spatial viewers, the mode without a server, network shares, the media player and the raw Insta360 files. The Meta Horizon Store text already presents the media player.
- **Raw 360° camera files, next**: a progress indicator while a raw photo is prepared for the headset; levelling of GoPro and DJI videos from their own motion data; dual fisheye .dng; device reports on the two lens playback of build 18 (X4, X5, X6, GoPro MAX 2, Osmo 360) to confirm seams and decoder budgets.
- **More sources (build 19)**: DLNA/UPnP servers (Plex, Jellyfin, minidlna, the NAS boxes) as a share type; "Share this phone on the network" so that a Quest reads the phone's gallery over Wi-Fi without a computer; Apple spatial photos (HEIC stereo pairs) shown in 3D on the headset, spatial videos with one eye where the platform decodes only that.
- **360° players on phones, next**: a time bar in the iOS 360° video player (the Android one has it), previous/next in the 360° players of phones as in the Quest immersive view, and photos in the native 360° video player.
- **Network shares, next steps**: swiping from one file of a folder to the next in the photo and video pages (the Quest immersive view already goes through the 360° files of a folder), Digest authentication for WebDAV, the user name from the Bonjour record.
- **Flat videos**: the audio track choice in the flat player, for server, device and share videos alike (the 360° and Spatial players have it).
- **Upstream**: small pull requests to Immich for the parts the maintainers want, starting with the 360° photo viewer.

## Build it yourself

The build chain is the one of Immich mobile (Flutter 3.47, managed with [mise](https://mise.jdx.dev)):

```bash
git clone https://github.com/freeKC/Immuch360.git
cd Immuch360/mobile
mise install
mise run install
mise run codegen
flutter build apk --release --flavor phone                                   # phones: the universal APK of the GitHub releases (add --split-per-abi for the per ABI files)
flutter build appbundle --release --flavor phone                             # the App Bundle sent to Google Play (also mise run build:android)
flutter build apk --release --flavor quest --target-platform android-arm64 --android-project-arg arm64only=true   # Meta Quest 3: the -quest-release.apk of the releases (also mise run build:quest)
flutter build ios --release                                                  # iPhone and iPad, on a Mac with Xcode and your own signing team
```

Store screenshots are taken on debug simulator builds made with `--dart-define=IMMUCH_SCREENSHOTS=true`, which only hides the debug banner. The two Android flavours are the same app. The `quest` one targets SDK 34 and keeps only the permissions the headset uses (photos, videos, notifications): media management, background location, legacy storage, audio, media location, device location and camera are removed in `android/app/src/quest/AndroidManifest.xml`, because the Meta Horizon Store refuses the first two and asks for a justification of every other sensitive one; the same file names the Quest 3 and 3S as its supported devices and limits plain HTTP to the headset itself and to names of the home network. The APK is 64 bit only because of the two extra arguments of its command line (`--target-platform android-arm64 --android-project-arg arm64only=true`). The `phone` one is what Google Play requires. To build for iOS on your own Mac, use Xcode and your own signing team; with Xcode 26, run `xcodebuild -downloadComponent MetalToolchain` once first, as the Spatial shaders need it. Without a Mac, iOS builds run on Codemagic (a hosted Mac) from the `codemagic.yaml` file of this repository. Android release builds run on GitHub Actions (`.github/workflows/immuch360-release.yml`).

No secret lives in this repository: the Android signing key is stored as encrypted GitHub Actions secrets, and the Apple signing material is stored as encrypted variables on Codemagic. The workflow files only reference them by name. Without your own `android/key.jks`, a release build is signed with the debug key and cannot install over a copy from GitHub or a store (uninstall that one first); a debug build installs next to it as Immuch360 debug. The Meta Horizon Store copy is the `quest` APK of the release signed with another key, the one the store app was first registered with, so it cannot install over a sideloaded APK either, nor the other way round.

## Branches

- `main`: Immich `main` at the commit `immuch360` is based on (29 September 2026 for the current builds), never modified; it moves forward when the fork is rebased on a newer Immich.
- `immuch360`: the changes of this fork on top of Immich. Each release says which Immich version it is based on.

## License and trademark

This project is a fork of Immich and stays under the [GNU AGPL v3](LICENSE). Every APK, the phone ones included, also contains the Meta Spatial SDK, which is not open source (Meta Platform Technologies SDK License Agreement) and is only used on Meta Quest headsets. Immuch360 is not affiliated with, nor endorsed by, the Immich team or FUTO. For the full documentation of Immich itself, see [immich.app](https://immich.app).
