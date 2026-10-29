# Captures of the README

Every capture here is a real capture of the app, cut to the app's own window or screen, without any device frame. Unless said otherwise, the media shown are CC0 assets from [Poly Haven](https://polyhaven.com/license), or test files made from them.

## Windows, desktop build 4

* Files: `desktop-b4-video.jpg` and `desktop-b4-photo.jpg`, 1200 x 750, JPEG quality 85.
* Build: Immuch360 Desktop 3.3.0-rc.0, desktop build 4 (version 3.3.0-rc.0-22-9911335), English interface, display at 200 percent.
* Date: 12 October 2026.
* How: each file opened from the command line, as "Open with" does; window client area of 1280 x 800 logical pixels (2560 x 1600 pixels), saved by a script with PrintWindow, client area only, then reduced. For the video, a click on the picture showed the player controls one second before the capture. The date and time at the top are the moment the file was opened: a file opened this way has no date of its own in the viewer.
* `desktop-b4-video.jpg`: `video_wide_street_01.mp4`, a 5 second clip made with ffmpeg from the backplate DSC_4349 of "Wide Street 01" by Sergej Majboroda (CC0).
* `desktop-b4-photo.jpg`: the backplate IMG_0809 of "The Sky Is On Fire" by Greg Zaal and Rico Cilliers (CC0).
* Not captured: the 360° view. On this build a 360° photo or video opened with "Open with" shows flat, and "View as 360°" opens a 360° page that keeps loading (photo) or nothing (video).

## Android TV and Google TV, build 21

* Files: `tv-b21-share-folder.jpg`, `tv-b21-sphere.jpg`, `tv-b21-library.jpg`, 1280 x 720, JPEG quality 85, reduced from the 1920 x 1080 captures of the Google Play listing.
* Build: universal APK of build 21, Google TV emulator (Android 16 Google TV image, 1920 x 1080), English interface.
* Date: 8 October 2026.
* Media: the panoramas "Lakeside" by Greg Zaal, "Pink Sunrise" by Greg Zaal and Rico Cilliers and "Snowy Forest Path 01" by Oliksiy Yakovlyev (CC0), and a 12 second 360° video made from "Pink Sunrise", on the device and on a test SMB share named NAS.

## Android phone, build 19

* Files: `b19-*.png`, 540 px wide. `b19-sphere.jpg` and `b19-share-folder.jpg` are JPEG copies (quality 85) of the two heaviest captures, which replaced their PNG originals on 12 October 2026.
* Build: build 19 of the Android app, debug build with the screenshot setting (no debug banner), phone emulator at 1080 x 1920, English interface.
* Date: 5 October 2026.
* Media: the same three panoramas and the same 360° video (CC0), on the device and on the test share NAS.

## Meta Quest 3, build 11

* Files: `quest-*.jpg`, 1280 x 720.
* Build: release build 11 on a Meta Quest 3, French interface.
* Date: 3 October 2026.
* How: taken by the author in the headset with its capture button (3840 x 2160), cut around the panel, then reduced.
* Media: photos and videos of the author, not CC0, published with the author's agreement; `quest-immersive-3d-360-video.jpg` shows the 3D 360° sample video of Kandao.

## The AI creator, build 32 (desktop build 13)

