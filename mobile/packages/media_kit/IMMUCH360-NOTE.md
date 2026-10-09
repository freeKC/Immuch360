Copy of `media_kit` 1.2.6 (MIT, https://github.com/media-kit/media-kit, folder `media_kit`) at commit
`c533e446755f51cf53c7e57aea873f2aa5355f81` of `main` (2026-08-30), the newest commit of `main` on 2026-10-08, which
carries the 2026 fixes the pub.dev release 1.2.6 of 2025-12-13 lacks (#1440, #1446, `observeEvent` of #1429). Used by
Immuch360 Desktop through `dependency_overrides` in `mobile/pubspec.yaml`, with the copies of `media_kit_video` and
`media_kit_libs_windows_video` of the same commit. The MIT notice is in `LICENSE`, as upstream has it. The Dart code
under `lib/` is unchanged but for punctuation (four em dashes of doc comments in
`lib/src/player/platform_player.dart` and `lib/src/player/web/utils/duration.dart` became commas and brackets, the
fork's texts having none) and for the patch below.

Why a copy and not a git dependency on that commit: upstream's `pubspec.yaml` declares `assets/web/hls1.4.10.js`
(375 KB) for its web player, and Flutter bundles the assets of every dependency of an app into every build of it
(`flutter_tools` `asset.dart`), so the Android and iOS apps of Immuch360, which share `mobile/pubspec.yaml` with the
desktop, would carry that file. Immuch360 has no web build.

What differs from upstream, to apply again when a newer commit is copied here:

- `pubspec.yaml`: no `flutter: assets:` section; no `resolution: workspace`, no `screenshots`, no dev dependencies;
  `publish_to: none`, version `1.2.6+immuch360`.
- Left out: `assets/` (the web player's hls.js), `screenshots/`, `example/`, `test/`.

Patch:

1. media_kit #1449, "Player.dispose() leaves COM uninitialized on Windows, permanently breaking drag-and-drop after 4
   disposals" (open on 2026-10-08, the code of the pinned commit unchanged on that path)
   (`lib/src/player/native/player/real.dart`, `_restoreComReference`). Each disposal of a player took one COM
   reference off the thread the Dart code runs on, the window's thread, without the matching initialisation; once the
   references Flutter and the plugins hold were gone, OLE tore the window's drop target down. After
   `mpv_terminate_destroy`, which `dispose` runs five seconds later, one `CoInitializeEx(NULL,
   COINIT_APARTMENTTHREADED)` gives the reference back (S_FALSE: COM was set up, one more reference), the workaround
   the issue measured (41 players made and disposed, drag and drop alive). Should a later libmpv balance its calls,
   the thread keeps one reference more per disposal, which keeps COM set up as it must stay. The app's player pool
   (`mobile/lib/desktop/video/player_pool.dart`) also disposes rarely. Checked on 2026-10-08 by the soak of the
   measurement harness (`IMMUCH360_MEASURE_SOAK=8`, its `oleAtEnd`, which probes COM on the window's thread), with
   the libmpv of `media_kit_libs_windows_video`: without the patch COM was torn down after 8 disposals, with it COM
   stayed set up, handles and memory flat.
