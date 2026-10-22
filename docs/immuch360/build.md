# Build it yourself

How to build Immuch360 from its sources for phones, tablets, headsets, TVs and computers, and its app for LG webOS TVs, with the branches and the CI.

Back to the [README](../../README.md)

## Phones, tablets, headsets and TVs

The build chain is the one of Immich mobile (Flutter 3.47, managed with [mise](https://mise.jdx.dev)):

```bash
git clone https://github.com/freeKC/Immuch360.git
cd Immuch360/mobile
mise install
mise run install
mise run codegen
flutter build apk --release --flavor phone                                   # phones: the universal APK of the GitHub releases (add --split-per-abi for the per ABI files)
flutter build appbundle --release --flavor phone                             # the App Bundle sent to Google Play (also mise run build:android)
flutter build apk --release --flavor quest --target-platform android-arm64 --android-project-arg arm64only=true   # Meta Quest 2, Pro, 3 and 3S: the -quest-release.apk of the releases (also mise run build:quest)
flutter build ios --release                                                  # iPhone and iPad, on a Mac with Xcode and your own signing team
```

Store screenshots are taken on debug simulator builds made with `--dart-define=IMMUCH_SCREENSHOTS=true`, which only hides the debug banner.

The two Android flavours are the same app. From build 20 the `phone` one also declares itself as a TV app (a TV launcher entry and a banner, no touch screen required), which the `quest` one leaves out.

The `quest` one targets SDK 34 and keeps only the permissions the headset uses (photos, videos, notifications): media management, background location, legacy storage, audio, media location, device location and camera are removed in `android/app/src/quest/AndroidManifest.xml`, because the Meta Horizon Store refuses the first two and asks for a justification of every other sensitive one; the same file names the Quest 2, Quest Pro, Quest 3 and 3S as its supported devices and limits plain HTTP to the headset itself and to names of the home network. The APK is 64 bit only because of the two extra arguments of its command line (`--target-platform android-arm64 --android-project-arg arm64only=true`). The `phone` one is what Google Play requires.

To build for iOS on your own Mac, use Xcode and your own signing team; with Xcode 26, run `xcodebuild -downloadComponent MetalToolchain` once first, as the Spatial shaders need it. Without a Mac, iOS builds run on Codemagic (a hosted Mac) from the `codemagic.yaml` file of this repository. Before that build, `.github/workflows/immuch360-ios-check.yml` compiles the same release build without signing on a GitHub macOS runner, free for a public repository: on the push of a `release-*` branch that changes the iOS side, and by hand. Android release builds run on GitHub Actions (`.github/workflows/immuch360-release.yml`): the Android version code of a release is 3029998 plus the build number of its tag (3030026 for build 28, from build 25 on), and the workflow builds with NDK 28 (28.2.13676358, the NDK of Flutter 3.47.2), which it hands to the build hook of the Rust core as to Gradle.

**16 KB memory pages** (from build 26): Google Play requires apps that target Android 15 or later to support 16 KB memory pages on 64 bit devices. `native/.cargo/config.toml` links the Rust core of Immich for 16 KB pages whatever the NDK, and the release workflow checks the universal, arm64-v8a and x86_64 APKs, the Quest APK and the App Bundle with `mobile/scripts/check_16kb.sh` before it publishes them: a 64 bit native library aligned below 16 KB, an APK that is not zip aligned for 16 KB pages, or a bundle not set for them stops the release. The 32 bit libraries are reported only. To check a build of your own, with the zipalign of build-tools 35 or later:

```bash
ZIPALIGN="$ANDROID_HOME/build-tools/36.0.0/zipalign" bash scripts/check_16kb.sh build/app/outputs/flutter-apk/app-phone-release.apk
```

**Unit tests of the Android code** (from build 27): the release workflow has a job that runs the Kotlin unit tests of the `phone` flavour and keeps their report as the `kotlin-unit-tests` artifact. On a tag or a manual run it runs next to the build, and the GitHub Release of a tag waits for both; a push to any branch that changes `mobile/android` runs the tests alone. The Gradle wrapper and `local.properties` are written by the Flutter tool, so run them, after the code generation, with:

```bash
flutter build apk --config-only
cd android && ./gradlew :app:testPhoneDebugUnitTest -Ptarget-platform=android-x64
```

**libsmb2 and its source** (from build 27): the SMB shares use libsmb2, under the GNU LGPL, whose corresponding source travels with every build. `mise run codegen` runs the task `codegen:libsmb2-sources`, which packs it with `.github/desktop/libsmb2/pack_sources.py` (the pinned commit of libsmb2-scripts, read from git, the libsmb2 archive it names, checked by its SHA-256, `build_linux.sh` and a README) into `mobile/packages/dart_smb2/libsmb2/Immuch360-libsmb2-sources.tar.gz`, ignored by git, next to the notice and the licence texts that every build carries as assets. The archive is the same, byte for byte, wherever it is packed (the Linux runners and the Mac of the CI gave the same file). A build made without the code generation works, without the archive: the release workflows check that every APK, the App Bundle, the Windows ZIP, the .deb, the .rpm and the macOS app hold it, with the notice and the texts, and Codemagic checks the IPA. When the upstream sources do not answer, the packer takes the same files from the release [libsmb2-inputs-f0688e7](https://github.com/freeKC/Immuch360/releases/tag/libsmb2-inputs-f0688e7) of the project.

Immuch360 Desktop, the computer version, builds from the same sources, the `immuch360` branch: with Flutter for Windows, the steps are in [Build it yourself on Windows](#build-it-yourself-on-windows), and for Linux and macOS in [macOS and Linux](#macos-and-linux). How the installer and the packages are made is in [Packages of Immuch360 Desktop](#packages-of-immuch360-desktop). The app for LG webOS TVs builds from the `webos/` folder with Node.js, see [LG webOS TVs](#lg-webos-tvs).

No secret lives in this repository: the Android signing key is stored as encrypted GitHub Actions secrets, and the Apple signing material is stored as encrypted variables on Codemagic. The workflow files only reference them by name. Without your own `android/key.jks`, a release build is signed with the debug key and cannot install over a copy from GitHub or a store (uninstall that one first); a debug build installs next to it as Immuch360 debug. The Meta Horizon Store copy is the `quest` APK of the release signed with another key, the one the store app was first registered with, so it cannot install over a sideloaded APK either, nor the other way round.

## Branches

- **`main`**: Immich `main` at the commit `immuch360` is based on (10 October 2026 for the current builds), never modified; it moves forward when the fork is rebased on a newer Immich.
- **`immuch360`**: the changes of this fork on top of Immich, Immuch360 Desktop included since 9 October 2026. Each release says which Immich version it is based on.
- **`desktop`**: where Immuch360 Desktop, the computer version, was built on top of `immuch360`, until it was merged into it on 9 October 2026 so that phones, headsets, TVs and computers ship from the same sources. It now follows `immuch360` and carries the desktop pre-release tags ([desktop build 1](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-1) from commit 21f285c34, [desktop build 2](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-2) from 5b723bd25, [desktop build 3](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-3) from the merge of the 360° video player on 10 October 2026, [desktop build 4](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-4) from 99113354a, with build 22 and the project's own libmpv, [desktop build 5](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-5) from a45de2f00, with build 24, the installer and the Linux and macOS packages, [desktop build 6](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-6) from the merge of 20 October 2026, with build 26 and the videos of Linux and macOS, [desktop build 7](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-7) of 22 October 2026, with build 27, the graphics chip on X11 and the libsmb2 sources, [desktop build 8](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-8) with build 28, the first signed by the release workflow). New desktop work lands there first and joins `immuch360` with the desktop build that ships it. The computer version changes nothing under `mobile/android` and `mobile/ios`; a phone change made on another branch first is listed, file by file with its content, in `.github/desktop/phone-projects-exempt.json` until it reaches `immuch360`.
- **Tags `webos-v<x.y.z>`**: the pre-releases of the app for LG webOS TVs, made from the `webos/` folder ([webos-v0.1.0](https://github.com/freeKC/Immuch360/releases/tag/webos-v0.1.0) of 21 October 2026, [webos-v0.1.1](https://github.com/freeKC/Immuch360/releases/tag/webos-v0.1.1) of 22 October 2026, [webos-v0.2.0](https://github.com/freeKC/Immuch360/releases/tag/webos-v0.2.0) with build 28).

## Build it yourself on Windows

You need Windows 10 or 11 on x64, Flutter 3.47.2 for Windows, Visual Studio 2022 or its Build Tools with the "Desktop development with C++" workload, Developer Mode turned on in the Windows settings (Flutter needs it for the plugins), and Python 3 for the bundle script. The build also compiles the native core of Immich, written in Rust: install rustup and the toolchain that `native/crates/native_core_ffi/rust-toolchain.toml` names (1.98.0 today), as the CI does.

1. Get the sources and run the code generation. The main branch, `immuch360`, builds the computer version too: there is no branch to switch to. The code generation uses Java and Node, so run it on Linux, macOS or in WSL; with WSL, keep the clone on a Windows drive, which WSL sees under `/mnt/c` or `/mnt/d`:

   ```bash
   git clone https://github.com/freeKC/Immuch360.git
   cd Immuch360/mobile
   mise install
   mise run install
   mise run codegen
   ```

2. On Windows, in the same `mobile` folder, build the app. The first build downloads the libraries of the video player (libmpv and ANGLE) from GitHub and checks each archive by its SHA-256; it also compiles the small Direct3D 11 plugin that reads the decoders of the graphics chip, `immuch_desktop_video`, with the same C++ workload:

   ```bat
   flutter pub get
   REM try it, with hot reload: a debug build, with a profile of its own (Immuch360 Desktop Debug), so it runs next to the app
   flutter run -d windows -t lib/main_desktop.dart
   REM the app, in build\windows\x64\runner\Release\immuch360.exe
   flutter build windows --release -t lib/main_desktop.dart
   ```

3. The `Release` folder runs on the PC that built it. For another PC, keep the whole folder and add the Visual C++ runtime next to `immuch360.exe`. From the root of the clone, the bundle script copies it, leaves out what only serves Android, adds the licences of the video player, checks that every DLL the app loads is in the folder or in Windows itself, and makes the ZIP:

   ```bat
   python .github\desktop\windows_bundle.py --release mobile\build\windows\x64\runner\Release --out <folder> --zip <file.zip>
   ```

4. To make the installer of that folder, install [Inno Setup 6](https://jrsoftware.org/isinfo.php), then, from the root of the clone, give the folder the bundle script made, the version label and the file version (`python .github\desktop\desktop_version.py` prints both, as `label` and `file_version`):

   ```bat
   python .github\desktop\desktop_installers.py windows --bundle "<folder>\Immuch360 Desktop" --label <label> --file-version <A.B.C.D> --out <folder>
   ```

   It writes `Immuch360-Desktop-<label>-windows-x64-setup.exe` next to the ZIP, see [Packages of Immuch360 Desktop](#packages-of-immuch360-desktop).

The CI of Immuch360 Desktop (`.github/workflows/immuch360-desktop.yml`) runs on the `desktop` branch, which follows `immuch360`: the phone gates (nothing changes in the phone builds) and the whole test suite on Linux, the desktop tests on Windows, and the same ZIP and its installer, then on that build the tests that need its libmpv and ANGLE (the Tapo live view's sign in, what a video file may not open, the 360° shaders); its Linux job builds libsmb2 and the app on Ubuntu 22.04, runs the tests that need libmpv with the system's libmpv, makes the .deb and the .rpm, and plays a short video with the build on a virtual screen (Xvfb), from desktop build 7 on the hardware path, after a test program of the isolated EGL context of the video plugin under X11 (`mobile/packages/media_kit_video/linux/test/isolated_egl_test.cc`); each package is then installed in a container of five distributions, where it must play the same video; its macOS job builds the app with Xcode 26.3 and the macOS 26 SDK, checks the libmpv frameworks and their notices in it, zips it, makes a DMG, and runs a self check of the app on the runner (all with the same `-t lib/main_desktop.dart`). A second workflow (`.github/workflows/immuch360-libmpv.yml`) rebuilds libmpv from pinned sources for Windows x64 and arm64 and, from desktop build 6, for macOS (universal xcframeworks, release [libmpv-macos-20261020-9](https://github.com/freeKC/Immuch360/releases/tag/libmpv-macos-20261020-9), mpv 0.41.0 and FFmpeg 8.0 under the LGPL), and publishes the archives with their SHA-256 and their sources; only the x64 Windows archive goes into an app ZIP so far, as there is no Windows on ARM build of the app yet. Since desktop build 4 the Windows build downloads that libmpv by default, from the release [libmpv-windows-20261009-3](https://github.com/freeKC/Immuch360/releases/tag/libmpv-windows-20261009-3) of the project, pinned by its SHA-256 in `mobile/packages/media_kit_libs_windows_video/windows/CMakeLists.txt`: it stacks the two lenses of raw videos in one player and lets the graphics chip draw the 360° view without copying each frame back. Setting the environment variable `IMMUCH360_LIBMPV_FROM_CI` to `OFF` for a build takes media-kit's 2024 archive instead, the one of the desktop builds before build 4.

## macOS and Linux

The CI of Immuch360 Desktop builds both on every change of the `desktop` branch and makes their packages. From desktop build 6 their videos play through libmpv: on Linux the libmpv of the system, which the app opens at run time without linking it, so one build runs with `libmpv.so.2` and `libmpv.so.1`; on macOS the project's own libmpv frameworks, which the package `mobile/packages/media_kit_libs_macos_video` downloads by their SHA-256 from the release of the libmpv workflow. The macOS app has only run on the CI's Mac, see [Platform support](platform-support.md#macos-and-linux). Run the code generation as for the other builds, then, in the `mobile` folder:

```bash
# Linux, on Ubuntu 22.04 or later, with the packages the CI installs:
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev libmpv-dev patchelf
# optional, on Ubuntu 22.04 as the CI does: libsmb2 built again for older systems, instead of the download that needs glibc 2.38;
# from build 27 it builds offline from the packed sources, given as a second argument or packed first
bash ../.github/desktop/libsmb2/build_linux.sh /tmp/libsmb2 && export IMMUCH360_LIBSMB2=/tmp/libsmb2/libsmb2.so
flutter build linux --release -t lib/main_desktop.dart

# macOS, with Xcode 26.3 and the macOS 26 SDK; the native core of Immich is built for both slices:
mise exec -- rustup target add --toolchain 1.98.0 aarch64-apple-darwin x86_64-apple-darwin
flutter build macos --release -t lib/main_desktop.dart
```

The macOS build of the CI is signed for the computer that runs it only ("Sign to Run Locally", without an Apple certificate) and not notarized, so it keeps its secrets in the login keychain. A build signed with a Developer ID and a keychain access group may use the data protection keychain instead, with `--dart-define=IMMUCH360_MACOS_DATA_PROTECTION_KEYCHAIN=true`; the secrets of the login keychain are not moved, so users sign in once more.

## Packages of Immuch360 Desktop

Each run of the desktop CI makes seven files (six up to desktop build 6), each an artifact of the run, named after the version label of `.github/desktop/desktop_version.py` (`3.3.0-rc.0-desktop.7` on the commit of a desktop pre-release tag, `3.3.0-rc.0-26-e6afc4d` between two releases):

| File | What it is | Made by |
|---|---|---|
| `Immuch360-Desktop-<label>-windows-x64-setup.exe` | The Windows installer, from the same folder as the ZIP | Inno Setup 6 on the Windows runner, from `.github/desktop/packaging/windows/immuch360.iss` |
| `Immuch360-Desktop-<label>-windows-x64.zip` | The folder of the app, to unzip anywhere | `.github/desktop/windows_bundle.py` |
| `Immuch360-Desktop-<label>-linux-amd64.deb` | Debian and Ubuntu package | [nFPM](https://nfpm.goreleaser.com) 2.47.0, pinned by its SHA-256 |
| `Immuch360-Desktop-<label>-linux-x86_64.rpm` | Fedora package | nFPM, from the same description |
| `Immuch360-Desktop-<label>-macos.dmg` | The macOS app (universal) in a disk image | `hdiutil` on the macOS runner |
| `Immuch360-Desktop-<label>-macos.zip` | The same app, zipped | `ditto` |
| `Immuch360-Desktop-<label>-libsmb2-sources.tar.gz` | The corresponding source of libsmb2, the archive every build carries (from desktop build 7) | `.github/desktop/libsmb2/pack_sources.py`, in the code generation |

- **The file types**: `.github/desktop/file-associations.json` lists the photos and videos the packages offer "Open with" for, with a one line description each. `.github/desktop/desktop_installers.py` turns it into the registry entries of the installer, the `MimeType=` line of the Linux desktop entry and the MIME types of the raw camera files (.insp, .insv, .360, .osv), and the `CFBundleDocumentTypes` of `mobile/macos/Runner/Info.plist`. After a change of the list, run `python3 .github/desktop/desktop_installers.py macos --write`; the gates job runs `desktop_installers.py check`, which fails when Info.plist and the list differ or when an extension has no Linux or macOS type.
- **Windows**: the installer is per user (no administrator rights, in `%LOCALAPPDATA%\Programs`) or for every user of the PC (Program Files), in every language Inno Setup ships, with a Start menu entry, an optional desktop shortcut and an uninstaller. It registers the app in "Open with" and in the Default apps settings, never as the default program of a type. The language is that of Windows, and the language dialog, after the choice between one user and every user, lets the user pick another. Silent installation: `/VERYSILENT /CURRENTUSER` or `/ALLUSERS`, `/DIR="<folder>"`, `/LANG=<name>`; the uninstaller, `unins000.exe` in the folder of the app, takes `/VERYSILENT` too. From desktop build 7 the `licenses` folder of the app holds libsmb2's notice and licence texts in `licenses/libsmb2/`, and `windows_bundle.py` stops when one of them, or the source archive among the assets, is missing.
- **Linux**: from the bundle of `flutter build linux`, `desktop_installers.py linux` installs the app in `/opt/immuch360`, a launcher in `/usr/bin/immuch360` (which also answers `--version`), the desktop entry `com.aprogsys.immuch360.desktop`, the icons and the MIME types, and declares the libraries the app needs (GTK 3, libsecret, WebKitGTK 4.1, libsoup 3, libepoxy and libmpv: `libmpv2 | libmpv1` on Debian and Ubuntu, `mpv-libs` on Fedora), and `xdg-user-dirs`, which gives the app its documents folder. From desktop build 7 the .deb has a section for `/opt/immuch360/lib/libsmb2.so` in its copyright file, with libsmb2's notice and the LGPL text, and the .rpm installs those texts in `/usr/share/licenses/immuch360/libsmb2/`; the packaging stops when a text or the source archive is missing. With [nFPM](https://nfpm.goreleaser.com) installed:

  ```bash
  python3 .github/desktop/desktop_installers.py linux --bundle mobile/build/linux/x64/release/bundle --label <label> --out dist
  # the check of the CI, in a clean container of a distribution:
  docker run --rm -v "$PWD/dist:/pkgs:ro" -v "$PWD/.github/desktop/packaging/linux:/check:ro" ubuntu:24.04 \
    sh /check/check_package.sh /pkgs/Immuch360-Desktop-<label>-linux-amd64.deb
  ```

  The check installs the package with its dependencies, then makes sure that `immuch360 --version` answers, that every library each ELF file of `/opt/immuch360` needs is found (libmpv and libsmb2 among them, with no newer glibc than the system's), that the desktop entry is valid and that the MIME types are registered; with `--video`, as the CI runs it, the installed app must also play a short video on a virtual screen with the distribution's libmpv. The CI runs it on Ubuntu 22.04 and 24.04, Debian 12, Fedora 40 and Fedora 44. The test clip is H.264 Constrained Baseline, since Fedora's own FFmpeg decodes H.264 through OpenH264 only. OpenH264 comes from Fedora's Cisco repository: when that repository does not answer, dnf installs a stub without a decoder, and the check of Fedora fails on "libopenh264: Unable to create decoder", a reason outside the app (seen on Fedora 40 on 21 October 2026, while the same .rpm passed on another computer).
- **macOS**: the CI zips the app with `ditto -c -k --sequesterRsrc --keepParent` and makes the DMG with `hdiutil create -format UDZO`, with a link to the Applications folder. It then registers the app with Launch Services and asks it, as Finder does for "Open with", which apps open a file of each extension of the list (`.github/desktop/packaging/macos/open_with.swift`), and starts the app on the runner: once for 30 seconds, then three times with its self check (`lib/desktop/window/self_check.dart`, which runs only when `IMMUCH360_SELF_CHECK` names a file): a folder of a photo and a video on the command line, the video alone, then the photo through Launch Services followed by the video handed to the app that runs. Each start checks the keychain, the pages shown, libmpv and 5 seconds of video; `.github/desktop/packaging/macos/self_check_summary.py` writes the results in the run summary, and the captures and logs go to the `macos-first-start` artifact. Its steps do not fail the job: a failed check marks the summary.
- **Releases**: a tag `desktop-v<version>-<n>` (desktop build n) starts `.github/workflows/immuch360-desktop-release.yml`, which runs the desktop CI on the tag and attaches the seven files to the GitHub release of the tag, with `SHA256SUMS.txt` for every file of the release. It creates the release as a pre-release when the tag has none, and keeps the notes of a release written by hand. The owner runs the same script, `.github/desktop/desktop_release.py`, with a token of their own, to write the notes or add a file: `python3 .github/desktop/desktop_release.py --repo freeKC/Immuch360 --tag desktop-v<version>-<n> --name "<name>" --notes <notes.md> --token-file <file> [files]`. It is the only desktop workflow that writes to the repository; `.github/desktop/check_workflow.py --release` keeps it on those tags, pinned, and without any secret but the three of its signing job (below). It first ran with the tag of desktop build 5, on 13 October 2026; its upload is also covered by the tests of `desktop_release.py` against a fake GitHub server, and the gathering of the seven files by the `packages` job of every desktop CI run.
- **Signing of the Windows files** (from desktop build 8; the installer and the ZIP of desktop build 7 were signed by hand on 22 October 2026, with the same account): the `sign-windows` job of the release workflow, on the Windows runner, signs with `.github/desktop/windows_sign.py`, through Azure Artifact Signing (account APROGSYS, certificate profile APROGSYS-PublicTrust, SHA-256 and a timestamp of Microsoft), every `.exe` and `.dll` of the ZIP of the build that has no signature yet (24 of them; nine DLLs come signed by Microsoft or Google and keep that signature), writes the ZIP again with the same entries, then makes the installer again from the signed folder, Inno Setup signing its uninstaller and itself (`desktop_installers.py windows --sign-with`). signtool and the signing client come from nuget.org at the versions of the official `azure/artifact-signing-action` v2.0.0, checked by their SHA-256: the action itself cannot be called by Inno Setup for the uninstaller. The job checks every file with `signtool verify /pa`, installs the signed installer silently on the runner to check its uninstaller and its files, and replaces the two Windows artifacts of the run with the signed ones; the release job attaches those, checked by their SHA-256, so `SHA256SUMS.txt` is that of the signed files. The credentials of the signing account are the repository secrets `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET`, given to the steps that sign and to nothing else; `check_workflow.py --release` refuses them anywhere else, and any other secret. To try it without a release, run the workflow by hand on a branch with `sign_test` set: it builds, signs and keeps the signed files as artifacts of the run, and skips the release job. The macOS app and the Linux packages stay unsigned.

## LG webOS TVs

The app for LG webOS TVs lives in the `webos/` folder: an Enact (React) app built on [Immich TV for webOS](https://github.com/Seeky91/immich-tv-webos) 1.7.0 by Seeky91, with the layers of Immuch360 in `webos/src/immuch360/`. It needs Node.js 24 (`webos/.nvmrc`); the Enact and webOS command line tools are pinned in `webos/package.json`, and nothing is installed globally:

```bash
cd webos
npm ci
npm run test-unit    # node tests of the Immuch360 layers (360° rules, keys, the rotation, texts, Immich client, sources)
npm run test-bridge  # node tests of the media bridge of the service (webOS 0.2.0), against local fake servers
npm test             # the jest tests inherited from immich-tv-webos, and ours
npm run typecheck
npm run ipk          # build/com.aprogsys.immuch360_<version>_all.ipk, then checks its content
npm run set-version -- 0.2.0   # the version of appinfo.json and of the service
```

`npm run ipk` reads the texts from `../i18n/*.json`, the files of the Flutter app: the texts only the TV app has are the `webos_*` keys of `i18n/en.json`, translated with the others at a release. It also writes the licence files into the package (the AGPL of Immuch360, the MIT licence of immich-tv-webos and a notice with the link to the source of the tag), and `tools/check-package.mjs` checks the ids, the icons, the locales and those files. The workflow `.github/workflows/immuch360-webos.yml` tests and builds the `.ipk` on every push that touches `webos/` or `i18n/`, and by hand, with the artifact `Immuch360-webOS-<version>`; `.github/workflows/immuch360-webos-release.yml` builds it from a `webos-v<x.y.z>` tag and publishes it as a pre-release with `SHA256SUMS.txt`, and `check_workflow.py --release --tag-prefix webos-v` keeps it on those tags. How to install it on a TV is in [Install it on an LG TV](platform-support.md#install-it-on-an-lg-tv).

Last updated: 22 October 2026 (build 28, desktop build 8, webOS 0.2.0)
