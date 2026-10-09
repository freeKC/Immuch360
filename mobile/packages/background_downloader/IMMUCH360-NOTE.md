Copy of the background_downloader 9.5.6 package (MIT, https://pub.dev/packages/background_downloader) used through
`dependency_overrides` in `mobile/pubspec.yaml`. Two changes, to apply again when a newer package version is copied
here:

1. In `android/.../Helpers.kt`, `acceptUntrustedCertificates()` no longer installs an X509TrustManager that accepts
   every certificate; it only logs. Immuch360 never asks the plugin to bypass TLS validation, and the Meta Horizon
   Store security scan flags that code.

2. Immuch360 Desktop: the desktop transfers (`lib/src/desktop/`) run each task in an isolate of its own with a plain
   `HttpClient`, so they would see neither the certificates the user trusts in the app, nor the client certificate of
   the user's server, nor the session cookie of that server (the phones' native transfers take them from the app's
   shared TLS configuration and cookie store). The app hands them over through `configureDesktopTransfers` of the new
   file `lib/src/desktop/transfer_security.dart`, exported by `lib/background_downloader.dart`:
   - `DesktopTransferSecurity` holds the trusted certificates (PEM or DER) and the PKCS #12 client certificate with
     its password, and builds the `SecurityContext` (system roots plus that material); `DesktopTransfers` keeps what
     the app configured in the isolate, and the file imports nothing of the downloader, so that exporting it does not
     bring `dart:isolate` code into the library on other platforms;
   - `desktop_downloader.dart`: `httpClient` becomes a getter that rebuilds the client when the configuration
     changed; `transferSecurity`, `transferHeadersOf` and `useTaskTransfer` are new; `_executeTask` sends the material
     and the headers made for the task's URL with the task's arguments; `_recreateClient` builds
     `HttpClient(context: ...)` and wraps the client in `_TransferHeadersClient`, which adds those headers to requests
     to the task's origin only, without replacing a header of the task;
   - `isolate.dart`: `doTask` reads the two new arguments and calls `useTaskTransfer` before `setHttpClient`.
   `FileDownloader.request` (a compute isolate, not used by the app) is left as it was. Nothing changes on Android,
   iOS or the web, and nothing changes on the desktop while the app configures nothing.
