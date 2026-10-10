# Platform audit: every `Platform.isAndroid` and `Platform.isIOS` line of the app, read for the computers

Immuch360 Desktop runs the code of the phone app on Windows, macOS and Linux. A test of `Platform.isAndroid`,
`Platform.isIOS`, `CurrentPlatform.isAndroid` or `CurrentPlatform.isIOS` sends a computer down one of the two phone
paths without anyone having decided it: an "iOS, else Android" branch takes the computers to Android, an "Android,
else iOS" branch takes them to iOS. This table records, for each such line of `mobile/lib`, what the computers do
there and whether that is right.

Read on the code of build 20 (`34cbb0665`, tag `v3.3.0-rc.0-20`): 93 lines in 54 files, generated files left out.
Line numbers are those of that commit; the wiring points of the desktop work moved some of them by a few lines.

Kept with each upstream sync (plan 20, section 9): list the lines again with

    git grep -n "Platform\.isAndroid\|Platform\.isIOS" -- mobile/lib ':!*.g.dart'

and give each new line a verdict here. New "iOS else Android" ternaries are caught by
`.github/desktop/check_platform_ternaries.py`, whose allow list follows this table.

Verdicts:

- **right**: the branch the computers take is the right one for them, nothing to do.
- **wired (G1)**: the line got a guarded hand over to `lib/desktop/` in the groundwork of phase 1.
- **hidden**: the feature is not offered on the computers (`deviceFeaturesProvider` or a desktop gate), so the
  line is not reached there.
- **harmless**: reached on the computers, with no effect.
- A verdict that names an agent (LIB, LAN, NET, IMG, UX) is work left to that agent of phase 1, in its own files or
  through the wiring point already there.

The three desktops behave alike on every line below: none of them is Android or iOS, and every desktop gate of the
app reads `CurrentPlatform.isDesktop`. Where Linux or macOS differ later (macOS photo library, Linux file sharing),
the gate is per desktop and is noted.

