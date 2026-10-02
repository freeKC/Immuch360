Copy of the background_downloader 9.5.6 package (MIT, https://pub.dev/packages/background_downloader) used through
`dependency_overrides` in `mobile/pubspec.yaml`. One change: in `android/.../Helpers.kt`, `acceptUntrustedCertificates()`
no longer installs an X509TrustManager that accepts every certificate; it only logs. Immuch360 never asks the plugin
to bypass TLS validation, and the Meta Horizon Store security scan flags that code. Update by copying a newer
package version here and applying the same change.
