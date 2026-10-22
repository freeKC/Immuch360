// Optional extension of SecurityContext for WinRM message encryption over
// plain HTTP with Kerberos. It is additive: the LOCKED contract
// (docs/contracts/auth-provider.md v1, mirrored in ./types.ts) is not
// changed, and every required member keeps its meaning. A context carries
// these two members only when its GSS layer can split a wrap token the way
// MS-WSMV 2.2.9.1.1.2.2 needs (gss_wrap_iov in @winlinux/krb-session-key).
// With the `kerberos` package fallback they are absent, and WinRM keeps
// refusing Kerberos message encryption with its usual error.
//
// The WinRM transport stays the protocol owner of the framing: it writes
// header.length into the MS-WSMV Length-Field, then header, then data.
// Auth only returns the sealed pieces. NTLM is unaffected: its wrap() is
// already signature || sealed data, and WinRM keeps using wrap()/unwrap()
// for it.
//
// Proposed for a contract v1.x follow-up: "SecurityContext
// MAY expose wrapWinRM / unwrapWinRM; WinRM uses them when present for
// Kerberos."
// True when ctx offers the split (both members present).
export function hasWinRMMessageProtection(ctx) {
    const c = ctx;
    return typeof c.wrapWinRM === 'function' && typeof c.unwrapWinRM === 'function';
}
//# sourceMappingURL=winrm-extension.js.map