# Known issues

The known problems of Immuch360, and what has not been checked on a device yet, by platform and by feature.

Back to the [README](../../README.md)

Each line links to the section that explains it. The limits by design, such as the SMB versions or the Plex servers that must be claimed, are listed in [Limits by feature](compatibility.md#limits-by-feature). To report a problem, open an [issue](https://github.com/freeKC/Immuch360/issues) with the lines of the [logs](troubleshooting.md#logs).

## Every platform

- **No previous and next in the 360° players of phones and tablets** yet; the Quest immersive view has them: [360° photos and videos](user-guide.md#360-photos-and-videos-as-a-sphere).
- **No audio track choice in the flat player** of phones and tablets yet; the 360°, Spatial and computer players have it: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- **No swiping from one file of a share folder to the next** on a phone yet: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- **The 3D or 180° choice made on a file of a network share is not remembered**: [3D and VR180](user-guide.md#3d-and-vr180-photos-and-videos).
- **Dual fisheye .dng files show flat**: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **Raw videos are levelled once and not stabilised**, and GoPro and DJI files are not levelled: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **Objects close to a 360° camera can show a seam** in a raw file stitched by the app: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **WebDAV servers that only offer Digest authentication** are refused: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- **Photos over 30 MB get no thumbnail in a share**: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- **A file the server already has is sent in full** before the server reports it as a duplicate: [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- **Plex: IPv4 addresses only**, and no relay away from home: [Plex Media Server](user-guide.md#plex-media-server-without-plextv).
- **The 360° video players of phones do not hand their playback position back** to the flat player when they close, nor use the initial view the camera recorded: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- **Tapo: H.265 recordings are not converted yet**, and a clip plays once it is fully fetched: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- **A turn kept on the device is not shown everywhere** (from build 27): the slideshow, the memories, the thumbnails and casting show the photo as it is; a turn saved on the server through Immich's photo editor shows everywhere: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).
- **A photo of the device that may be 360°** (2:1, or "pano" or "360" in its name) gets the rotate button only once the 360° scan has read it: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).

## Android phones and tablets

- **Two lens raw videos on a phone** (Insta360 X4 and later, X3 pairs, GoPro .360, DJI .osv) have not been played on a phone yet; a DJI Osmo 360 file needs a 10 bit HEVC decoder, which the Android emulator lacks: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **Raw files copied to the phone are not listed**: Android files .insv, .insp, .360, .lrv and .osv as other files, not as photos or videos, so they stay out of the gallery and of the app; play them from a share or a computer: [Watch a raw file](user-guide.md#watch-a-raw-file).
- **A phone serving a Quest 3** with "Share this phone on the network" is not checked on a device yet: [Share this phone](user-guide.md#share-this-phone-on-the-network).
- **Plex playback on a phone** is not checked on a device yet: [Plex Media Server](user-guide.md#plex-media-server-without-plextv).
- **Apple spatial videos play one eye**, since Android has no public way to decode the second view: [Apple spatial photos and videos](user-guide.md#everywhere-else).
- **The DJI drone page is experimental and not checked with a real drone yet** (from build 27): it ran on an Android phone emulator with synthetic files; a real DJI Neo 2, a USB drive or card reader, a device in File transfer mode (MTP) and an unplug in the middle of a large file are still to try: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- **DJI: the sound recorded by the phone is not merged**: a drone keeps that sound in a separate .m4a file, which DJI Fly merges when it downloads the clip; the app sends the video without it and says so on the tile: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- **DJI: a device in File transfer mode may send its list of files slowly**: the page says when the list may be incomplete, and Refresh reads it again; it does not read it again by itself: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).

## iPhone and iPad

- **The 360° video player has play and pause only**, no time bar yet: [360° photos and videos](user-guide.md#play-a-360-video).
- **No Tapo live view in the published builds yet**: it comes with version 3.3.2, built from build 28, a few seconds behind the camera; the recordings play: [Tapo cameras](user-guide.md#watch-it-live).
- **The phone does not sign in big screens yet**: "Connect a TV or computer" comes with version 3.3.2 too. Its scanner and the live view were compiled on a GitHub macOS runner and have not run on an iPhone yet: [Sign in with your phone](user-guide.md#sign-in-a-tv-a-headset-or-a-computer-with-your-phone).
- **The DLNA, Plex and Tapo searches send unicast requests only** until Apple grants the multicast entitlement, and some servers do not answer them (minidlna on Linux): [Network shares](user-guide.md#network-shares-a-nas-a-computer-or-a-media-server).
- **The MKV and AVI files of a share do not open**: [Formats and sources](compatibility.md#formats-and-sources-by-platform).
- **The photos stored only in iCloud** are skipped by the 360° scan until they are downloaded: [Without a server](user-guide.md#without-a-server-or-an-account).
- **The phone share runs only while the app is in front**: [Share this phone](user-guide.md#share-this-phone-on-the-network).
- **Raw files have not run on an iPhone yet**: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **The iPhone side of the phone share has not run on an iPhone yet**: [Share this phone](user-guide.md#share-this-phone-on-the-network).
- **Spatial 2.5D is checked on a Galaxy S24+ only**, and iPhone feedback is welcome: [Spatial 2.5D](user-guide.md#formats-privacy-and-limits).
- **No App Store version yet**: version 3.3.1, sent again with build 27 on 22 October 2026, waits for Apple's review, first sent on 14 October 2026: [Release status](release-status.md).

## Android TV and Google TV

- **Sign in with your phone was not tried with a real camera** (from build 28): between two emulators, the QR code was read from a screenshot of the TV and the code typed on the phone: [Sign in with your phone](user-guide.md#sign-in-a-tv-a-headset-or-a-computer-with-your-phone).
- **Build 27 has not run on a real TV yet**: the first run on a real Android TV, on 21 October 2026 with build 25 or 26, found five problems (a video playing in a loop that Left and Right could not leave, the controls over the picture, 360° videos that never played, white pages, one freeze while photos scrolled), which build 27 answers; those answers were checked on the Google TV emulator and by widget tests. Still to confirm on a TV: the direction in which the arrows turn a 360° video, the keyboard of the TV (Gboard) in the text dialog, the OK key of infrared remotes, a held OK on the remote of the TV, the margins and the banner on the TV home screen: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **A 360° video beyond the decoders of the TV still does not play**: from build 27 the app says so instead of loading forever, names the cause and the largest size the TV decodes, and asks before it opens the 360° player; the server's transcoded stream, or a smaller export, is the way to watch it: [When a video does not play](user-guide.md#when-a-video-does-not-play).
- **The freeze seen once while photos scrolled is not explained yet**: build 27 uses less image memory on a TV and holds a held arrow to about 10 rows a second, and writes a stalled app (no answer for 3 seconds) and why the app last ended to the Logs page; a report with those lines helps: [Logs](troubleshooting.md#logs).
- **Left and Right go to the next item while a video plays, and OK shows the controls first** (from build 27): Google's quality guidelines for TV apps ask that, during playback, Left and Right seek and OK pauses. Build 27 follows what the first run on a real TV asked for; if the review of the TV listing asks otherwise, going back is one switch in the code: [Release status](release-status.md#roadmap).
- **The video page of a share and the 360° photo viewer** do not open details with Menu or a held OK, which the photo and video viewer does from build 27: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **On a TV, OK then OK on a photo of a share turns it** (from build 27): the rotate button is the first of the top bar of the share photo page, so a second OK turns the photo, on the TV only; in the main viewer OK never lands on Rotate: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).
- **"Custom range" of the date filter** opens the date range picker of the system, which was not tried with the remote: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **The Plex and Tapo pages have not been opened on a TV**, not even on the emulator: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **The Settings page of a TV still lists the Backup section** when a server is connected, although backup is hidden everywhere else on a TV, and it still shows the setting of Spatial 2.5D, whose button is hidden: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **The decoders of a real TV are not measured yet**: the Google TV emulator decodes in software: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **Signing in with OAuth is not possible** on a TV: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **On a TV with little memory, 360° photos are shown at 4096x2048 at most** (from build 27, a TV with 3 GB of memory or less counts as one): [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **Fire TV is not tested**, and there is no Apple TV version: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **Google Play on TVs** waits for Google's review of the TV listing: [Release status](release-status.md).

## LG webOS TVs

- **webOS 0.2.0 has not run on a real LG TV yet**, nor in LG's simulator: version 0.1.0 ran on a tester's LG TV (webOS 22); the shares, Plex and the cameras of 0.2.0 were checked against real servers on the project's build host and in a browser. To confirm on a TV: whether its player reads the media bridge of the app on 127.0.0.1, the live view through Media Source and its HLS fallback, the discovery of servers from the service of the app, and the load of SMB 3 encryption on the processor of the TV. Reports from testers with a TV in Developer Mode are welcome: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **360° videos play flat**, with a message: whether a TV hands video frames to WebGL is what the video test of its About page finds out. 360° photos turn on the sphere: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **The texts only the TV app has are in English** until the next webOS release; the texts it shares with the Immuch360 app come in its 89 languages: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **On webOS before 25 the server needs CORS headers**: the reverse proxy in front of Immich must send them, and the app explains them when it meets the problem: [Install it on an LG TV](platform-support.md#install-it-on-an-lg-tv).
- **Not on an LG TV**: uploads, the photo editor (only its quarter turn is there), the recordings of the Tapo cameras (not before December 2026) and their sound, H.265 cameras in the live view, the mode without a server, and Cast. HEIC photos of a share do not decode on a TV, and their tile says so: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **The shares, Plex and the cameras need webOS 5 or later**, and SMB webOS 22 or later; a TV with webOS 4 keeps the Immich features only: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **A photo turned on the TV** keeps its former thumbnail in the grid until the grid draws it again (scroll away and back); from 0.1.1, "Saving the rotation" shows while the turn is saved on the server: [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **Only through Developer Mode**: the app is not in the LG Content Store, and the TV removes it when the 1000 hours of a Developer Mode session run out, unless the session is renewed: [Install it on an LG TV](platform-support.md#install-it-on-an-lg-tv).

## Meta Quest

- **The Quest 2, Quest Pro and Quest 3S are not tested yet**: only a Quest 3 has run the app. The decoders of the Quest 2 and Quest Pro are slower than those of the Quest 3, on which the limits the app checks were measured: [Meta Quest](platform-support.md#meta-quest).
- **H.264 videos above about 4096x2304 stutter** on a Quest 3; HEVC is the safe codec: [Video details and decoders](user-guide.md#video-details-decoders-and-why-a-video-stutters).
- **The headset build refuses a server typed as a plain HTTP address with an IP**: [Meta Quest](platform-support.md#meta-quest).
- **DLNA, the phone share, Plex and the Tapo cameras are not confirmed on the headset yet**: [Meta Quest](platform-support.md#meta-quest).
- **The headset view of Apple spatial photos is not checked on a device yet**, nor real iPhone files: [Apple spatial photos and videos](user-guide.md#not-checked-on-a-device-yet).
- **No previous and next from a spatial photo** yet: [Apple spatial photos and videos](user-guide.md#see-a-spatial-photo-in-3d-in-the-headset).
- **No progress indicator while a raw photo is prepared** for the immersive view: [Raw 360° camera files](user-guide.md#watch-a-raw-file).
- **The starting orientation of the picture is not confirmed for every camera**: [If the picture does not face you](user-guide.md#if-the-picture-does-not-face-you).
- **A flat stereoscopic video plays in the window with both eyes visible**: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- **A partial panorama is spread over the full sphere** in the immersive view, unless its GPano crop covers about half the width and the whole height: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- **The initial view the camera recorded (GPano) is not used** by the immersive view: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- **No audio track choice in the immersive view**: [Limits of the immersive view](user-guide.md#limits-of-the-immersive-view).
- **The store version is build 25**, until Meta approves version 4, with build 28: [Release status](release-status.md).
- **Sign in with your phone and the DJI link page have not run in a headset yet** (from build 28). Whether a Quest offers the USB accessory mode a DJI remote controller needs is the first question the DJI link page answers: [Sign in with your phone](user-guide.md#sign-in-a-tv-a-headset-or-a-computer-with-your-phone), [DJI link](user-guide.md#dji-link-diagnostics-experimental).

## Windows

- **A preview**: the test of each function by hand on a Windows PC, with real files, both screens and a real camera, is still to do: [On a Windows computer](user-guide.md#on-a-windows-computer-immuch360-desktop-preview).
- **The Tapo live view is not checked with a real camera yet**: [Known problems](#known-problems).
- **No Windows on ARM app yet**: the libmpv workflow builds an arm64 archive, but no app ZIP for it is made: [Windows](platform-support.md#windows).
- **Sign in with your phone is off on a network that Windows marks as public**, and no computer was signed in that way yet; on the test PC only the sign-in page was seen (from desktop build 8): [Sign in with your phone](user-guide.md#sign-in-a-tv-a-headset-or-a-computer-with-your-phone).
- **Opening files from File Explorer by hand is not checked yet** (from desktop build 5): the command line, later starts (one at a time, or several at once with a file each, as File Explorer makes them) and drops sent to the window by a test script were checked on the test laptop, and the window came to the front for those starts; the "Open with" menu and a drag with the mouse were not: [Use it on a computer](user-guide.md#use-it-on-a-computer).
- **What to do when something goes wrong**: [Troubleshooting](troubleshooting.md#windows).

### Not there yet

- **Two lens raw videos on a laptop**: in desktop builds 3 and 4 the test laptop stacked an X3 pair (two 2880x2880 H.264 files) at 30 frames a second on its NVIDIA chip only, and an X4 file (two 3840x3840 HEVC tracks) played one lens on both chips. From desktop build 5 they play in two players: on the NVIDIA chip, a DJI Osmo 360 file (two 3840x3840 HEVC 10 bit tracks at 25 frames a second), an X4 file (two 3840x3840 HEVC tracks at 30) and an X3 pair played with no frame dropped. The first time a file at 30 frames a second opens, the player may still say "it may not play smoothly on this device", until the computer has measured it. Not checked yet in the app: the Intel chip, where the flat viewer alone took 2.5 GB of shared GPU memory for the Osmo 360 file and the test stopped for lack of memory on the PC (two players outside the app dropped 2 to 3 frames of 300 there).
- **3D on the screen only**: a 3D video shows its left eye, as on phones; there is no gyroscope and no headset view on the computer. To watch in true 3D, share the computer with a Meta Quest.
- **Spatial 2.5D**, with the webcam, in development for November 2026; the **map** and the Places view; **signing in with OAuth** (sign in with an email and a password instead); **Google Cast**; **notifications**.
- **Automatic updates**: the next build is installed by hand. The installer and the ZIP are signed from desktop build 7: [Windows](platform-support.md#windows).
- **Linux and macOS**: from desktop build 5 they have packages, early previews: see [macOS and Linux](#macos-and-linux).

### Known problems

- **After the installer, Windows may ask which program opens a .insp or .insv file**: the installer offers Immuch360 Desktop in "Open with" and never makes it a default program, but when the program of a type was never chosen as the default by you (Insta360 Studio for .insp and .insv, for example), Windows asks once at the next double click; and a type that no other program opens (often .osv and .360) opens with Immuch360 Desktop, the only program offered. Choose "Always" with the program you want, or change it in Settings, Apps, Default apps.
- **The first start of a new build is slow**: from 10 seconds to about a minute before the window shows, most likely while Microsoft Defender scans the new files. Wait for the window rather than starting the app again; the next starts take a second or two.
- **8K HEVC videos need a dedicated graphics chip, and 360° videos run better on one**: on the test laptop, the integrated Intel UHD chip showed about half the frames of an 8K HEVC video, while the dedicated NVIDIA chip played 8K HEVC and 5.7K H.264 with no dropped frame; the 360° player is smooth on the NVIDIA chip and slower on the Intel one, see [360° videos and the graphics chip](user-guide.md#360-videos-and-the-graphics-chip). Windows runs the app on the integrated chip unless told otherwise: in the Windows settings, System, Display, Graphics, add `immuch360.exe` and choose "High performance", then start the app again. On the integrated chip, a flat 5.7K H.264 video, which its decoder refuses, is decoded by the processor without a lost frame.
- **Flat videos are drawn at most 1440 lines high**, then scaled to the window: on a 4K screen in full screen, a 4K or 8K video is a little softer than in a dedicated video player. This keeps an 8K video within the graphics power of a laptop. The 360° player reads the whole frame, or the smaller size its measure chose, and draws its view at most 1440 lines high too.
- **While a video of your folders plays in the app, or while the headset reads a file from the shared computer** (a video it plays, a photo it downloads), Windows cannot rename, move or delete that file and says it is open in Immuch360 Desktop: close the video, or stop the playback in the headset, first. Backups do not hold your files that way: a file can be renamed, moved or deleted while it is uploaded.
- **Rough edges**: desktop build 3 passed 855 of its 863 desktop tests on Windows (8 are skipped by design) and the whole test suite of the app, 200 players opened one after the other left no leak, and its release ZIP started, played a test clip and closed cleanly. Desktop build 4 is covered by the project's CI (the desktop tests on Windows and the whole test suite of the app), and was started, played a 1080p video and closed cleanly by hand; desktop builds 5 and 6 are built and tested by the same CI. The test of every function by hand on a real PC is still to do.
- **What the 360° player and the live view were checked with**: the 360° player was run with synthetic 4K, 5.7K and 8K 360° clips on both graphics chips of a laptop (opened, played, turned while playing and paused, closed) with no crash and no reset of the graphics driver. Raw two lens videos were played from synthetic clips and from real X3 and X4 files. The Tapo live view was checked against a test RTSP server that signs in the way the cameras do (Digest), cut and refused on purpose, with no password in any log line, but not yet with a real camera. The test by hand, with real 360° and 3D files, both screens of a laptop, sleep and resume, and a real camera, is still to come.

If something goes wrong, please open an [issue](https://github.com/freeKC/Immuch360/issues) with the log saved from the Logs page, see [Logs](troubleshooting.md#logs). Check the log before sharing it: it can contain your server address.

## macOS and Linux

- **Packages from desktop build 5, early previews**: a .deb, an .rpm and a macOS app, built by the project's CI: [Install it on a computer](user-guide.md#install-it-on-a-computer-windows-linux-and-macos).
- **360°, 3D, VR180 and raw dual lens videos play flat** on Linux and macOS (from desktop build 6, when flat videos came), with "This computer cannot show the 360° view of this video: it plays flat.": the 360° video player draws through renderer C, written for Windows only so far: [macOS and Linux](platform-support.md#macos-and-linux).
- **Linux, never run on a real Linux PC**: only under WSLg (the Linux of Windows 11) and in the containers of the CI, so the graphics chip of a real PC is not checked there (from desktop build 7 the videos take the graphics chip on X11 sessions too, checked in the CI with Mesa's software rasterizer and with a test program under WSLg, not with the app on a real Intel or AMD chip); the Immich server gallery, the SMB, WebDAV and DLNA shares, Plex, the Tapo recordings and live view, Apple spatial photos and the upload to Immich are in the sources and built by the CI, not checked on Linux yet: [macOS and Linux](platform-support.md#macos-and-linux).
- **Linux, videos drawn by the processor on X11 sessions, up to desktop build 6**: the isolated EGL context of the graphics chip failed under X11, so the frames went through the processor; desktop build 7 fixes it. A system whose graphics cannot share a frame between two contexts still draws in software, and says so when the app is started from a terminal: [Linux](user-guide.md#linux).
- **Linux, without a secret service**: on a session with no GNOME Keyring or KWallet (a minimal window manager, a container), the app keeps its secrets for the session only, so it asks for the server's sign in and the passwords of the shares again at its next start; from desktop build 7 it no longer waits 25 seconds at each secret, and Settings, This computer says "Secrets kept for this session only": [Linux](user-guide.md#linux).
- **Linux, Fedora in the CI**: the CI plays an H.264 clip with each package, which Fedora's own FFmpeg decodes through OpenH264, installed from Fedora's Cisco repository; when that repository does not answer the runners, the package check of Fedora fails for a reason outside the app ("libopenh264: Unable to create decoder", seen on Fedora 40 on 21 October 2026). The first start in the Fedora 40 container also ended once with a crash under software rendering, before any video, which the next attempt did not show. Neither was seen outside the CI's containers, and the same .rpm passed both Fedora checks on another computer: [Build it yourself](build.md#packages-of-immuch360-desktop).
- **Linux, camera videos on Fedora**: Fedora's own FFmpeg decodes H.264 through OpenH264 only, which refuses the Main and High profiles of camera videos; install the FFmpeg of RPM Fusion with `sudo dnf swap ffmpeg-free ffmpeg --allowerasing`: [Linux](user-guide.md#linux).
- **Linux, without libmpv**: the packages bring libmpv; a bundle copied by hand onto a system without it runs without videos, and the viewer names the package to install: [Linux](user-guide.md#linux).
- **Linux, the folders are not watched**: files added to a folder show after Refresh or the next rescan: [macOS and Linux](platform-support.md#macos-and-linux).
- **macOS, never run on a real Mac**: nobody working on the project has a Mac, and the app only ran on the Mac of the CI, a virtual Mac without a user. Untested on a real Mac: the Gatekeeper steps of the first start, the OpenGL path of the video (the CI's Mac drew video in software), the keychain prompts after an update, the local network prompt and the discovery of servers, Finder drops, signing in to an Immich server, shares with passwords, the gestures of a trackpad, Retina screens and two displays. A capture of the CI's Mac once showed garbled glyphs in titles, which the later runs did not show. The app is not signed with an Apple Developer ID nor notarized: [macOS](user-guide.md#macos).
- **Files given to the app** (from desktop build 5): on Linux, the drop on the window and the hand over of a later start over the session bus have not run; on macOS, a drop by hand has not run, while the Finder path ran on the CI's Mac: [Platform support](platform-support.md#macos-and-linux).

## Not checked on a device yet

- **Tapo cameras** with a real camera, on every platform: [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).
- **Plex** on a phone, in the Quest, on an iPhone and on a TV, and the switch to the address outside home: [Plex Media Server](user-guide.md#plex-media-server-without-plextv).
- **Raw two lens playback** on a phone, a Quest and an iPhone: [Raw 360° camera files](user-guide.md#raw-360-camera-files-without-the-cameras-app).
- **The iPhone side of the phone share**, and a phone serving a Quest 3: [Share this phone](user-guide.md#share-this-phone-on-the-network).
- **DLNA** on a real network, with Plex, Jellyfin, a NAS, the Freebox Server, an iPhone and the Quest: [DLNA media servers](user-guide.md#dlna-media-servers).
- **Apple spatial photos in the headset**, and real iPhone photos and videos: [Apple spatial photos and videos](user-guide.md#not-checked-on-a-device-yet).
- **The Quest 2, Quest Pro and Quest 3S**: [Meta Quest](platform-support.md#meta-quest).
- **Sign in with your phone** with a real camera, in a headset, on a computer and from an iPhone: [Sign in with your phone](user-guide.md#sign-in-a-tv-a-headset-or-a-computer-with-your-phone).
- **A real DJI remote controller on the DJI link page**, in a Quest and on a phone: [DJI link](user-guide.md#dji-link-diagnostics-experimental).
- **The Tapo live view on an iPhone or an iPad**, with version 3.3.2: [Tapo cameras](user-guide.md#watch-it-live).
- **Builds 27 and 28 on a real Android TV or Google TV**, and the Plex and Tapo pages on a TV: [Watch on your TV](user-guide.md#watch-on-your-tv-android-tv-and-google-tv).
- **webOS 0.2.0 on a real LG TV**, its shares, Plex and live view (0.1.0 ran on one): [LG webOS TVs](platform-support.md#lg-webos-tvs).
- **A real DJI drone**, a USB drive or card reader, and a device in File transfer mode: [DJI drones](user-guide.md#dji-drones-photos-and-videos-over-usb-experimental).
- **The one-key rotation on a phone, an iPhone, a Quest and a computer**: it ran on the Google TV emulator against an Immich server, and the other platforms are covered by widget tests: [Turn a photo with one key](user-guide.md#turn-a-photo-with-one-key).
- **A real Linux PC and a real Mac**: [macOS and Linux](platform-support.md#macos-and-linux).
- **Everything checked so far**, device by device and server by server: [Servers and devices checked](compatibility.md#servers-and-devices-checked).

Last updated: 22 October 2026 (build 28, desktop build 8, webOS 0.2.0)
