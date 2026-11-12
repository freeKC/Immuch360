# Release status

The builds of Immuch360, what each store has on 12 November 2026, after release 45, and what comes next.

Back to the [README](../../README.md)

## Where to get it

The GitHub release is always the newest build. The stores follow after their reviews, so a store can be one or two builds behind. Each row says what the store has, what is in its review, and the GitHub build:

| Platform | Today | In review or next |
|---|---|---|
| Android phones and tablets | [Google Play](https://play.google.com/store/apps/details?id=com.aprogsys.immuch360): build 40 (3030038), public since 1 November 2026. [GitHub](https://github.com/freeKC/Immuch360/releases/tag/v3.4.0-45): build 45 (version 3.4.0, 3030043), published on 11 November 2026, the APKs and the App Bundle | Build 45, in Google's review since 11 November 2026, in place of build 44 |
| iPhone and iPad | [App Store](https://apps.apple.com/us/app/immuch360-360-3d-player/id6817655965): version 3.3.4, made from build 44, on sale since 10 November 2026. Before it: 3.3.3 (9 November), 3.3.2 (6 November) and 3.3.1, the first one on the store (5 November 2026). The source builds with Xcode or on Codemagic, see [Build it yourself](build.md) | Version 3.4.0 (iOS build 38, made from build 45), waiting for Apple's review since 11 November 2026 |
| Meta Quest 3, Quest 3S, Quest 2 and Quest Pro (only the Quest 3 is tested) | [Meta Horizon Store](https://www.meta.com/experiences/immuch360/1384208401440714/): version 10, with build 44 (3030042), public since 11 November 2026. [GitHub](https://github.com/freeKC/Immuch360/releases/tag/v3.4.0-45): the Quest APK of build 45, sideloaded in developer mode | Version 11, with build 45 (3030043), submitted to Meta on 11 November 2026 |
| Android TV and Google TV | [Google Play](https://play.google.com/store/apps/details?id=com.aprogsys.immuch360): the build of the phones (build 40), since Google Play offers the app on Android TV and Google TV (by 8 November 2026). [GitHub](https://github.com/freeKC/Immuch360/releases/tag/v3.4.0-45): the universal APK of build 45, sideloaded with adb, see [Install it on the TV](platform-support.md#install-it-on-the-tv) | Build 45 with the phones |
| LG webOS TVs (webOS 5.0 and later) | [GitHub](https://github.com/freeKC/Immuch360/releases/tag/webos-v1.0.1): webOS 1.0.1 (27 October 2026), for TVs in Developer Mode, see [LG webOS TVs](platform-support.md#lg-webos-tvs) | Version 1.0.0, in the review of the LG Content Store since 24 October 2026, under LG's tests since 26 October 2026 |
| Samsung TVs (Tizen 5.5 and later) | [GitHub](https://github.com/freeKC/Immuch360/releases/tag/tizen-v0.3.0): test build 0.3.0 of the same TV app, to sign with your own Samsung certificate and install in Developer mode | Not on Samsung's store; a run of 0.3.0 on a Samsung TV |
| Windows 10 and 11, 64 bit | [GitHub](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.4.0-25): desktop build 25 (version 3.4.0), a preview, as an installer or a ZIP signed by APROGSYS, published on 11 November 2026 | The next desktop build with release 46 |
| Linux, 64 bit | [GitHub](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.4.0-25): the .deb and the .rpm of desktop build 25, a preview; 360° videos play flat | The 360° video renderer; a run on a real Linux PC |
| macOS 12 or later | [GitHub](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.4.0-25): the DMG and the ZIP of desktop build 25, an unsigned preview; 360° videos play flat | A signed and notarized app; the 360° video renderer |

Sign in with your usual Immich server address and account, or choose "Use without a server" on the welcome page to start on the device's own photos and videos. The APK from GitHub does not update itself: watch the Releases page, or the website. Once you have installed the app from a store, take the updates from that store.

The store build and the GitHub APK are signed with different keys: to switch from one to the other, uninstall the app first (its settings and saved shares go with it). How to install each one is in [Platform support](platform-support.md).

## The builds

- **Phones, tablets, headsets and TVs**: build 45, version 3.4.0, build number 3030043, is the GitHub release [v3.4.0-45](https://github.com/freeKC/Immuch360/releases/tag/v3.4.0-45) of 11 November 2026: the universal APK, the APKs for arm64-v8a, armeabi-v7a and x86_64, the Quest APK, the App Bundle that goes to Google Play, and `Immuch360-libsmb2-sources.tar.gz`, the corresponding source of the SMB library. Its base is the Immich 3.4.0 app with 11 later fixes of Immich. New in it: the Plex films by year with a page for each film, their audio and subtitle menus, their download to the device and their playback on a TV from the phone (all experimental), the JPEG XL photos of Immich 3.4 servers, the tags of a photo in its details, the version notice of a major gap only, and an invitation to rate the app in the store builds. The release notes say what was checked and what was not.
- **Computers**: desktop build 25 is the GitHub pre-release [desktop-v3.4.0-25](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.4.0-25) of 11 November 2026, from the same code. Its files are named `Immuch360-Desktop-3.4.0-desktop.25-<system>`: the Windows installer and ZIP, the Linux .deb and .rpm, the macOS DMG and ZIP, and the source of libsmb2, with `SHA256SUMS.txt`. New in it: JPEG XL, the Plex films with a Subtitles menu and the download (experimental), Play from a phone (experimental), and the AV2 decoder, libmpv and the video renderer taken from the repositories of the [immuch360](https://github.com/immuch360) organisation, with nothing changed in what plays.
- **LG and Samsung TVs**: unchanged in release 45. webOS 1.0.1 is the GitHub pre-release [webos-v1.0.1](https://github.com/freeKC/Immuch360/releases/tag/webos-v1.0.1), and the Samsung test build 0.3.0 is [tizen-v0.3.0](https://github.com/freeKC/Immuch360/releases/tag/tizen-v0.3.0). The LG and Samsung apps cannot show JPEG XL yet: keep WebP or JPEG thumbnails on a server you watch from those TVs.
- **Earlier builds**: the notes of every build are on the [Releases page](https://github.com/freeKC/Immuch360/releases) and on [immuch360.com](https://immuch360.com/).

## Experimental functions

These are on by default, labelled "experimental" in the app, and may change. Each one can be turned off where the README says.

- **Plex films**: the films page by year, the page of a film with its Wikipedia summary, the audio and subtitle menus that write your pick back to Plex, the download of a film to the device, and playing a film on a TV, the Quest window or a computer from the phone.
- **AI immersive, on the computers**: 3D photos, 3D scenes and 360° panoramas made from your own photos, and Gaussian splats made from photos or a video; in the Meta Quest 3 and 3S, the splats in your room and the AI relief of a flat photo; "Large splats" for up to 1,000,000 gaussians in the headset.
- **Splat scenes kept in Immich**, opened on phones, tablets, computers and the Quest.
- **AV2 videos** on the computers.
- **Raw 360° videos stabilised** with the camera's gyroscope (Insta360, GoPro MAX and DJI Osmo 360 files).
- **DJI drones**: the import over USB, the DJI link page, and the live video of a drone relayed by a phone to a Quest or an Android TV.
- **Kiosk mode** in the Meta Quest, for an exhibition or a shop.
- **In the Quest window**: 3D by file name and sharper flat screens.

## Roadmap

What is in the works for the next release, then later. Nothing here is a promise, and feedback on the [issue tracker](https://github.com/freeKC/Immuch360/issues) helps decide what comes first.

- **Plex films, next**: the films the Quest cannot decode (DTS, TrueHD, older AVI files) played through libmpv, with the server's transcoding as a second way; clear messages and retries when a Plex server stops or is slow to start a film; an optional "Sign in with Plex"; "Play on" through Google Cast (experimental); the subtitle files beside a film copied with its download; the audio and subtitle menus on iPhone and iPad.
- **Settings**: an export and import of the servers, sources and settings, so that a move between the store build and the GitHub APK keeps them ([issue 16](https://github.com/freeKC/Immuch360/issues/16)).
- **Video stabilisation**: on more players (iPhone and iPad, the computers, the Quest).
- **AI immersive**: the open points of the 2D to 3D functions, and their tests in the Quest.
- **Stores**: build 45 on Google Play and the Horizon Store, and version 3.4.0 on the App Store, once reviewed; the LG Content Store; a signed macOS app.
- **Device tests**: the Plex functions with a real server on a phone, a TV and the Quest, JPEG XL with a real Immich 3.4 server, and the rating invitation of the store builds.

Last updated: 12 November 2026 (build 45, desktop build 25, webOS 1.0.1, Samsung test build 0.3.0)
