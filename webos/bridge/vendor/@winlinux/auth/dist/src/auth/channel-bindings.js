// Channel bindings (RFC 5056) for the handshake, additive to the LOCKED
// contract (docs/contracts/auth-provider.md v1.1, mirrored in ./types.ts,
// which is not changed): an AuthTarget MAY carry `channelBindings`, the
// application data of a GSS channel-binding structure, for example the
// RFC 5929 tls-server-end-point binding "tls-server-end-point:" + the hash
// of the server certificate. A consumer that only learns the binding once
// its connection exists (WinRM over TLS) sets it on the target object it
// gave createContext() before it feeds the first server challenge; a
// provider that binds the channel reads it when it builds the token that
// carries it. NTLM puts MD5(gss_channel_bindings_struct) in the
// MsvAvChannelBindings AV pair (MS-NLMP 3.1.5.1.2) and, like pyspnego,
// omits the pair when there is no binding: an all-zero pair is refused by
// Windows over TLS with the default CbtHardeningLevel=Relaxed.
//
// Proposed for a contract v1.x follow-up: "AuthTarget MAY
// carry channelBindings?: Buffer (RFC 5056 application data). A consumer
// MAY set it on the target it passed to createContext() before the first
// server challenge is fed back."
import { md5 } from './ntlm/crypto.js';
// GSS_C_AF_UNSPEC: no initiator or acceptor address.
export const GSS_C_AF_UNSPEC = 0;
function uint32(n) {
    const b = Buffer.alloc(4);
    b.writeUInt32LE(n, 0);
    return b;
}
// The gss_channel_bindings_struct (RFC 2744 3.11) as Windows and pyspnego
// hash it: initiator_addrtype, initiator_address, acceptor_addrtype,
// acceptor_address, application_data, each address type a 32-bit
// little-endian integer and each buffer a 32-bit little-endian length
// followed by its bytes. Addresses default to unspecified and empty.
export function packGssChannelBindings(cb) {
    const empty = Buffer.alloc(0);
    return Buffer.concat([
        uint32(cb.initiatorAddrtype ?? GSS_C_AF_UNSPEC),
        uint32((cb.initiatorAddress ?? empty).length),
        cb.initiatorAddress ?? empty,
        uint32(cb.acceptorAddrtype ?? GSS_C_AF_UNSPEC),
        uint32((cb.acceptorAddress ?? empty).length),
        cb.acceptorAddress ?? empty,
        uint32(cb.applicationData.length),
        cb.applicationData,
    ]);
}
// MsvAvChannelBindings value (MS-NLMP 3.1.5.1.2): MD5 of the structure.
export function channelBindingsHash(applicationData) {
    return md5(packGssChannelBindings({ applicationData }));
}
//# sourceMappingURL=channel-bindings.js.map