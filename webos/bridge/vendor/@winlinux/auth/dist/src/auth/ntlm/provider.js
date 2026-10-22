import { hostname } from 'node:os';
import { NegState, OID_NTLMSSP, encodeMechTypeList, frameNegTokenInit, frameNegTokenResp, unframeSpnego, } from '../spnego.js';
import { F_KEY_EXCH, F_SEAL, F_SIGN, TYPE1_FLAGS, buildType1, buildType3, negotiateResponseFlags, parseType2, } from './messages.js';
import { NtlmSealSession } from './seal.js';
import { channelBindingsHash } from '../channel-bindings.js';
function defaultWorkstation() {
    const short = hostname().split('.')[0] || 'CLIENT';
    return short.toUpperCase().slice(0, 15);
}
export class NtlmSecurityContext {
    target;
    credentials;
    options;
    state = 'start';
    type1Raw = null;
    session = null;
    key = null;
    sealNegotiated = false;
    disposed = false;
    micOptions = null;
    finalTokenSeen = false;
    constructor(target, credentials, options = {}) {
        this.target = target;
        this.credentials = credentials;
        this.options = options;
    }
    get spnegoSealState() {
        return this.options.mechListMICSealState === 'spnego';
    }
    get complete() {
        return this.state === 'complete';
    }
    negotiatedMechanism = 'ntlm';
    // A copy: dispose() zeroes the internal key, and consumers such as SMB2
    // signing keep using the key after the context is disposed.
    get sessionKey() {
        return this.key ? Buffer.from(this.key) : undefined;
    }
    async step(inputToken) {
        if (this.disposed)
            throw new Error('NTLM context is disposed');
        if (this.state === 'start') {
            if (inputToken !== undefined)
                throw new Error('NTLM: first step takes no input token');
            const { username, password, domain } = this.credentials;
            if (!username)
                throw new Error('NTLM needs a username');
            if (this.credentials.keytab !== undefined)
                throw new Error('NTLM cannot use a keytab; a keytab works with Kerberos only');
            if (password === undefined)
                throw new Error('NTLM needs a password');
            this.type1Raw = buildType1({ domain: domain ?? '', workstation: defaultWorkstation() });
            this.state = 'sent-type1';
            return {
                output: frameNegTokenInit([OID_NTLMSSP], this.type1Raw),
                complete: false,
            };
        }
        if (this.state === 'complete') {
            if (this.finalTokenSeen || !inputToken || inputToken.length === 0) {
                throw new Error('NTLM: handshake is already complete');
            }
            return this.acceptFinalToken(inputToken);
        }
        if (!inputToken || inputToken.length === 0)
            throw new Error('NTLM: missing server challenge');
        const framed = unframeSpnego(inputToken);
        let type2Raw;
        if (framed.kind === 'resp') {
            if (!framed.responseToken)
                throw new Error('NTLM: server response holds no token');
            type2Raw = framed.responseToken;
        }
        else if (framed.kind === 'raw') {
            type2Raw = framed.token; // tolerate stacks that send raw NTLM
        }
        else {
            throw new Error('NTLM: expected a challenge, got NegTokenInit');
        }
        const challenge = parseType2(type2Raw);
        const responseFlags = negotiateResponseFlags(TYPE1_FLAGS, challenge.flags);
        const spn = this.target.spn ?? `${this.target.service}/${this.target.host}`;
        // Read now, not at construction: a consumer may set the binding on the
        // target once its TLS connection is up (channel-bindings.ts).
        const binding = this.target.channelBindings;
        const built = await buildType3({
            username: this.credentials.username,
            password: this.credentials.password ?? '',
            domain: this.credentials.domain ?? '',
            workstation: defaultWorkstation(),
            challenge,
            responseFlags,
            targetName: spn,
            negotiateMessage: this.type1Raw ?? undefined,
            channelBindings: binding ? channelBindingsHash(binding) : undefined,
        });
        // eslint-disable-next-line no-bitwise
        this.sealNegotiated = (responseFlags & F_SEAL) !== 0;
        const sealOptions = {
            exportedSessionKey: built.exportedSessionKey,
            negotiatedFlags: responseFlags,
            // eslint-disable-next-line no-bitwise
            keyExchange: (responseFlags & F_KEY_EXCH) !== 0 && (responseFlags & (F_SIGN | F_SEAL)) !== 0,
        };
        this.session = new NtlmSealSession(sealOptions);
        // SPNEGO mechListMIC (RFC 4178 5, MS-SPNG 3.1.5.1): sent with type3 when
        // type3 carries a MIC, whatever the SIGN flag, and when NTLM gives
        // integrity. AD DCs (Samba, Windows) demand it once type3 has a MIC.
        // The seal state that follows it depends on mechListMICSealState.
        // eslint-disable-next-line no-bitwise
        const wantMic = built.micIncluded || (responseFlags & F_SIGN) !== 0;
        let mechListMIC;
        if (wantMic && this.spnegoSealState) {
            mechListMIC = this.session.sign(encodeMechTypeList([OID_NTLMSSP]));
            this.session.resetRc4('client');
        }
        else if (wantMic) {
            mechListMIC = new NtlmSealSession(sealOptions).sign(encodeMechTypeList([OID_NTLMSSP]));
        }
        this.key = built.exportedSessionKey;
        this.micOptions = sealOptions;
        this.state = 'complete';
        return {
            output: frameNegTokenResp({ responseToken: built.message, mechListMIC }),
            complete: true,
        };
    }
    // One final NegTokenResp from the server after type3: accept-completed
    // and an optional mechListMIC (MS-SPNG 3.1.5.1). The MIC is at server
    // seq 0 and must verify ('spnego': on the session itself, which then
    // resets its server RC4 state; 'separate': on a fresh state).
    acceptFinalToken(inputToken) {
        const framed = unframeSpnego(inputToken);
        if (framed.kind !== 'resp' || (framed.responseToken && framed.responseToken.length > 0)) {
            throw new Error('NTLM: handshake is already complete');
        }
        if (framed.negState !== undefined && framed.negState !== NegState.acceptCompleted) {
            throw new Error(`NTLM: final SPNEGO negState is ${framed.negState}, not accept-completed`);
        }
        const mic = framed.mechListMIC;
        if (mic && mic.length > 0) {
            let ok;
            if (this.spnegoSealState && this.session) {
                ok = this.session.verify(encodeMechTypeList([OID_NTLMSSP]), mic);
                this.session.resetRc4('server');
            }
            else {
                ok = this.micOptions !== null &&
                    new NtlmSealSession(this.micOptions).verify(encodeMechTypeList([OID_NTLMSSP]), mic);
            }
            if (!ok)
                throw new Error('NTLM: the server mechListMIC does not verify');
        }
        this.finalTokenSeen = true;
        return { output: null, complete: true };
    }
    async wrap(plaintext) {
        if (this.disposed)
            throw new Error('NTLM context is disposed');
        if (!this.session)
            throw new Error('NTLM wrap: context is not established');
        if (!this.sealNegotiated)
            throw new Error('NTLM wrap: the server did not negotiate SEAL');
        return this.session.seal(plaintext);
    }
    async unwrap(ciphertext) {
        if (this.disposed)
            throw new Error('NTLM context is disposed');
        if (!this.session)
            throw new Error('NTLM unwrap: context is not established');
        if (!this.sealNegotiated)
            throw new Error('NTLM unwrap: the server did not negotiate SEAL');
        return this.session.unseal(ciphertext);
    }
    async dispose() {
        this.disposed = true;
        this.key?.fill(0);
        this.key = null;
        this.session = null;
        this.micOptions = null;
    }
}
export class NtlmAuthProvider {
    mechanism = 'ntlm';
    createContext(target, credentials) {
        return new NtlmSecurityContext(target, credentials);
    }
}
//# sourceMappingURL=provider.js.map