Every picture of this section comes from a real output of Immuch360, made from a CC0 photo of [Poly Haven](https://polyhaven.com/license). None of these files has been looked at in a headset by the author yet (29 October 2026). Composed with Python (Pillow, numpy) by a script outside the repository; the badges in the strip are the words of the app ("3D AI", "3D scene", "360° AI"), drawn by that script on a dark chip so that they read on a white wall.

* `ai-one-photo-four-ways.jpg`, 1600 x 1207, JPEG quality 85: one photo and what the app made of it, in the style of the platforms montage.
  * The photo: `p01_interior.jpg`, the backplate 10 of "Christmas Photo Studio 07" by Sergej Majboroda (CC0), 5568 x 3712, MD5 419eef4b21ef186928e54ef815e3a0c2 as the Poly Haven API gives it.
  * 3D photo: made on 29 October 2026 on a Linux PC (Intel processor, no graphics card used) by the engine, the queue and the writer of the app at `feat-ai-immersive` 611672c39, through `mobile/test/desktop/ai/real_conversion_test.dart` ("next to the original"), with ONNX Runtime 1.31.0 and Depth Anything V2 Small installed from a local copy of the components: 5 seconds, `p01_interior_3D_LRF_Full_SBS.jpg`, 11136 x 3712. The tile shows its right eye, the one the app computes (the left eye is the photo).
  * 3D scene: made the same day on the same PC and head by `real_scene_test.dart`, MoGe-2 ViT-S and LaMa on ONNX Runtime 1.31.0, on the processor: 41 seconds, `p01_interior_scene3D.jpg`, 2 meshes, 50,868 vertices, 96,852 triangles, room to move 0.5 m each side. The two tiles are drawn from the scene file itself by a small software renderer (the one the V2 checks used, nearest texel, no smoothing), not by the app's "Preview in 3D": the eye moved 0.3 m to the left or to the right and 0.15 m forward, turned 5 degrees back toward the middle, then 2.6 percent trimmed at each edge, where the reconstructed area ends.
  * 360° panorama: `p01_interior_360.jpg`, made on 28 October 2026 by the Windows app (test build 4ef2440 of `feat-ai-immersive`, the panorama components installed from a local copy) on a laptop with an RTX 4060 Laptop GPU: FLUX.2 klein base 4B with the 360° LoRA of nomadoor, through stable-diffusion.cpp on Vulkan, in 4 to 5 minutes like the two others of that run, 6144 x 3072, reduced here. Its XMP says `Origin=GeneratedContent`, about 10.5 percent of the sphere is the photo, the rest is invented. The outline and "The original photo" are drawn from the file's own `PhotoHfov` and `PhotoVfov` (81.45 and 59.71 degrees), as the viewers of the app show them for a few seconds when the panorama opens.
* `ai-3d-photo-wiggle.webp`, 900 x 593, animated WebP, 2 frames of 167 ms, endless: the left eye and the right eye of a 3D photo made by the app, one after the other, the "Wiggle" view of the app. The 3D photo is `indoor_hall_3D_LRF_Full_SBS.jpg`, made on 27 October 2026 by the Linux app of our CI (the `.deb` of desktop run 40514244187, `feat-ai-immersive` 573ae2f3e) in an Ubuntu 24.04 container, on the processor, from the backplate DSC_3962 of "Old Hall" by Sergej Majboroda (CC0). The right eye is moved 8 pixels (of 5568) so that the middle of the room stays still, and 64 pixels are trimmed on each side.
* `ai-windows-make-3d-dialog.png`, 720 x 807, PNG with transparent corners: the "Make 3D (AI)" box of the Windows app, cut from a capture of the window (2534 x 1369) on 28 October 2026, test build f81e82f, English interface, the RTX 4060 laptop. "About 96%" and "About 5 min" are for that photo and that graphics card. Behind the box, thumbnails of the CC0 photos of the test.
* `ai-windows-panorama-viewer.jpg`, 1280 x 692, JPEG quality 85: the 360° viewer of the Windows app opening `p02_landscape_360.jpg`, a panorama it made from the backplate IMG_0929 of "Table Mountain 1" by Greg Zaal and Rico Cilliers (CC0): the badges "360° AI" and "360°", the outline "The original photo" and "Generated by AI beyond the photo's edges", which fade after a few seconds. Capture of the window (2534 x 1369) on 28 October 2026, test build 4ef2440, reduced.
* The words in the two captures were checked on 29 October 2026 against the English texts of `feat-ai-immersive` 611672c39, the head of the AI branch that day.

## Montage of the platforms

* File: `platforms-2026-10.jpg`, 1600 x 490, JPEG quality 85, composed with Python PIL.
* From left to right: `b19-sphere.jpg` (Android phone), the TV capture behind `tv-b21-share-folder.jpg` (Android TV and Google TV), the Windows capture behind `desktop-b4-video.jpg` (Windows) and `quest-immersive-360-photo.jpg` (Meta Quest 3), each at its own aspect ratio, the phone 1.6 times taller than the others, with a thin grey border, rounded corners and a caption in DejaVu Sans.

* File: `platforms-2026-10-24.jpg`, 1600 x 900, JPEG quality 85, composed with Python PIL for the build 30 README.
* First row: `b19-sphere.jpg` (Android phone), the sphere viewer of the iOS app in the iPad Pro 13 inch simulator on 14 October 2026 with the Poly Haven panorama lake_pier (the capture behind the first iPad screenshot of the App Store listing), the first TV screenshot of the Google Play listing (the sphere viewer on the Google TV emulator, build 23) and the primary screenshot of the LG Content Store listing (a 360° photo on the sphere, the LG TV app in a browser that stands in for the TV). Second row: the second screenshot prepared for Samsung (the photo timeline, the same TV app packaged for Samsung TVs, in a browser that stands in for the TV, against a stand in Immich server with Poly Haven media), the first English screenshot of the Meta Horizon Store listing (the window of the app in a Meta Quest 3, 14 October 2026, Poly Haven panoramas) and the Windows capture behind `desktop-b4-video.jpg`. Rounded corners, a thin grey border and a caption in DejaVu Sans under each.

## iPad

* Files: `ipad-sphere.jpg` and `ipad-library-360.jpg`, 675 x 900.
* Build: the App Store build of the iOS app, on an iPad, English interface.
* Date: 3 October 2026.
* Media: a 360° photo of a city at dusk, not one of the Poly Haven panoramas.

## Other lighter copies


## Artwork, not captures

* `hero-2026-10-29.jpg`, 1536 x 864, JPEG quality 87: the opening image of the build 32 README, an illustration generated on 29 October 2026 for the project, in the palette of the earlier hero: at dusk in front of a sea bay, the same room four times, as a flat photo on a phone, in floating layers in front of a headset, as a scene on a laptop and unrolled on a curved band like a panorama. The room on the screens was drawn after the CC0 photo of the strip above ("Christmas Photo Studio 07" by Sergej Majboroda), given as a reference. The launcher icon, the name, the signature, the two lines on the AI creator and the list of screens are added as plain text by a script, with the helpers of the build 30 hero. It shows no screen of the app, and its devices carry no brand, logo or label. A 1280 x 640 crop with the name and the signature only was made for the social preview of the repository, kept outside the repository.
* `hero-2026-10-24.jpg`, 1536 x 1024, JPEG quality 86: the opening image of the build 30 README, an illustration made in October 2026 for the project: at dusk in front of a sea bay, a storage box, a phone, a tablet, a TV, a laptop and a headset, a drone in the sky and a home camera, linked by arcs of light, with the launcher icon, the name, the signature, the line under it and the list of screens added as plain text. It shows no screen of the app, and its devices carry no brand, logo or label.
* `hero-2026-10.jpg`, 1536 x 1024, JPEG quality 88: the previous opening banner, artwork made on 12 October 2026 from the previous banner (`banner-2026-10.png`) and an older logo, with the headline of the README. It shows no screen of the app. Kept until the translations of build 30 point to the new one.
* `banner-2026-10.png`: the previous banner artwork, used by no README; it shows the logos and products of other companies, and goes at the build 30 translation pass.
* `lg-tv-webos.png`, `dji-drone-import.png` and `rotate-one-key.png`, 1152 x 648, PNG with 256 colours: illustrations made on 22 October 2026 for the sections "Immuch360 on an LG TV (webOS)", "Your DJI drone's photos and videos on your Immich server" and "Turn a photo with one key", in the palette of the hero. They show no screen of the app: the TV, the phones, the drone and the photo tiles are drawn, without any brand, logo, text or person.
* `sign-in-with-your-phone.png`, 1152 x 648, PNG with 256 colours: illustration made on 22 October 2026 for the section "Sign in a TV, a headset or a computer with your phone", in the palette of the hero: a TV on its sign-in page with a QR code, and a phone held in front of it scanning the same code. It shows no screen of the app: the TV, the phone, the hand and the codes are drawn, without any brand, logo, text or face, and neither QR code decodes to anything.
* `home-cameras.png`, 1152 x 648, PNG with 256 colours: illustration made in October 2026 for the section "Watch your home cameras on the big screen", in the palette of the hero: a TV in a living room shows four home camera views, a small home camera stands on a shelf and a phone on the table shows one of the views. It shows no screen of the app and no real camera picture; the TV, the camera and the phone are drawn without any brand, logo, text or person. The Tapo support of the app has not been checked with a real camera yet, as the section says.
* `drone-live-phone.png`, 1152 x 648, PNG with 256 colours: illustration made in October 2026 for the section "See what your drone sees, on your phone", in the palette of the hero: a phone on a drone remote controller shows an aerial view of a coast while a small drone flies over the bay. It shows no screen of the app; the remote, the phone and the drone are drawn without any brand, logo or text, and no face.
* `logos/`: the platform logos, see `logos/SOURCES.md`.
