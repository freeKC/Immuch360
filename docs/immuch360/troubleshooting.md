# Troubleshooting

What to do when something goes wrong: the logs to attach to a report, a video that stutters, the first start on Windows, and the messages that need an answer.

Back to the [README](../../README.md)

Each problem below comes with its answer. The known problems that have no answer yet are in [Known issues](known-issues.md). Please report what is not here in [Issues](https://github.com/freeKC/Immuch360/issues), not to the Immich project, with the lines of the logs.

## Logs

On Android and the Quest, `adb logcat` shows the immersive view of the headset under the tag `Immuch360` (from build 19 also the two eyes of an Apple spatial photo: how the second eye was decoded, the crop, where the photo is placed), the decoder checks under `VideoDecoders`, the stitching of a side by side raw video under `DualFisheyeEffect`, and the two lens playback of build 18 under `TwoLensPlayer`, `TwoLensCompositor` and `LensVideoRenderer`:

```bash
adb logcat -c
# reproduce the problem, then
adb logcat -d -v time -s Immuch360 VideoDecoders DualFisheyeEffect TwoLensPlayer TwoLensCompositor LensVideoRenderer
adb logcat -d -v time > quest-full.log      # everything, including crashes and decoder errors (it can contain your server address, check before sharing)
adb logcat -d -v time -s PhoneShareService PhoneShareApi   # on the phone that shares itself (from build 19)
```

The native players of Android and their bridges to Flutter write under tags of their own too: `SphericalVideoActivity` (the 360° video player of phones and TVs), `SpatialVideoActivity` and `SpatialHeadTracker` (the Spatial 2.5D player and its head tracking), `RawProjection` (the calibration of a raw video as the players read it, and why they refuse one), and `VideoDecoderApi`, `SphericalVideoApi` and `SpatialVideoApi` (the calls from Flutter to the decoder check and to the two players):

```bash
adb logcat -d -v time -s SphericalVideoActivity SpatialVideoActivity SpatialHeadTracker RawProjection VideoDecoderApi SphericalVideoApi SpatialVideoApi
```

From build 19 the DLNA client, the phone share and the detection of Apple spatial media also write to the app's own log (Logs, in the menu of the profile picture at the top right), under `Ssdp`, `DlnaFileSystem`, `NetworkBrowserPage`, `PhoneShare`, `PhoneShareServer`, `AppleSpatialService`, `HeicStereoProbe` and `NetworkMediaService`. From build 20 the TV mode writes there under `TvMode` and `TvTextEntry`, the Plex servers under `Gdm`, `UdpTransport`, `PlexClient`, `PlexFileSystem` and `PlexServerEditPage`, and the Tapo cameras under `TapoDiscovery`, `TapoHttps`, `TapoLogin`, `TapoControl`, `TapoMedia`, `TapoFileSystem`, `TapoTest`, `TapoCamera`, `CameraPage`, `CameraEditPage` and `CameraLiveView`; the Plex lines never hold the token, an address or a title, and the camera lines leave the passwords out. Log lines stay on the device unless you copy them yourself.

On a computer (Immuch360 Desktop), the Logs page also has "Save logs to a file": the log, or a ZIP of the log and the reports of the last crashes when there are some (its suggested name then ends with "with-crash-reports"). A crash report is a small minidump: the threads, where they stopped and only what is needed to follow their calls, with the names of the program files but not their folders; not the memory of the app.

From desktop build 2 the video player of the computer writes there under `DesktopVideo`, `DesktopPlayer`, `DesktopVideoController`, `PlayerPool` and `VideoThumbnailGrabber`, mpv's own warnings included, with tokens and passwords removed. From desktop build 3 it also writes the 360° player under `SphericalPlayer`, `SphereRenderer` and `PluginRenderer` (the size chosen, the frames per second measured, the graphics chip), the raw two lens videos under `RawTwoStreams`, the decoders of the graphics chip under `DesktopGpuDecoders`, `DesktopVideoDecoderApi` and `DecoderMeasure`, and the Tapo live view under `DesktopCameraLive`, whose lines never hold the camera account nor its password. Check the log before sharing it: it can contain your server address.

## A video stutters, or plays a blurry copy

### Why a video stutters

People ask which codec, size and bit rate the Quest 3 plays, and why a 5.7K export stutters in the headset while it plays on the phone. The answer is the hardware decoder: the H.264 decoder of the Quest 3 (XR2 Gen 2) tops out around 4096x2304, so a 5760x2880 H.264 video (level 6.0, about 200 Mbit/s, the usual Insta360 export) decodes at about 17 fps on the headset, with block artifacts, while the same file plays fine on a phone.

The same video in HEVC (H.265) plays well on the headset: an Insta360 X4 8K HEVC video (7680x3840, 29.97 fps, 210 Mbit/s, Main profile level 6.1, 8 bit) plays smoothly in the immersive view, at its native resolution and without transcoding (reported by a user on a Quest 3).

The Immich app has one "Force original video" switch and shows the codec only. Immuch360 shows what a video is and what the device decodes, and picks the file that plays.

The details of a video, what the device decodes, and the choice between the original and the transcoded stream are in [Video details, decoders and why a video stutters](user-guide.md#video-details-decoders-and-why-a-video-stutters).

### Give the headset a video it can decode

In Immich, go to Administration, Settings, Video Transcoding Settings, and pick one of these:

- **Every H.264 video re-encoded in HEVC**: set Video codec to HEVC and Target resolution to Original (the default 720p would shrink a 360° video to 1440x720), and keep only HEVC in Accepted video codecs. Every H.264 video of the library is transcoded, not only the 360° ones, and the headset gets HEVC at full resolution.
- **Only what is larger than 1440p**: keep H.264 in Accepted video codecs, set Transcode policy to "Videos higher than target resolution or not in an accepted format" and Target resolution to 1440p, preferably with Video codec set to HEVC. Anything larger is transcoded and the headset gets 2880x1440. Regular 4K videos are transcoded to 1440p too.

These settings apply to the whole server, for every user and every app, and re-encoding a large library takes hours of CPU time and extra disk space; the originals are not modified. Browsers without HEVC support (Firefox on most systems, Chrome without hardware HEVC) will not play an HEVC transcode in the Immich web app. The easiest fix for new videos is to export in H.265 from the Insta360 app or Studio. After changing these settings, the existing videos must be transcoded again: Administration, Job Queues (Jobs in older Immich versions), Transcode videos, All.

The alternative, and the only one for files of a network share or of the headset (they have no transcoded stream), is to re-encode the export in HEVC before uploading it or copying it to the share:

```bash
ffmpeg -i VID_360.mp4 -c:v libx265 -crf 20 -preset medium -tag:v hvc1 -c:a copy -movflags +faststart VID_360_hevc.mp4
exiftool -overwrite_original -tagsFromFile VID_360.mp4 -XMP-GSpherical:all VID_360_hevc.mp4
exiftool -ProjectionType VID_360_hevc.mp4        # must print: equirectangular
```

`-tag:v hvc1` labels the HEVC track the way Apple devices and browsers expect, `-c:a copy` keeps the audio as it is. ffmpeg drops the 360° tag of the export, the exiftool line copies it back; without it, Immich shows the video as a flat one.

### Originals that cannot stream

When the server ignores HTTP Range requests on the original and the MP4 index (moov) is at the end of the file, the whole file would have to download before the first frame, so the app falls back to the server playback stream. A reverse proxy in front of Immich that buffers the responses or strips the Range headers can cause this.

## Windows

### The window takes a long time to show

**The first start of a new build is slow**: from 10 seconds to about a minute before the window shows, most likely while Microsoft Defender scans the new files, which are not signed yet. Wait for the window rather than starting the app again; the next starts take a second or two.

### A file opened with the program does not show

- **On the first start**, before you sign in or choose "Use without a server", the file waits, and opens once you have.
- **"No assets to show"**: the file is no photo or video the app reads, see [Formats and sources](compatibility.md#formats-and-sources-by-platform).
- **A folder shows fewer files than File Explorer**: it shows its own photos and videos, not those of its subfolders, at most 5000, and leaves out the files OneDrive keeps online only. To see all of it, add it in Settings, This computer.
- **A 360° file shows flat**: its file declares no projection the app knows. "View as 360°" in the ⋮ menu views it as 360°, see [A 360° file that shows flat](user-guide.md#a-360-file-that-shows-flat-view-as-360).
- **What was opened**: the lines of "OpenFiles" on the Logs page say how many files were read and how many are 360°, see [Logs](#logs).

### A 360° or 8K video is slow on a laptop

**8K HEVC videos need a dedicated graphics chip, and 360° videos run better on one**: on the test laptop, the integrated Intel UHD chip showed about half the frames of an 8K HEVC video, while the dedicated NVIDIA chip played 8K HEVC and 5.7K H.264 with no dropped frame; the 360° player is smooth on the NVIDIA chip and slower on the Intel one, see [360° videos and the graphics chip](user-guide.md#360-videos-and-the-graphics-chip). Windows runs the app on the integrated chip unless told otherwise: in the Windows settings, System, Display, Graphics, add `immuch360.exe` and choose "High performance", then start the app again. On the integrated chip, a flat 5.7K H.264 video, which its decoder refuses, is decoded by the processor without a lost frame.

- **Use the dedicated graphics chip of a laptop.** Windows runs the app on the integrated chip unless told otherwise. In the Windows settings, System, Display, Graphics, add `immuch360.exe` and choose "High performance", then start the app again. On the test laptop (an Intel UHD chip and an NVIDIA RTX 4060 Laptop), the NVIDIA chip drew 4K, 5.7K and 8K 360° videos at full size and 30 frames a second while the view turned. The Intel chip drew them at most 2880 pixels wide: a 4K H.264 and an 8K HEVC video at about 30 frames a second with a 2026 build of libmpv, a 4K video at 23 to 27 with media-kit's 2024 libmpv, used until desktop build 3, and a 5.7K H.264 video, which the processor decodes, at about 20: from the server, the player then switches to the transcoded stream; a video with no transcoded stream, from a folder for example, plays on with the message "This graphics card cannot show the 360° view of this video smoothly".

### A video looks a little soft on a 4K screen

**Flat videos are drawn at most 1440 lines high**, then scaled to the window: on a 4K screen in full screen, a 4K or 8K video is a little softer than in a dedicated video player. This keeps an 8K video within the graphics power of a laptop. The 360° player reads the whole frame, or the smaller size its measure chose, and draws its view at most 1440 lines high too.

More on the 360° player and the graphics chip: [360° videos and the graphics chip](user-guide.md#360-videos-and-the-graphics-chip).

## Tapo cameras

### "The camera is busy with another viewer, such as the Tapo app. Try again in a minute."

The camera serves one download at a time. While the Tapo app browses the memory card, the app tries again after 4, 8 and 12 seconds, then shows this message. Close the Tapo app, or leave its memory card page, wait a minute, then open the recording again. See [Tapo cameras](user-guide.md#tapo-cameras-live-view-and-the-recordings-of-the-memory-card).

### "The camera is locked after too many wrong passwords. Try again in N minutes."

Each wrong password counts, and after a few the camera locks for a while. The app never tries a refused password again by itself: only "Test the camera" or Retry ask the camera again. Wait for the minutes the message gives, check the passwords in the page of the camera (the TP-Link account password for the recordings, the camera account for the live view), then tap "Test the camera" once. When the camera takes the password for its settings but not for its videos, turn Third-Party Compatibility off and on again in the Tapo app, then restart the camera.

## Other messages

- **"The app cannot see the photos of this device"**: the photos and videos permission was refused. Tap "Allow access", or "Open the settings" to allow it there. See [Without a server or an account](user-guide.md#start-without-a-server).
- **A 360° photo or video shows flat**: the file carries no projection tag. Tap ⋮, then "View as 360°". See [A 360° file that shows flat](user-guide.md#a-360-file-that-shows-flat-view-as-360).
- **"Playing the transcoded stream: the original (codec and size) exceeds what this device decodes"**: the original is above the decoders of the device, so the server's transcoded stream plays instead. See [Choose the original or the transcoded stream](user-guide.md#choose-the-original-or-the-transcoded-stream).
- **"This raw video needs two (size) video decoders at once: it may not play smoothly on this device"**, or one lens with half of the sphere black: the device cannot run two decoders of that size. See [When the device cannot play both lenses](user-guide.md#when-the-device-cannot-play-both-lenses).
- **"This recording is split in two files, one per lens, and (name) was not found next to it"**: keep the two files of an X3 pair together, or export the video from the camera app. See [Watch a raw file](user-guide.md#watch-a-raw-file).
- **"The Plex server refused this token."**, or "Paste a new token" on the folder page: get a new token as [Add a Plex server](user-guide.md#add-a-plex-server) says.
- **"Your Plex server cannot be reached from outside your home network."**: turn on Remote Access with a port forwarding in Plex, or type the public address of the server. See [Away from home](user-guide.md#away-from-home).
- **"This address answers without a Plex certificate."**: claim the server in Plex, or add it as an SMB, WebDAV or DLNA share. See [Plex Media Server](user-guide.md#plex-media-server-without-plextv).
- **"Windows protected your PC"**: the files are not signed yet; choose "More info", then "Run anyway". See [Download and install on Windows](platform-support.md#download-and-install-on-windows).
- **The picture does not face you in the headset**: turn it with the right thumbstick or the Turn button, and post the angle shown in an issue with your camera model. See [If the picture does not face you](user-guide.md#if-the-picture-does-not-face-you).

Last updated: 12 October 2026 (build 23, desktop build 4)
