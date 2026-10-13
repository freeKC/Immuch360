# Build it yourself

How to build Immuch360 from its sources for phones, tablets, headsets, TVs and computers, with the branches and the CI.

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

To build for iOS on your own Mac, use Xcode and your own signing team; with Xcode 26, run `xcodebuild -downloadComponent MetalToolchain` once first, as the Spatial shaders need it. Without a Mac, iOS builds run on Codemagic (a hosted Mac) from the `codemagic.yaml` file of this repository. Android release builds run on GitHub Actions (`.github/workflows/immuch360-release.yml`).

Immuch360 Desktop, the computer version, builds from the same sources, the `immuch360` branch: with Flutter for Windows, the steps are in [Build it yourself on Windows](#build-it-yourself-on-windows), and for Linux and macOS in [macOS and Linux](#macos-and-linux). How the installer and the packages are made is in [Packages of Immuch360 Desktop](#packages-of-immuch360-desktop).

No secret lives in this repository: the Android signing key is stored as encrypted GitHub Actions secrets, and the Apple signing material is stored as encrypted variables on Codemagic. The workflow files only reference them by name. Without your own `android/key.jks`, a release build is signed with the debug key and cannot install over a copy from GitHub or a store (uninstall that one first); a debug build installs next to it as Immuch360 debug. The Meta Horizon Store copy is the `quest` APK of the release signed with another key, the one the store app was first registered with, so it cannot install over a sideloaded APK either, nor the other way round.

## Branches

- **`main`**: Immich `main` at the commit `immuch360` is based on (10 October 2026 for the current builds), never modified; it moves forward when the fork is rebased on a newer Immich.
- **`immuch360`**: the changes of this fork on top of Immich, Immuch360 Desktop included since 9 October 2026. Each release says which Immich version it is based on.
- **`desktop`**: where Immuch360 Desktop, the computer version, was built on top of `immuch360`, until it was merged into it on 9 October 2026 so that phones, headsets, TVs and computers ship from the same sources. It now follows `immuch360` and carries the desktop pre-release tags ([desktop build 1](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-1) from commit 21f285c34, [desktop build 2](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-2) from 5b723bd25, [desktop build 3](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-3) from the merge of the 360° video player on 10 October 2026, [desktop build 4](https://github.com/freeKC/Immuch360/releases/tag/desktop-v3.3.0-rc.0-4) from 99113354a, with build 22 and the project's own libmpv). New desktop work lands there first and joins `immuch360` with the desktop build that ships it. The computer version changes nothing under `mobile/android` and `mobile/ios`.

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

The CI of Immuch360 Desktop (`.github/workflows/immuch360-desktop.yml`) runs on the `desktop` branch, which follows `immuch360`: the phone gates (nothing changes in the phone builds) and the whole test suite on Linux, the desktop tests on Windows, and the same ZIP and its installer, then on that build the tests that need its libmpv and ANGLE (the Tapo live view's sign in, what a video file may not open, the 360° shaders); its Linux job builds the app on Ubuntu and makes the .deb and the .rpm, which are installed and checked in containers of five distributions, and its macOS job builds the app with Xcode 26.3 and the macOS 26 SDK, zips it and makes a DMG (all with the same `-t lib/main_desktop.dart`). A second workflow (`.github/workflows/immuch360-libmpv.yml`) rebuilds libmpv for Windows x64 and arm64 from pinned sources and publishes the archives with their SHA-256 and their sources; only the x64 archive goes into an app ZIP so far, as there is no Windows on ARM build of the app yet. Since desktop build 4 the Windows build downloads that libmpv by default, from the release [libmpv-windows-20261009-3](https://github.com/freeKC/Immuch360/releases/tag/libmpv-windows-20261009-3) of the project, pinned by its SHA-256 in `mobile/packages/media_kit_libs_windows_video/windows/CMakeLists.txt`: it stacks the two lenses of raw videos in one player and lets the graphics chip draw the 360° view without copying each frame back. Setting the environment variable `IMMUCH360_LIBMPV_FROM_CI` to `OFF` for a build takes media-kit's 2024 archive instead, the one of the desktop builds before build 4.

## macOS and Linux

The CI of Immuch360 Desktop builds both on every change of the `desktop` branch and makes their packages; their video player library (libmpv) is not built into them yet, and the macOS app has only run on the CI's Mac, see [Platform support](platform-support.md#macos-and-linux). Run the code generation as for the other builds, then, in the `mobile` folder:

```bash
# Linux, on Ubuntu 22.04 or later, with the packages the CI installs:
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev
flutter build linux --release -t lib/main_desktop.dart

# macOS, with Xcode 26.3 and the macOS 26 SDK; the native core of Immich is built for both slices:
mise exec -- rustup target add --toolchain 1.98.0 aarch64-apple-darwin x86_64-apple-darwin
flutter build macos --release -t lib/main_desktop.dart
```

The macOS build of the CI is signed for the computer that runs it only ("Sign to Run Locally", without an Apple certificate) and not notarized.

## Packages of Immuch360 Desktop

Each run of the desktop CI makes six files, each an artifact of the run, named after the version label of `.github/desktop/desktop_version.py` (`3.3.0-rc.0-desktop.5` on the commit of a desktop pre-release tag, `3.3.0-rc.0-23-d7103a7` between two releases):

| File | What it is | Made by |
|---|---|---|
| `Immuch360-Desktop-<label>-windows-x64-setup.exe` | The Windows installer, from the same folder as the ZIP | Inno Setup 6 on the Windows runner, from `.github/desktop/packaging/windows/immuch360.iss` |
| `Immuch360-Desktop-<label>-windows-x64.zip` | The folder of the app, to unzip anywhere | `.github/desktop/windows_bundle.py` |
| `Immuch360-Desktop-<label>-linux-amd64.deb` | Debian and Ubuntu package | [nFPM](https://nfpm.goreleaser.com) 2.47.0, pinned by its SHA-256 |
| `Immuch360-Desktop-<label>-linux-x86_64.rpm` | Fedora package | nFPM, from the same description |
| `Immuch360-Desktop-<label>-macos.dmg` | The macOS app (universal) in a disk image | `hdiutil` on the macOS runner |
| `Immuch360-Desktop-<label>-macos.zip` | The same app, zipped | `ditto` |

- **The file types**: `.github/desktop/file-associations.json` lists the photos and videos the packages offer "Open with" for, with a one line description each. `.github/desktop/desktop_installers.py` turns it into the registry entries of the installer, the `MimeType=` line of the Linux desktop entry and the MIME types of the raw camera files (.insp, .insv, .360, .osv), and the `CFBundleDocumentTypes` of `mobile/macos/Runner/Info.plist`. After a change of the list, run `python3 .github/desktop/desktop_installers.py macos --write`; the gates job runs `desktop_installers.py check`, which fails when Info.plist and the list differ or when an extension has no Linux or macOS type.
- **Windows**: the installer is per user (no administrator rights, in `%LOCALAPPDATA%\Programs`) or for every user of the PC (Program Files), in every language Inno Setup ships, with a Start menu entry, an optional desktop shortcut and an uninstaller. It registers the app in "Open with" and in the Default apps settings, never as the default program of a type. The language is that of Windows, and the language dialog, after the choice between one user and every user, lets the user pick another. Silent installation: `/VERYSILENT /CURRENTUSER` or `/ALLUSERS`, `/DIR="<folder>"`, `/LANG=<name>`; the uninstaller, `unins000.exe` in the folder of the app, takes `/VERYSILENT` too.
- **Linux**: from the bundle of `flutter build linux`, `desktop_installers.py linux` installs the app in `/opt/immuch360`, a launcher in `/usr/bin/immuch360` (which also answers `--version`), the desktop entry `com.aprogsys.immuch360.desktop`, the icons and the MIME types, and declares the libraries the app needs (GTK 3, libsecret, WebKitGTK 4.1, libsoup 3, libepoxy and libmpv: `libmpv2 | libmpv1` on Debian and Ubuntu, `mpv-libs` on Fedora). With [nFPM](https://nfpm.goreleaser.com) installed:

  ```bash
  python3 .github/desktop/desktop_installers.py linux --bundle mobile/build/linux/x64/release/bundle --label <label> --out dist
  # the check of the CI, in a clean container of a distribution:
  docker run --rm -v "$PWD/dist:/pkgs:ro" -v "$PWD/.github/desktop/packaging/linux:/check:ro" ubuntu:24.04 \
    sh /check/check_package.sh /pkgs/Immuch360-Desktop-<label>-linux-amd64.deb
  ```

  The check installs the package with its dependencies, then makes sure that `immuch360 --version` answers, that every library each ELF file of `/opt/immuch360` needs is found, that libmpv is there, that the desktop entry is valid and that the MIME types are registered. The CI runs it on Ubuntu 22.04 and 24.04, Debian 12, Fedora 40 and Fedora 44.
- **macOS**: the CI zips the app with `ditto -c -k --sequesterRsrc --keepParent` and makes the DMG with `hdiutil create -format UDZO`, with a link to the Applications folder. It then registers the app with Launch Services and asks it, as Finder does for "Open with", which apps open a file of each extension of the list (`.github/desktop/packaging/macos/open_with.swift`), and starts the app once on the runner, with a capture of its screen in the `macos-first-start` artifact.
- **Releases**: a tag `desktop-v<version>-<n>` (desktop build n) starts `.github/workflows/immuch360-desktop-release.yml`, which runs the desktop CI on the tag and attaches the six files to the GitHub release of the tag, with `SHA256SUMS.txt` for every file of the release. It creates the release as a pre-release when the tag has none, and keeps the notes of a release written by hand. The owner runs the same script, `.github/desktop/desktop_release.py`, with a token of their own, to write the notes or add a file: `python3 .github/desktop/desktop_release.py --repo freeKC/Immuch360 --tag desktop-v<version>-<n> --name "<name>" --notes <notes.md> --token-file <file> [files]`. It is the only desktop workflow that writes to the repository; `.github/desktop/check_workflow.py --release` keeps it on those tags, pinned and without secrets. It runs for the first time with the tag of desktop build 5: until then its upload is covered by the tests of `desktop_release.py` against a fake GitHub server, and the gathering of the six files by the `packages` job of every desktop CI run.

Last updated: 13 October 2026 (build 23, desktop build 4, the packages of desktop build 5)
