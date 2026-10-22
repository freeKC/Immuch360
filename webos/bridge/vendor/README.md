# Vendored packages of the media bridge

| Package | Version | Licence | From |
|---|---|---|---|
| @winlinux/smb2 | 1.1.0 | MIT (`LICENSE`; it is a fork of node-smb2, MIT, `LICENSE.node-smb2.md`) | npm, https://github.com/sanjay3290/winlinux |
| @winlinux/auth | 1.1.0 | MIT (`LICENSE`) | npm, same repository |

Copied as published on npm (12 October 2026), without the TypeScript declarations and the source maps; no file is
changed here. Why vendored and not installed: `@winlinux/auth` declares the `kerberos` native addon as an optional
dependency, which `npm ci` would try to build, and the TV's service may not load native addons anyway; only the NTLM
part is used.

`tools/build-bridge.mjs` bundles them for Node 12 into `service/bridge/smb.js`, with what the TV's Node lacks:
`fs/promises` and `stream/promises` are mapped to `require('fs').promises` and promisified `stream.pipeline` and
`finished` (`bridge/shims/`), and the `createRequire(import.meta.url)` that loads `des.js` in
`@winlinux/auth/dist/src/auth/ntlm/crypto.js` becomes a plain import, so that `des.js` (MIT, a dependency in
`package.json`) goes into the bundle. `kerberos` stays out. The choice and the tests against three Samba setups on Node
12, 16 and 20 are in the feasibility study of 22 October 2026.
