Replacement of `flutter_secure_storage_windows` 3.1.2 for Immuch360 Desktop, used through `dependency_overrides` in
`mobile/pubspec.yaml`. It is not a copy of that package: it was written for Immuch360 and keeps its name only so that
`flutter_secure_storage` 9.2.4 picks it up as its Windows implementation.

Why: the C++ part of `flutter_secure_storage_windows` (Credential Manager, through `CA2W` and `CW2A`) includes
`<atlstr.h>`, so the Windows build needs the "C++ ATL" component of Visual Studio, which the build machines do not
have. The app reads and writes its secrets through `flutter_secure_storage` only (`SecureStorageRepository`), so a Dart
implementation of the platform interface is enough, and the rest of the app does not change.

What it does: every secret of the app lives in one file, `secure_storage.dat`, in the support folder of the app
(`getApplicationSupportDirectory()`, under `%APPDATA%`), as a JSON map from the keys the app uses to their values,
sealed by `CryptProtectData` of `crypt32.dll` (DPAPI, tied to the Windows user account, with an entropy of the app) and
opened by `CryptUnprotectData`. Writes go to a temporary file renamed over the old one, under a lock file, so that a
crash or a second isolate never leaves half a file. A file that can no longer be opened (another Windows account, a
damaged file) is kept aside as `secure_storage.dat.unreadable-<time>` and the store starts empty; a read error of the
disk is reported, never taken as an empty store.

The `WindowsOptions` of `flutter_secure_storage` (`useBackwardCompatibility`) are ignored: there is no older store to
read on a computer that never ran the app.

The package declares the `windows` platform only, so the Android and iOS builds do not see it. Its tests are in
`mobile/test/desktop/platform/secure_storage_test.dart`; the DPAPI round trip runs only on Windows.

Update: when `flutter_secure_storage` moves to a new major version, check that its platform interface still has the six
methods implemented here (`write`, `read`, `containsKey`, `delete`, `readAll`, `deleteAll`).
