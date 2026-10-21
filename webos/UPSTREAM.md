# Upstream: immich-tv-webos

| | |
|---|---|
| Project | https://github.com/Seeky91/immich-tv-webos (MIT, Quentin Jean-Amans) |
| Base | tag `v1.7.0`, commit `8187a502d35ef8efa5cdaf0abc60d81b3b88004a`, 20 October 2026 |
| Imported by | commit "webOS: import immich-tv-webos 1.7.0 by Quentin Jean-Amans (MIT) as the base", the tree of the tag byte for byte |
| Left out | `.github/` (its release workflow and funding file): `.github/workflows/immuch360-webos.yml` builds this app |

Every later commit under `webos/` is Immuch360's, so `git diff <import commit> -- webos` shows exactly what changed.
The history of immich-tv-webos is not imported (one squashed commit keeps the history of the fork linear).

## What Immuch360 changed

- Name, ids and icons: `com.aprogsys.immuch360`, its service `com.aprogsys.immuch360.service` (webOS wants the service
  id to start with the app id), the screen saver client name, `appinfo.json`, `Makefile`, the icons and splash.
- `package.json`: name, licence, the Enact and webOS command line tools pinned as dev dependencies, our scripts.
- Texts through the fork's `i18n/` files (`src/immuch360/i18n`, `tools/build-i18n.mjs`; the texts only the TV app has
  are the `webos_*` keys of the fork's `i18n/en.json`); dates and numbers in the language of the TV.
- The dark palette of the fork (`src/styles/_theme.less`).
- The viewer (`src/components/MediaViewer`): the 360° sphere (`src/immuch360/sphere`), "View as 360°", the 3D and
  coverage buttons, the zoom of photos, the key policy of the Android TV app on videos, the top bar of videos that hides,
  5 s before the controls hide; `useAutoHideControls` takes the keys that reveal them.
- The one-key rotation (`src/immuch360/rotation`): yellow and blue turn a photo, saved through Immich's photo editor
  (`PUT /api/assets/{id}/edits`) for the user's own photos, else in the inherited `rotationStore`; the pictures carry
  the asset's thumbhash as their cache key (`c`), as in Immich's web app.
- The 360° badge of the tiles, the 360° flag read from the timeline and from the asset details (`src/api`).
- The About page with the diagnostics and their QR code (`src/immuch360/diagnostics`), in the navigation rail.
- The welcome page shows the Immuch360 icon and tagline.
- Tests: `test/unit` (node test runner) for the new layers; the inherited jest tests kept, adjusted where a text
  changed.
- `README.md`, `LICENSE.md`, `THIRD_PARTY.md` and this file; the inherited `LICENSE` is kept unchanged. The inherited
  `assets/screenshots` are kept unchanged (not in the `.ipk`).

## Bringing in a new release of immich-tv-webos

In the clone of immich-tv-webos (outside the repository):

```bash
git fetch --tags
git diff v1.7.0 v1.x.y -- . ':!.github' > /tmp/immich-tv-webos-1.x.y.patch
```

In the worktree of a branch of Immuch360:

```bash
git apply -3 --directory=webos /tmp/immich-tv-webos-1.x.y.patch
# resolve the conflicts, run npm ci, npm run test-unit, npm test, npm run typecheck, npm run ipk
git commit -m "webOS: bring in immich-tv-webos 1.x.y changes"
```

Then update the base in the table above and `BASE_VERSION` in `src/immuch360/diagnostics/collect.ts`.

## Offering changes back

Fixes to inherited code, and the 360° sphere, may be offered to immich-tv-webos as pull requests under its MIT licence.
That is the owner's decision; nothing is sent from here.