| Line (build 20) | What the line decides | Windows, Linux, macOS |
|---|---|---|
| `lib/constants/constants.dart:12` | Android branch: 512 files per hash batch | right: files of a folder, no iCloud |
| `lib/domain/services/asset.service.dart:189` | Android media management trash | right: no system trash on the computers |
| `lib/domain/services/background_worker.service.dart:324` | iOS background upload | right: the background worker does not run on the computers |
| `lib/domain/services/background_worker.service.dart:375` | Android background engine | right: idem |
| `lib/domain/services/background_worker.service.dart:381` | Android background engine | right: idem |
| `lib/domain/services/device_permission.service.dart:17` | iOS photos permission, else the Android version | wired (G1): the computers ask .photos of DesktopPermissionRepository; LIB may answer denied until a folder is chosen |
| `lib/domain/services/hash.service.dart:61` | Android trashed assets | right: no trash on the computers |
| `lib/domain/services/local_sync.service.dart:48` | Android media management | right |
| `lib/domain/services/local_sync.service.dart:83` | Android full album sync (deletions not detected natively) | iOS like path on the computers: LIB must report removed folders in getMediaChanges, or ask for this branch |
| `lib/domain/services/local_sync.service.dart:94` | iOS cloud albums | right: no cloud album |
| `lib/domain/services/local_sync.service.dart:335` | Android equality on updatedAt, else adjustmentTime and GPS | iOS like comparison on the computers: LIB fills adjustmentTime (file modification time) and the GPS of PlatformAsset, or a change is missed |
| `lib/domain/services/sync_stream.service.dart:210` | Android media management | right |
| `lib/domain/services/sync_stream.service.dart:217` | Android media management | right |
| `lib/domain/services/sync_stream.service.dart:223` | Android media management | right |
| `lib/domain/utils/cloud_id_resolver.dart:20` | iOS cloud ids | right |
| `lib/domain/utils/migrate_cloud_ids.dart:32` | iOS cloud ids | right |
| `lib/infrastructure/network/plex/plex_client.dart:184` | Plex platform header, else Platform.operatingSystem | right: "windows", "linux", "macos" |
| `lib/infrastructure/network/plex/plex_client.dart:186` | idem | right |
| `lib/infrastructure/network/upnp/ssdp.dart:60` | Android multicast socket option | right; LAN checks multicast on Windows |
| `lib/infrastructure/network/upnp/ssdp.dart:69` | SSDP user agent, else Platform.operatingSystem | right |
| `lib/infrastructure/repositories/local_album.repository.dart:70` | iOS assets unique to the album, else every asset of it | right: a file is in one folder |
| `lib/infrastructure/repositories/local_album.repository.dart:169` | Android: an asset is in one album | iOS like path on the computers: correct (it handles several albums), slower; LIB may ask for the Android branch |
| `lib/infrastructure/repositories/local_album.repository.dart:277` | iOS upsert, else Android upsert | right: the Android upsert fits one folder per file |
| `lib/infrastructure/repositories/local_album.repository.dart:369` | Android delete | iOS like path on the computers, correct; same remark as line 169 |
| `lib/infrastructure/repositories/network.repository.dart:21` | URLSession on iOS, else OkHttp | wired (G1): DesktopHttpStack before it |
| `lib/infrastructure/repositories/network.repository.dart:38` | iOS init after headers | right: the desktop headers apply at once |
| `lib/infrastructure/repositories/network.repository.dart:45` | iOS websocket, else OkHttp | wired (G1): DesktopHttpStack.createWebSocket before it |
| `lib/infrastructure/repositories/storage.repository.dart:144` | iOS temporary folder cleanup | right; DesktopStorageRepository overrides it |
| `lib/main.dart:91` | Android high refresh rate | right |
| `lib/main.dart:189` | Android navigation bar colour | right; initApp returns before it on the computers (G1) |
| `lib/main.dart:253` | Android notification texts | right |
| `lib/pages/backup/backup.page.dart:203` | Android battery dialog on resume | right |
| `lib/pages/backup/backup.page.dart:271` | Android background options | right |
| `lib/presentation/actions/delete.action.dart:245` | Android custom delete prompt | right; "Delete from device" hidden on the computers (G1) |
| `lib/presentation/actions/lock.action.dart:63` | Android dialog text, else iOS text | iOS text on the computers; harmless (local files are not deleted on the computers), UX may add a computer text |
| `lib/presentation/actions/share.action.dart:32` | Android share icon, else the iOS one | cosmetic: the iOS share icon on the computers; UX |
| `lib/presentation/pages/asset_troubleshoot.page.dart:134` | iOS cloud details | right |
| `lib/presentation/pages/network/phone_share.page.dart:80` | iOS foreground notice | right |
| `lib/presentation/pages/network/phone_share.page.dart:95` | phone share tile on phones only | wired (G1): shown on the computers once computerShareAvailable is true (LAN) |
| `lib/presentation/widgets/asset_viewer/asset_viewer.page.dart:534` | iOS immersive mode with details | harmless: SystemChrome goes through an optional channel that the desktop embedders ignore |
| `lib/presentation/widgets/asset_viewer/asset_viewer.page.dart:610` | iOS scroll physics, else clamping | right: clamping on the computers |
| `lib/presentation/widgets/asset_viewer/asset_viewer.page.dart:619` | gradient under the status bar, not on iOS | right |
| `lib/presentation/widgets/asset_viewer/panorama_viewer.widget.dart:58` | 360 video player on phones only | wired (phase 2c): true on the computers where libmpv loaded, the 360° route of DesktopSphericalVideoApi plays it |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart:150` | Android file URI, else path | right: a path; the video placeholder stands for the player (G1) until phase 2 |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart:171` | idem | right |
| `lib/presentation/widgets/map/map.widget.dart:90` | Android map style | hidden: no map on the computers (deviceFeaturesProvider.maps) |
| `lib/presentation/widgets/map/map.widget.dart:106` | iOS map style | hidden |
| `lib/providers/app_life_cycle.provider.dart:155` | Android full sync on resume | iOS like partial sync on the computers; LIB adds the folder rescan on resume after five minutes (Design 1.8) |
| `lib/providers/app_life_cycle.provider.dart:165` | idem | idem |
| `lib/providers/asset_viewer/local_panorama.provider.dart:123` | iOS local availability check | right: files are local (placeholders are never published) |
| `lib/providers/infrastructure/immersive.provider.dart:16` | Quest only | right |
| `lib/providers/infrastructure/tv.provider.dart:26` | Android TV only | right |
| `lib/providers/network/phone_share.provider.dart:256` | Android device name | wired (G1): desktopShareDeviceName |
| `lib/providers/network/phone_share.provider.dart:260` | iOS device name | wired (G1) |
| `lib/providers/network/phone_share.provider.dart:390` | iOS pause in background | right: a computer keeps sharing |
| `lib/providers/network/phone_share.provider.dart:407` | Android notification permission | right |
| `lib/providers/permission.provider.dart:13` | initial notification permission state | right: notifications hidden on the computers |
| `lib/providers/raw/raw_video.provider.dart:43` | two stream raw playback on iOS | wired (phase 2d): the computers are neither, and play two streams where libmpv loaded (`CurrentPlatform.isDesktop` term of the same expression, the 360° route stacks them or falls back) |
| `lib/providers/raw/raw_video.provider.dart:45` | two stream raw playback on Android and Quest | wired (phase 2d): idem |
| `lib/providers/tapo/tapo_camera.provider.dart:167` | Android live view events | right: the computers' live view (`DesktopCameraLiveView`, `lib/desktop/video/camera_live_view.dart`) reports its states itself |
| `lib/providers/view_intent/view_intent_handler.provider.dart:18` | Android view intents, else the stub | wired (G1): the computers use the same handler with the command line files |
| `lib/repositories/asset_media.repository.dart:41` | Android trash support | right |
| `lib/repositories/asset_media.repository.dart:51` | Android trash, else photo_manager delete | wired (G1): `DesktopAssetMediaRepository`, a root override, deletes nothing until the system trash (phase 4) |
| `lib/repositories/asset_media.repository.dart:151` | iOS temporary entity | right: no temporary copy on the computers |
| `lib/repositories/download.repository.dart:75` | live photo tasks | right: an Apple live photo downloads its two parts |
| `lib/repositories/download.repository.dart:93` | idem | right; DesktopFileMediaRepository.saveLivePhoto keeps both files (IMG) |
| `lib/repositories/network.repository.dart:18` | Android Wi-Fi name quotes | right |
| `lib/repositories/permission.repository.dart:26` | iOS has no SDK version | right; DesktopPermissionRepository overrides it |
| `lib/services/api.service.dart:158` | iOS device headers | wired (G1): "Immuch360 Desktop" and the system name, never the computer name |
| `lib/services/api.service.dart:162` | Android device headers | wired (G1) |
| `lib/services/background_upload.service.dart:205` | iOS cloud upload | right |
| `lib/services/background_upload.service.dart:423` | iOS cloud id | right |
| `lib/services/cleanup.service.dart:13` | delete batch size | right: free up space hidden on the computers |
| `lib/services/download.service.dart:82` | Android DCIM/Immich, else none | right: no relative path on the computers; DesktopFileMediaRepository saves into the download folder |
| `lib/services/download.service.dart:103` | idem | right |
| `lib/services/foreground_upload.service.dart:480` | not found text, Android else iOS | wired (G1): asset_not_found_on_computer |
| `lib/services/foreground_upload.service.dart:495` | iOS cloud download | right |
| `lib/services/foreground_upload.service.dart:587` | iOS cloud id | right |
| `lib/services/foreground_upload.service.dart:639` | iOS deletes its temporary copies | right, and needed: the computers upload the original files in place, never to be deleted |
| `lib/utils/migration.dart:60` | Android date migration | right |
| `lib/widgets/asset_viewer/detail_panel/exif_map.dart:48` | Android map link | hidden: no map on the computers (G1) |
| `lib/widgets/asset_viewer/detail_panel/exif_map.dart:57` | iOS map link | hidden |
| `lib/widgets/common/app_bar_dialog/server_update_notification.dart:30` | App Store link, else Play, else the release | right: the latest release on the computers until the desktop update check (phase 4) |
| `lib/widgets/common/app_bar_dialog/server_update_notification.dart:32` | idem | right |
| `lib/widgets/common/mesmerizing_sliver_app_bar.dart:55` | iOS back icon | right |
| `lib/widgets/common/person_sliver_app_bar.dart:79` | iOS back icon | right |
| `lib/widgets/common/remote_album_sliver_app_bar.dart:74` | iOS back icon | right |
| `lib/widgets/forms/login/login_form.dart:260` | Android media management | right |
| `lib/widgets/settings/advanced_settings.dart:49` | Android 12 check | right |
| `lib/widgets/settings/backup_settings/backup_settings.dart:29` | Android background options | right; the computers show desktop_backup_while_open instead of the cellular options (G1) |
| `lib/widgets/settings/beta_sync_settings/sync_status_and_actions.dart:184` | iOS cloud ids | right |
| `lib/widgets/settings/beta_sync_settings/sync_status_and_actions.dart:363` | Android trash tools | right |
| `lib/widgets/settings/free_up_space_settings.dart:539` | iOS cloud option | hidden: free up space is not offered on the computers (G1) |

