# @winlinux/smb2

An SMB 2 and 3 file-share client for Node.js. It is a fork of `node-smb2`
(MIT, see `LICENSE.node-smb2.md`) with pluggable authentication, packet
signing, SMB 3.x encryption and share listing.

Most users want the [`winlinux`](https://www.npmjs.com/package/winlinux)
package, which adds WinRM, a CLI and one credential set for both.

```bash
npm install @winlinux/smb2 @winlinux/auth
```

```js
import { connect } from '@winlinux/smb2';
import { createAuthProvider } from '@winlinux/auth';

const smb = await connect({
  host: 'server.corp.example',
  authProvider: createAuthProvider('ntlm'),
  credentials: { username: 'alice', password: process.env.WINLINUX_PASSWORD, domain: 'CORP' },
});
try {
  console.log(await smb.listShares());
  console.log(await smb.list('C$', 'Windows/Temp'));
  await smb.download('C$', 'Windows/Temp/report.csv', './report.csv');
  const tail = await smb.readRange('C$', 'inetpub/logs/LogFiles/W3SVC1/u_ex261011.log', 400 * 1024 * 1024, 1024 * 1024);
  const signal = AbortSignal.timeout(5000); // or an AbortController's signal
  for await (const entry of smb.listIter('C$', 'Windows/System32', { signal })) {
    if (entry.name.endsWith('.dll')) break;  // stops the listing and closes the handle
  }
} finally {
  await smb.close();
}
```

- Dialects: SMB 3.1.1, 3.0.2, 3.0, 2.1 and 2.0.2. `maxDialect: '2.1'` limits
  a connection to SMB 2.x.
- Signing: HMAC-SHA256, AES-CMAC and AES-GMAC. Encryption: AES-128-GCM and
  AES-128-CCM, when the server or a share requires it.
- Kerberos signing needs the session key from the optional
  `@winlinux/krb-session-key` addon.
- `AbortSignal`, and connect and request timeouts. `list`, `listIter`,
  `stat`, `readFile` and `download` take `{ signal }` as their last
  argument. On abort the call sends no further request, the request in
  flight rejects at once, the file or directory handle closes, and the call
  rejects with `SmbAbortError`, whose `name` is `'AbortError'`; the session
  stays usable. A signal that is already aborted rejects before any request
  goes out.
- A `download` that fails or is aborted removes the partial file at its
  local path before it rejects, so no truncated file stays behind.
- `listIter(share, dir)` yields entries as each `QUERY_DIRECTORY` response
  arrives, so a caller with a time budget can stop early: `break` closes
  the directory handle.
- `readRange(share, path, offset, length)` returns the bytes
  `[offset, offset + length)` of a file of any size, for example the tail
  of a large log: the file opens read-only with share access read, write
  and delete, so a file another process holds open for append reads too.
  Fewer bytes come back at end of file, an empty `Buffer` past it; `length`
  above `MAX_BUFFERED_FILE_BYTES` (64 MiB) is refused.
- No runtime dependencies. The package has no NTLM code of its own: an
  `AuthProvider` (from `@winlinux/auth` or your own) does the sign-in.

ESM only, Node.js 22 or later. MIT license.
