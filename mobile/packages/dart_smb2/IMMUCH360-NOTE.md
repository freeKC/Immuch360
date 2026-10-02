# dart_smb2 0.1.3, vendored copy for Immuch360

Copied from pub.dev (BSD-3-Clause, https://github.com/ales-drnz/dart_smb2), without the example and the images, with one change:

- `lib/src/smb2_client.dart`, `_applyCredentials`: an empty password is passed to libsmb2 (`smb2_set_password("")`) instead of
  being dropped. Dropping it made libsmb2 log on anonymously, which servers such as the Freebox Server refuse for their disk
  shares while they accept the user "freebox" with an empty password. A null password still means an anonymous logon.

Everything else is the upstream package. Remove this copy and the `dependency_overrides` entry of `mobile/pubspec.yaml` once
upstream accepts an equivalent change.
