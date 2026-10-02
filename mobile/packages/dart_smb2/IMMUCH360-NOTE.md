# dart_smb2 0.1.3, vendored copy for Immuch360

Copied from pub.dev (BSD-3-Clause, https://github.com/ales-drnz/dart_smb2), without the example and the images, with two changes:

- `lib/src/smb2_client.dart`, `_applyCredentials`: an empty password is passed to libsmb2 (`smb2_set_password("")`) instead of
  being dropped. Dropping it made libsmb2 log on anonymously, which servers such as the Freebox Server refuse for their disk
  shares while they accept the user "freebox" with an empty password. A null password still means an anonymous logon.
- `lib/src/pool/context_lock.dart` (new, exported), `lib/src/pool/pool.dart`: every worker spawn and close of every pool, the
  respawns of the auto-reconnect included, and `Smb2Pool.listSharesOn` run one at a time through `Smb2ContextLock`, a lock for
  the whole isolate. libsmb2 changes its global `active_contexts` list without a lock in `smb2_init_context` and
  `smb2_destroy_context`; upstream only ordered the spawns of one pool, so two pools reconnecting at the same moment (two
  connections to a share after a Wi-Fi change) could corrupt it. The app takes the same lock for its own connects.

Everything else is the upstream package. Remove this copy and the `dependency_overrides` entry of `mobile/pubspec.yaml` once
upstream accepts equivalent changes.
