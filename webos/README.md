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
| Read the app in your language | The texts it shares with the Immuch360 app come in its 89 locales and follow the language of the TV, or the Language choice of the About page; the few texts only the TV app has are in English for now | English |
| Leave a playing video with the remote | Left and Right go to the previous or next item, even while it plays; a video alone seeks 10 s | Same while the bar is hidden |
| Know why a video does not play | After a media error, or 20 s with nothing shown, a message gives its format and size instead of an endless spinner | Spinner |
| Watch a film without the date over it | The top bar of a video hides with the controls, 5 s after the last key | Always shown |
| Look closer at a photo | Zoom with the channel keys or the zoom buttons, then move with the arrows; Back zooms out. Past 2x the full-size picture replaces the preview when the server makes one (Administration, Image settings) | Not available |
| Read the name, size and camera of a photo or video | Info (or the details button) opens a panel that stays as you move to the next item; Back closes it | Date and place only |
| Turn a sideways photo | One key, as on Android TV: yellow turns it 90° clockwise, blue counterclockwise (R and Shift R on a keyboard). Your own photos are turned through Immich's photo editor (Immich 2.6 and later), so they show turned everywhere; the others are turned on this TV only | A button in the photo's controls, kept on the TV |
| Send a useful bug report | About page: TV model, webOS and Chromium versions, WebGL, video decoders, a video-in-WebGL test, all in a QR code | Not available |
| See the photos and videos of a NAS or a computer | "Network shares": SMB (webOS 22 and later), WebDAV and DLNA shares, found on the network or typed in; their 360° photos turn on the sphere on every webOS from 5 | Not available |
| Watch a Plex library | Plex Media Server: found on the network, signed in with a code on plex.tv/link; photos at the TV's size, videos played as they are or converted by Plex | Not available |
| Watch a Tapo camera | Its live view, video only for now; the recordings of its memory card come later | Not available |

360° videos play flat for now, with a message: whether LG TVs hand video frames to WebGL is what the video test of the
About page finds out.

Not on a TV: uploads and the photo editor (only its quarter turn is here), the phone's own media, the recordings of Tapo
cameras and their sound (planned), Cast, the gyroscope.

## Network shares, Plex and cameras

The "Network shares" page of the rail reads the photos and videos of the home network, as the phone app does. It needs
webOS 5 (2020 TVs) or later; SMB needs webOS 22 (2022 TVs) or later. A webOS 4 TV keeps the Immich features only.

| Source | How to add it | What the TV shows |
|---|---|---|
| SMB share (Windows, Samba on a NAS) | Add a share, SMB: the server's address, "Choose a share" lists its shares, a user and a password | the folders, photos (with the small picture the camera wrote in each JPEG) and videos |
| WebDAV (Nextcloud, Synology and others) | Add a share, WebDAV: the server, the path of its WebDAV address, HTTPS or not, a user and a password | the same |
| DLNA media server (Jellyfin, minidlna, a NAS, a TV box) | Pick it under "Found on the network", or type its description address | the server's folders and pictures; its videos go straight to the TV's player |
| Plex Media Server | Add a Plex server: one found on the network without a Plex account is added as it is; for the others, "Sign in with Plex" shows a code to type on plex.tv/link with a phone (or scan the QR code), then the servers of the account | the libraries and folders; photos made at the TV's size by Plex; a video the TV cannot play is converted by Plex (HLS) |
| Tapo camera | Add a camera: its address and the camera account (Tapo app, camera settings, Advanced Settings, Camera Account) | the live view, HD or SD, video only |

The photos and videos open in the same viewer as Immich's: 360° photos by their GPano tags or their camera, zoom, the
one-key turn (kept on the TV), the slideshow. HEIC photos do not decode on a TV: their tile says so.

How it works: the app's JS service runs a small web server on the TV itself (`127.0.0.1`, a random port, a random
token in every address), the media bridge. The page gives it the sources over the Luna bus; their passwords and tokens
stay in the service's memory and never appear in an address the TV's player sees. It reads SMB, WebDAV, DLNA and Plex
for the page and the player, with byte ranges (seeking works) and the header WebGL needs for 360° photos, and turns the
camera's RTSP stream into fragmented MP4 for the page's Media Source (a remux: the TV decodes it in hardware), with an
HLS playlist where Media Source refuses it. The sources are kept on the TV where the Immich sign ins are
(`localStorage`). A Plex token only goes to the server whose `plex.direct` certificate it was given with.

Not yet: the recordings of the cameras' memory card (they need the camera's own encrypted protocol, ported once it has
met a real camera), the cameras' sound (G.711, which Media Source does not play), H.265 cameras in the live view.

## Install on a TV in Developer Mode

You need an LG TV with webOS 4.0 or later, on the same network as your computer, and an LG developer account (free).

1. On the TV, install **Developer Mode** from the LG Content Store, sign in with your LG developer account, turn
   **Dev Mode Status** on and let the TV restart. Note the TV's IP address and the **passphrase** the app shows.
2. On the computer, install the webOS CLI (Node.js 18 or later): `npm install -g @webos-tools/cli`
3. Register the TV: `ares-setup-device` (add a device, its IP address, port 9922, user `prisoner`), then
   `ares-novacom --device <name> --getkey` and type the passphrase.
