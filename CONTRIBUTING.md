# Contributing to Immuch360

Thank you for your interest in Immuch360. Bug reports, tests on devices I do not have, fixes and new features are all welcome, on every platform the app runs on: Android phones and tablets, iPhone and iPad, Android TV and Google TV, Meta Quest, Windows, Linux and macOS.

## What this project is, and is not

Immuch360 is an independent fork of the [Immich](https://github.com/immich-app/immich) mobile app, under the [GNU AGPL v3](LICENSE). It keeps what the Immich app does and adds 360°, 3D and VR180 viewing, network shares, Plex, Tapo cameras, the Meta Quest immersive view, the TV layout and the computer version. The [README](README.md#the-project) explains why the fork exists, and [Platform support](docs/immuch360/platform-support.md) what each system has today.

It is not the Immich project: it is not affiliated with, nor endorsed by, the Immich team or FUTO, it does not change the Immich server, and the Immich maintainers do not review this repository.

- **A problem that also happens in the official Immich app**, or with the Immich server or web app, belongs to [Immich](https://github.com/immich-app/immich/issues).
- **Anything specific to Immuch360** belongs here: the 360°, 3D and VR180 viewers, the shares, Plex, Tapo, the Quest, the TV, the computer version, or a bug the official app does not have.

If you are not sure, open the issue here. I will tell you, and point it to Immich when it belongs there.

## Reporting a problem

Open an [issue](https://github.com/freeKC/Immuch360/issues/new/choose) on this repository and tell me:

- **The device and its system**: phone, tablet, TV, Quest, Windows, Linux or macOS, with the model and the system version.
- **The build**: the App Version line at the bottom of the menu of the profile picture, at the top right (for example `3.3.0-rc.0 build.23`), or the name of the file you installed and where it came from.
- **Where the media comes from**: the device itself, an Immich server, an SMB, WebDAV or DLNA share, Plex or a Tapo camera.
- **What kind of media**: flat, panorama, 360°, 3D, VR180 or a raw camera file, with the camera if you know it.
- **What you did, what you expected and what happened**, with a screenshot or a short video when you can.
- **The logs**, if you can get them: the Logs page, in the same menu, shares them, and on a computer it also has "Save logs to a file". [Troubleshooting](docs/immuch360/troubleshooting.md#logs) lists the `adb logcat` tags for Android and the Quest. Read the logs before posting them: they can contain your server address.

[Known issues](docs/immuch360/known-issues.md) lists what is already known, platform by platform.

Ideas and feature requests are welcome too: say what you would like and why it matters to you. The [Roadmap](README.md#roadmap) says what is planned.

## Proposing a change

1. Fork the repository and create your branch from `immuch360`, the default branch.
2. Keep one topic per pull request: one fix or one feature. Small pull requests are reviewed sooner. For something large, open an issue first so that we can agree on the approach.
3. Build and run the app as described in [Build it yourself](docs/immuch360/build.md), code generation included, and try the change on the devices it concerns.
4. Run the gates below, then open the pull request against `immuch360` and fill in the template.

A draft pull request is fine if you want an early opinion, and you do not need an issue assigned to you before you start.

### Gates

From the repository root, with Python 3 and nothing else to install:

```bash
python3 .github/desktop/check_desktop_imports.py
python3 .github/desktop/check_platform_ternaries.py
python3 .github/desktop/check_platform_audit.py
python3 .github/desktop/check_pigeon_desktop.py
python3 .github/desktop/check_workflow.py
```

For a change to the computer version, also run `check_phone_projects.py` and `check_phone_packages.py` from the same folder: they make sure the phone builds do not change.

Then, in `mobile/`:

```bash
mise exec -- flutter analyze
mise exec -- flutter test
mise exec -- dart format <the Dart files you changed>
```

If a gate fails and you do not see why, say so in the pull request. I would rather help than see the work dropped.

### Translations and documentation

- Add new text of the app as keys in `i18n/en.json` only. The other languages are generated at each release, so leave the other files of `i18n/` as they are.
- Leave `README.md`, `readme_i18n/` and `docs/immuch360/` alone unless I ask for a change there. I update them, with their translations, at each release. Describe the visible change in the pull request instead, and I will carry it into the documentation.

## Automated and machine generated pull requests

Pull requests written with automated tools or machine generated code are welcome, on one condition: you have built the result, run it on a real device, and you say so in the pull request, with the device and the build. A change that has never run is hard to review, whoever or whatever wrote it, and a test on a real device is what this project needs most.

## Licence and credits

Immuch360 is under the GNU AGPL v3, see [LICENSE](LICENSE). By opening a pull request, you agree that your contribution is published under the same licence.

Your authorship stays in the git history: your commits are merged or cherry picked with you as their author, and when I have to rework one, you stay its author or are named in a `Co-authored-by` line.

Contributors are thanked by name in [The project](README.md#the-project), the section of the README that already credits the work this fork builds on, from the release that ships their contribution. If you would rather not be named, or prefer another name, say so in the pull request.

## Languages

Code, comments, commit messages and pull requests are in English. Issues are welcome in English or in French.

## Contact

The [issues](https://github.com/freeKC/Immuch360/issues) are the place for questions, reports and ideas. The repository has no Discussions page and no chat server for now.
