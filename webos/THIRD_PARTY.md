# Third party software in the webOS app

What the `.ipk` carries besides the code of Immuch360 and of immich-tv-webos, with the versions of
`package-lock.json` at the time of writing (21 October 2026). `npm run license` (enact license) lists every package of
the bundle with its licence.

| Package | Version | Licence | In the app |
|---|---|---|---|
| @enact/core, @enact/ui, @enact/spotlight, @enact/i18n, @enact/webos | 4.9.8 | Apache-2.0 | the Enact framework, focus management of the remote, Luna calls |
| @enact/sandstone | 2.9.13 | Apache-2.0 | the TV components (buttons, inputs, tabs, video player) |
| ilib (ilib-webos) | 14.21.2 | Apache-2.0 | locale data used by Enact (pruned by tools/prune-ilib.mjs) |
| react, react-dom, scheduler | 18.3.1, 0.23.2 | MIT | user interface |
| @tanstack/react-query, @tanstack/query-core | 5.90.16 | MIT | requests to the Immich server and their cache |
| qrcode-generator | 2.0.4 | MIT | QR codes of the phone sign in and of the About page |
| prop-types, classnames | 15.8.1, 2.5.1 | MIT | used by Enact |

Fonts that come with Sandstone, in `dist/node_modules/@enact/sandstone/fonts`:

| Font | Licence |
|---|---|
| Museo Sans | Museo Sans Font License (LG Silicon Valley Lab): use, reproduction and distribution granted for Enact applications only; its text is in the folder of the font |
| Miso | Miso Font License (LG Silicon Valley Lab): same terms |
| Sandstone_Icons | part of @enact/sandstone, Apache-2.0 |

These two font licences are not free software licences: they allow the fonts in Enact applications, which this app is,
and are distributed as separate works next to the AGPL code. Replacing them with free fonts (Noto Sans, under the SIL
Open Font License) is possible through the Sandstone theme if that is ever needed.

Build tools, not shipped: @enact/cli 7.3.4 (Apache-2.0), @webos-tools/cli 3.2.6 (Apache-2.0), esbuild (MIT), TypeScript
(Apache-2.0).

Assets made for this app: the icons and the splash screen come from the Immuch360 launcher icon
(`mobile/android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png`);
`src/immuch360/diagnostics/probe.mp4` is a two second magenta clip generated with ffmpeg for the video test of the About
page.