4. Download `Immuch360-webOS-<version>.ipk` from the
   [webOS pre-releases](https://github.com/freeKC/Immuch360/releases) (tags `webos-v...`), check it against
   `SHA256SUMS.txt`, then:

   ```bash
   ares-install --device <name> Immuch360-webOS-<version>.ipk
   ares-launch --device <name> com.aprogsys.immuch360
   ```

5. Sign in with your phone (scan the QR code), with your email and password, or with an API key.

A Developer Mode session lasts 1000 hours (it used to be 50); the EXTEND button of the Developer Mode app renews it.
When it expires, the TV removes the apps installed this way. The
[webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop) of webosbrew installs an `.ipk` on a TV in Developer
Mode without the command line.

Immuch360 uses its own app id, `com.aprogsys.immuch360`, so it installs next to Immich TV (`com.seeky91.immichtv`):
both can be compared on the same TV.

## Remote control

The keys follow the Android TV app of Immuch360 (`mobile/lib/presentation/widgets/tv/remote_keys.dart`); the map is
in [src/immuch360/keys.ts](src/immuch360/keys.ts).

| Key | webOS code | In lists | Photo | 360° photo | Video |
|---|---|---|---|---|---|
| Arrows | 37 to 40 | move the focus | Left and Right: previous, next; Up, Down: controls; zoomed in: move | turn the view while held | Left and Right: previous, next (alone: 10 s); Up, Down: controls |
| OK | 13 | open | show or hide the controls | controls, zoom button focused | controls |
| Back | 461, 1536, 8, 10009, 27 | back | zoom out, then close | close | close the controls, then the video |
| Channel up, down | 33, 34 | timeline: a page up, down | zoom in, out | zoom in, out | |
| Play, Pause, Play/Pause | 415, 19, 179 | | | | play, pause, toggle |
| Rewind, Fast forward | 412, 417 | | | | 10 s back, forward |
| Stop | 413 | | | | close the video |
| Info, or I on a keyboard | 457 | | details | details | details |
| Previous, Next track | 177, 176 | | previous, next | previous, next | previous, next |
| Yellow, Blue | 405, 406 | | turn 90° clockwise, counterclockwise | | |
| Magic Remote | pointer, wheel | point and click | | drag with OK held, wheel zooms | |
| Keyboard R, Shift R | 82 | | turn 90° clockwise, counterclockwise | | |

One key turns a photo by 90°, with the keys of the Android TV app: yellow clockwise, blue counterclockwise, R and
Shift R on a keyboard. A Magic Remote without colour keys shows them on screen (its `...` or `123` button), and the turn
button of the photo's controls (Down, then OK on it) does the same. Holding a key down turns the photo once.

Where the turn is kept, as in the other Immuch360 apps:

- your own photos, on Immich 2.6 or later: through Immich's photo editor, on the server, so the photo shows turned on
  the web, on the phones and on this TV, and its edits in the editor (a crop, a mirror) are kept. The photo turns on
  screen at once; the server then makes its turned picture, which takes its place a moment later. An API key needs the
  `asset.edit.create` permission (and `asset.edit.get`, `asset.edit.delete`) for it;
- the photos of a partner or of a shared album, motion photos, GIFs, an older server, or a key without those
  permissions: on this TV only, for that photo (the viewer says so the first time), and the slideshow shows it too.

The arrows never turn a photo: Up is pressed by habit, to bring the controls back or to leave the pointer of the Magic
Remote, and a turn is saved.

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
npm run test-unit    # node tests of the Immuch360 layers (360° rules, keys, texts, Immich client, sources)
npm run test-bridge  # node tests of the media bridge of the service, against local fake servers
npm run bridge       # service/bridge/base.js and smb.js (npm run ipk does it)
npm test             # the jest tests inherited from immich-tv-webos
npm run typecheck
npm run ipk          # build/com.aprogsys.immuch360_<version>_all.ipk, then checks its content
npm run set-version -- 0.1.0   # the version of appinfo.json and of the service
```

The media bridge (`bridge/`) is plain JavaScript for the Node of the TVs: `base.js` is built for Node 8 (webOS 5 and 6),
`smb.js` for Node 12 (webOS 22) and loaded only there. `bridge/test/integration.js` runs the built bundles against real
servers (Samba with signing and SMB3 encryption, rclone's WebDAV, minidlna, Plex Media Server, a camera shaped RTSP
server) inside the `node:8.12.0`, `12.21.0`, `16.19.1` and `20.12.2` images, on the build host of the fork.

`npm run ipk` reads the texts from `../i18n/*.json` (the keys the code asks for, see `tools/build-i18n.mjs`). The texts
only the TV app has are the `webos_*` keys of the fork's `i18n/en.json`, translated with the others at a release; until
then they show in English.

The CI workflow `.github/workflows/immuch360-webos.yml` tests and builds the `.ipk` on every push that touches `webos/`
or `i18n/`, and by hand; `.github/workflows/immuch360-webos-release.yml` builds it from a `webos-v<x.y.z>` tag and
publishes it as a pre-release with `SHA256SUMS.txt`.

## Licence

This folder is part of Immuch360, under the GNU AGPL v3 (see [../LICENSE](../LICENSE)), and includes code of
immich-tv-webos under the MIT licence ([LICENSE](LICENSE), [LICENSE.md](LICENSE.md)). Third party packages:
[THIRD_PARTY.md](THIRD_PARTY.md).
