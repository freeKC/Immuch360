<p align="center">
  <img src="assets/icon-source.png" width="128" alt="Immuch360 icon">
</p>

<h1 align="center">Immuch360 for LG webOS TVs</h1>

<p align="center">Your media. Any screen. Every perspective.</p>

Immuch360 is an unofficial fork of [Immich](https://immich.app). This folder is its app for LG TVs running webOS: an
Immich viewer for the remote control, with the 360° photos on a sphere you turn with the arrows. It is a preview: the
first builds are for testers.

It is built on **[immich-tv-webos](https://github.com/Seeky91/immich-tv-webos) 1.7.0 by Quentin Jean-Amans** (MIT), which
did the hard part of an Immich app for LG TVs: the timeline, the albums, places, search, the slideshow, the sign in with
a phone, the Back key of every firmware, and a build that runs on webOS 4.0 and later (LG TVs from 2018). Thank you.
Its licence is kept in [LICENSE](LICENSE); what this folder changed is listed in [UPSTREAM.md](UPSTREAM.md).

Immuch360 is not affiliated with Immich, nor with LG.

## What it adds to immich-tv-webos

| You want to | Immuch360 on webOS | immich-tv-webos 1.7.0 |
|---|---|---|
| Look around a 360° photo | It opens on a sphere: the arrows turn the view (faster the longer you hold them), the channel keys zoom, the Magic Remote drags it | Shown flat |
| Find the 360° photos and videos | A "360°" badge on their tiles | No badge |
| See a VR180 or 3D photo | Half sphere for VR180, the left eye for 3D, with a 360°/180° and a 3D button | Shown flat |
| See a 360° photo the server does not flag | "View as 360°" in the photo's controls, kept on the TV | Not available |
| Read the app in your language | The texts it shares with the Immuch360 app come in its 89 locales and follow the language of the TV; the few texts only the TV app has are in English for now | English |
| Leave a playing video with the remote | Left and Right go to the previous or next item, even while it plays; a video alone seeks 10 s | Same while the bar is hidden |
| Watch a film without the date over it | The top bar of a video hides with the controls, 5 s after the last key | Always shown |
| Look closer at a photo | Zoom with the channel keys or the zoom buttons, then move with the arrows; Back zooms out | Not available |
| Send a useful bug report | About page: TV model, webOS and Chromium versions, WebGL, video decoders, a video-in-WebGL test, all in a QR code | Not available |

360° videos play flat for now, with a message: whether LG TVs hand video frames to WebGL is what the video test of the
About page finds out.

Not on a TV: uploads and editing, the phone's own media, network shares, Plex and Tapo cameras (planned through the
app's JS service), Cast, the gyroscope.

## Install on a TV in Developer Mode

You need an LG TV with webOS 4.0 or later, on the same network as your computer, and an LG developer account (free).

1. On the TV, install **Developer Mode** from the LG Content Store, sign in with your LG developer account, turn
   **Dev Mode Status** on and let the TV restart. Note the TV's IP address and the **passphrase** the app shows.
2. On the computer, install the webOS CLI (Node.js 18 or later): `npm install -g @webos-tools/cli`
3. Register the TV: `ares-setup-device` (add a device, its IP address, port 9922, user `prisoner`), then
   `ares-novacom --device <name> --getkey` and type the passphrase.
4. Download `com.aprogsys.immuch360_<version>_all.ipk` from the
   [webOS pre-releases](https://github.com/freeKC/Immuch360/releases) (tags `webos-v...`), check it against
   `SHA256SUMS.txt`, then:

   ```bash
   ares-install --device <name> com.aprogsys.immuch360_<version>_all.ipk
   ares-launch --device <name> com.aprogsys.immuch360
   ```

5. Sign in with your phone (scan the QR code), with your email and password, or with an API key.

Developer Mode keeps installed apps for 50 hours; the Developer Mode app extends the session. The
[webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop) of webosbrew installs an `.ipk` on a TV in Developer
Mode without the command line.

Immuch360 uses its own app id, `com.aprogsys.immuch360`, so it installs next to Immich TV (`com.seeky91.immichtv`):
both can be compared on the same TV.

## Remote control

The keys follow the Android TV app of Immuch360 (`mobile/lib/presentation/widgets/tv/remote_keys.dart`); the map is
in [src/immuch360/keys.ts](src/immuch360/keys.ts).

| Key | webOS code | In lists | Photo | 360° photo | Video |
|---|---|---|---|---|---|
| Arrows | 37 to 40 | move the focus | Left and Right: previous, next; zoomed in: move | turn the view while held | Left and Right: previous, next (alone: 10 s); Up, Down: controls |
| OK | 13 | open | show or hide the controls | controls, zoom button focused | controls |
| Back | 461, 1536, 8, 10009, 27 | back | zoom out, then close | close | close the controls, then the video |
| Channel up, down | 33, 34 | | zoom in, out | zoom in, out | |
| Play, Pause, Play/Pause | 415, 19, 179 | | | | play, pause, toggle |
| Rewind, Fast forward | 412, 417 | | | | 10 s back, forward |
| Stop | 413 | | | | close the video |
| Previous, Next track | 177, 176 | | previous, next | previous, next | previous, next |
| Magic Remote | pointer, wheel | point and click | | drag with OK held, wheel zooms | |

1536 is Back on recent firmwares, but the wheel of the Magic Remote sends it too (with the key "Unidentified"): that
pair is not Back. 8 is Back on a few firmwares, except while typing.

## "Couldn't reach the server (CORS)"

From the README of immich-tv-webos, by Quentin Jean-Amans:

The app runs from a `file://` origin and calls the Immich API cross-origin, and Immich sends no CORS headers by
default. On webOS 25 (webOS "10") and later, installed apps skip CORS: it works with no server change. Older firmwares
enforce CORS like any browser: Immich logs the request as `200 OK`, but the TV drops the answer. Allow the app's
requests on the reverse proxy in front of Immich, for example with nginx:

```nginx
add_header Access-Control-Allow-Origin  "*" always;
add_header Access-Control-Allow-Headers "Authorization, x-api-key, Content-Type" always;
add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;

if ($request_method = OPTIONS) {
    return 204;
}
```

The app authenticates with `Authorization` or `x-api-key` headers and uses no cookies, so a wildcard origin is safe
here. The 360° sphere also reads the preview of the photo with `fetch` (WebGL only takes pixels the page may read): the
same headers cover it.

## Build from source

Node.js 24 (`.nvmrc`). The Enact and webOS command line tools are pinned in `package.json`; nothing is installed
globally.

```bash
cd webos
npm ci
npm run test-unit    # node tests of the Immuch360 layers (360° rules, keys, texts, Immich client)
npm test             # the jest tests inherited from immich-tv-webos
npm run typecheck
npm run ipk          # build/com.aprogsys.immuch360_<version>_all.ipk, then checks its content
npm run set-version -- 0.1.0   # the version of appinfo.json and of the service
```

`npm run ipk` reads the texts from `../i18n/*.json` (the keys the code asks for, see `tools/build-i18n.mjs`). The texts
only the TV app has are in `i18n/en.json` of this folder, keys `webos_*`, until they move to the fork's `i18n/en.json`
for Weblate.

The CI workflow `.github/workflows/immuch360-webos.yml` tests and builds the `.ipk` on every push that touches `webos/`
or `i18n/`, and by hand; `.github/workflows/immuch360-webos-release.yml` builds it from a `webos-v<x.y.z>` tag and
publishes it as a pre-release with `SHA256SUMS.txt`.

## Licence

This folder is part of Immuch360, under the GNU AGPL v3 (see [../LICENSE](../LICENSE)), and includes code of
immich-tv-webos under the MIT licence ([LICENSE](LICENSE), [LICENSE.md](LICENSE.md)). Third party packages:
[THIRD_PARTY.md](THIRD_PARTY.md).