## Desktop gates added outside these lines

The wiring points of phase 1, and of the video of phase 2, that do not replace one of the lines above, each guarded by `CurrentPlatform.isDesktop`
or `deviceFeaturesProvider` so that the phones run exactly as before:

| File | Hand over |
|---|---|
| `lib/extensions/platform_extensions.dart` | `isWindows`, `isMacOS`, `isLinux`, `isDesktop` from `defaultTargetPlatform`, constants of the compiler in profile and release (`vm:platform-const-if`), so that the phone builds drop every desktop branch with the classes only it creates |
| `lib/main.dart` | `runImmich(beforeStart:)` shared with `lib/main_desktop.dart`; `PlatformApis` for the lock, sync and permission APIs; `desktopOverrides()` in the root scope (storage, file media, asset media, permission and share handler repositories); no `SystemChrome` or notifications set up; `desktopAppShell` around the app |
| `lib/utils/bootstrap.dart` | no `PhotoManager.setIgnorePermissionCheck` |
| `lib/data/db/main/database.dart` | `databaseDirectory()`: the support folder of the app on the computers |
| `lib/widgets/settings/beta_sync_settings/sync_status_and_actions.dart` | the database export reads `databaseDirectory()` |
| `lib/providers/infrastructure/platform.provider.dart` | every API through `PlatformApis` |
| `lib/domain/services/background_worker.service.dart`, `lib/presentation/widgets/network/network_media_tile.widget.dart`, `lib/providers/network/phone_share.provider.dart`, `lib/services/view_intent.service.dart` | the direct constructions through `PlatformApis` |
| `lib/infrastructure/loaders/local_image_request.dart` | accepts the encoded answer `{pointer, length}` |
| `lib/infrastructure/network/network_discovery_probes.dart` | `desktopLanAddressesOf` for the subnets to scan; on Windows, mDNS through the DNS-SD functions of dnsapi (`windowsDnsSdBrowse`, `lib/desktop/network/windows_dns_sd.dart`) instead of bonsoir_windows, which crashed the app |
| `lib/providers/network/phone_share.provider.dart` | on Windows, the share announced through dnsapi (`windowsShareAdvertise`) on the network it listens on only, instead of bonsoir on every interface |
| `lib/presentation/widgets/asset_viewer/panorama_viewer.widget.dart` | gyroscope button gated by `deviceFeaturesProvider`; mouse wheel zoom |
| `lib/presentation/widgets/tv/remote_keys.dart` | zoom key sets with the keyboard keys on the computers |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart`, `lib/presentation/pages/network/network_video.page.dart` | `DesktopVideoView` (media_kit, `lib/desktop/video`) instead of `NativeVideoPlayerView`, handing the pages a controller of the same type; the placeholder of phase 1 where libmpv is missing |
| `lib/widgets/asset_viewer/video_controls.dart`, `lib/presentation/widgets/network/network_video_controls.widget.dart` | the audio track menu of the desktop player (`DesktopAudioTrackButton`) for a video with several tracks |
| `lib/providers/app_life_cycle.provider.dart` | the media bridge is not bound again on "resumed", which a computer reports each time its window gets the focus back: that would cut the videos streamed through it |
| `lib/pages/common/settings.page.dart`, `lib/widgets/common/app_bar_dialog/app_bar_dialog.dart` | "This computer" section, its `ComputerSettings` built behind the gate too so that the phone builds leave it out; free up space and notifications not offered |
| `lib/widgets/settings/backup_settings/backup_settings.dart` | backup while the app is open, no cellular options |
| `lib/presentation/pages/library.page.dart`, `lib/widgets/asset_viewer/detail_panel/exif_map.dart` | maps through `deviceFeaturesProvider.maps`; "On this computer" on the card of the device albums |
| `lib/presentation/pages/local_album.page.dart`, `lib/pages/backup/backup_album_selection.page.dart` | `FoldersEntry`: the way to the folders page, the banner while no folder is chosen |
| `lib/widgets/common/local_album_sliver_app_bar.dart`, `lib/presentation/widgets/panorama_360/panorama_360_filter_bar.widget.dart` | "On this computer" instead of "On this device" |
| `lib/presentation/widgets/camera/camera_live_view.widget.dart` | `DesktopCameraLiveView` (media_kit, `lib/desktop/video/camera_live_view.dart`) instead of the Android view, with the same states; the live view announced for later where libmpv is missing |
| `lib/presentation/widgets/asset_viewer/spatial_viewer.dart` | Spatial 2.5D announced for later instead of "not available on this device" |
| `lib/widgets/forms/login/login_form.dart` | OAuth through `deviceFeaturesProvider.oauth`, with a line saying so |
| `lib/presentation/widgets/local_session/local_session_permission_banner.dart` | `FoldersBanner` instead of the gallery permission |
| `lib/widgets/settings/ssl_client_cert_settings.dart` | `importClientCertificate` from a file instead of the system picker |
| `lib/presentation/pages/network/phone_share.page.dart` | computer wording, `confirmComputerShare` before starting |
| `lib/repositories/asset_media.repository.dart` | "Save to a folder" on Linux instead of the share sheet; the name of a shared download made safe for the computer |
| `lib/repositories/upload.repository.dart` | `openSharedRead` on Windows, so that a file being uploaded can still be renamed, moved or deleted |
| `lib/services/immich_logger.service.dart`, `lib/pages/common/app_log.page.dart` | "Save logs to a file"; file names without colons |
| `lib/utils/action_button.utils.dart` | "Delete from device" not offered |
| `lib/routing/router.dart` | `FoldersRoute`, registered on the computers only so that the phone builds leave out the folders page and the library behind it |
