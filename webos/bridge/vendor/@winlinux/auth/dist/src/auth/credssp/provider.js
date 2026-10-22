// CredSSP (MS-CSSP) client for WinRM: the "double hop". The server gets the
// user's password, encrypted, so it can sign in to a third machine as the
// user. That is the risk too: a server that is compromised or impersonated
// gets a reusable password. Consumers make it strict opt-in.
//
// Flow (MS-CSSP 3.1.5), each client message one step() output:
//   1. TLS handshake inside the token stream (tls.ts).
//   2. TSRequest { version 6, negoTokens: SPNEGO token } inside that TLS,
//      until the inner mechanism completes: NTLM, or Kerberos when a realm
//      is set (the existing providers, SPNEGO framed).
//   3. With the last token: pubKeyAuth = wrap(SHA-256(client magic, nonce,
//      SubjectPublicKey)) and the 32-byte clientNonce.
//   4. The server's pubKeyAuth must unwrap to SHA-256(server magic, nonce,
//      SubjectPublicKey): the server that ran the inner authentication also
//      owns the inner TLS key. Nothing secret is sent before this check.
//   5. TSRequest { authInfo: wrap(TSCredentials) }: step() is complete.
// After that, wrap()/unwrap() encrypt WinRM messages with the inner TLS
// session (MS-WSMV 2.2.9.1, application/HTTP-CredSSP-session-encrypted).
// The context has no sessionKey.
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { KerberosSecurityContext } from '../kerberos.js';
import { NtlmSecurityContext } from '../ntlm/provider.js';
import { certificateSubjectPublicKey, tlvLength } from './der.js';
import { MemoryTlsClient } from './tls.js';
import { CREDSSP_VERSION, NONCE_LENGTH, checkServerVersion, decodeTSRequest, encodeTSCredentials, encodeTSRequest, formatErrorCode, pubKeyAuthHash, } from './tsrequest.js';
// Usage errors a caller can check before any network: CredSSP sends a
// password, so it needs one, and it never takes a keytab or a ticket cache.
export function credsspCredentialsError(creds) {
    if (!creds.username)
        return new Error('CredSSP needs a username');
    if (creds.keytab !== undefined)
        return new Error('CredSSP cannot use a keytab: it delegates a password to the server');
    if (creds.useTicketCache)
        return new Error('CredSSP cannot use the Kerberos ticket cache: it delegates a password to the server');
    if (typeof creds.password !== 'string' || creds.password.length === 0) {
        return new Error('CredSSP needs a password: it delegates the password to the server');
    }
    return undefined;
}
// The inner NTLM runs inside SPNEGO with its mechListMIC on the wire, so
// its seal state after the MIC must be the MS-SPNG 3.3.5.1 one: the
// client pubKeyAuth is the second signed message (seq 1) with the RC4
// state reset, and so is the server's. Windows drops CredSSP when
// the client pubKeyAuth does not verify.
function defaultInner(deps) {
    return (target, credentials) => typeof credentials.realm === 'string' && credentials.realm.length > 0
        ? new KerberosSecurityContext(target, credentials, deps.kerberos ?? {})
        : new NtlmSecurityContext(target, credentials, { mechListMICSealState: 'spnego' });
}
export class CredSSPSecurityContext {
    target;
    credentials;
    deps;
    state = 'start';
    tls = null;
    inner = null;
    nonce = null;
    serverKey = null;
    disposed = false;
    negotiatedMechanism = 'credssp';
    constructor(target, credentials, deps = {}) {
        this.target = target;
        this.credentials = credentials;
        this.deps = deps;
    }
    get complete() {
        return this.state === 'complete';
    }
    get credsspTrailerLength() {
        if (this.state !== 'complete' || !this.tls)
            return undefined;
        const tls = this.tls;
        return () => tls.trailerLength();
    }
    live() {
        if (this.disposed)
            throw new Error('CredSSP context is disposed');
        if (!this.tls)
            throw new Error('CredSSP: context is not started');
        return this.tls;
    }
    async send(req) {
        return this.live().write(encodeTSRequest(req));
    }
    // One server TSRequest from the TLS records in a server token.
    async receive(token) {
        if (!token || token.length === 0)
            throw new Error('CredSSP: missing server token');
        const plain = await this.live().read(token);
        const len = tlvLength(plain);
        if (len === null || len !== plain.length)
            throw new Error('CredSSP: the server token does not hold one whole TSRequest');
        const ts = decodeTSRequest(plain);
        // An errorCode is the server's verdict; report it before the version.
        if (ts.errorCode !== undefined && ts.errorCode !== 0) {
            throw new Error(`CredSSP: the server refused the sign-in (error ${formatErrorCode(ts.errorCode)})`);
        }
        checkServerVersion(ts.version);
        if (ts.authInfo !== undefined)
            throw new Error('CredSSP: the server sent authInfo');
        if (ts.clientNonce !== undefined && this.nonce && !timingSafeEqual(ts.clientNonce, this.nonce)) {
            throw new Error('CredSSP: the server echoed a different clientNonce');
        }
        return ts;
    }
    // The client half of pubKeyAuth, sent with the inner mechanism's last token.
    async clientPubKeyAuth() {
        const inner = this.inner;
        if (!inner.wrap)
            throw new Error('CredSSP: the inner mechanism offers no wrap()');
        const nonce = this.nonce;
        const pubKeyAuth = await inner.wrap(pubKeyAuthHash('client-to-server', nonce, this.serverKey));
        return { pubKeyAuth, clientNonce: nonce };
    }
    async afterTls() {
        const tls = this.live();
        try {
            this.serverKey = certificateSubjectPublicKey(tls.peerCertificate());
        }
        catch (err) {
            throw new Error(`CredSSP: cannot read the inner TLS certificate: ${err.message}`);
        }
        const nonce = (this.deps.nonce ?? (() => randomBytes(NONCE_LENGTH)))();
        if (nonce.length !== NONCE_LENGTH)
            throw new Error(`CredSSP: the client nonce must be ${NONCE_LENGTH} bytes`);
        this.nonce = Buffer.from(nonce);
        // The inner target has no channel bindings: the outer HTTP channel is
        // not what the inner mechanism protects; pubKeyAuth binds the TLS key.
        const innerTarget = { host: this.target.host, service: this.target.service, ...(this.target.spn ? { spn: this.target.spn } : {}) };
        this.inner = (this.deps.inner ?? defaultInner(this.deps))(innerTarget, this.credentials);
        const first = await this.inner.step();
        if (!first.output)
            throw new Error('CredSSP: the inner mechanism returned no initial token');
        const req = { version: CREDSSP_VERSION, negoTokens: [first.output] };
        if (this.inner.complete) {
            Object.assign(req, await this.clientPubKeyAuth());
            this.state = 'pubkey';
        }
        else {
            this.state = 'nego';
        }
        return this.send(req);
    }
    async negotiate(token) {
        const ts = await this.receive(token);
        if (ts.pubKeyAuth !== undefined)
            throw new Error('CredSSP: the server sent pubKeyAuth before the inner authentication finished');
        const serverToken = ts.negoTokens?.[0];
        if (!serverToken)
            throw new Error('CredSSP: the server sent no negoToken');
        const inner = this.inner;
        const res = await inner.step(serverToken);
        const req = { version: CREDSSP_VERSION };
        if (res.output && res.output.length > 0)
            req.negoTokens = [res.output];
        if (inner.complete) {
            Object.assign(req, await this.clientPubKeyAuth());
            this.state = 'pubkey';
        }
        else if (!req.negoTokens) {
            throw new Error('CredSSP: the inner mechanism returned no token for the server challenge');
        }
        return this.send(req);
    }
    async verifyServer(token) {
        const ts = await this.receive(token);
        const inner = this.inner;
        // A final SPNEGO token (accept-completed, mechListMIC) may come with
        // the server's pubKeyAuth; the inner context checks it.
        const final = ts.negoTokens?.[0];
        if (final) {
            const res = await inner.step(final);
            if (res.output && res.output.length > 0)
                throw new Error('CredSSP: the inner mechanism wants another round after it completed');
        }
        if (!ts.pubKeyAuth)
            throw new Error('CredSSP: the server sent no pubKeyAuth');
        if (!inner.unwrap)
            throw new Error('CredSSP: the inner mechanism offers no unwrap()');
        let got;
        try {
            got = await inner.unwrap(ts.pubKeyAuth);
        }
        catch (err) {
            throw new Error(`CredSSP: cannot unwrap the server pubKeyAuth: ${err.message}`);
        }
        const expected = pubKeyAuthHash('server-to-client', this.nonce, this.serverKey);
        if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
            throw new Error('CredSSP: the server pubKeyAuth does not match the inner TLS key; ' +
                'the server that signed in is not the one that holds this TLS session. No credentials were sent');
        }
        if (!inner.wrap)
            throw new Error('CredSSP: the inner mechanism offers no wrap()');
        // A UPN (user@domain) carries its domain; Windows wants the domain
        // field empty then. Otherwise the NetBIOS domain, else the realm.
        const upn = this.credentials.username.includes('@');
        const creds = encodeTSCredentials({
            domain: upn ? '' : (this.credentials.domain ?? this.credentials.realm ?? ''),
            username: this.credentials.username,
            password: this.credentials.password ?? '',
        });
        let authInfo;
        try {
            authInfo = await inner.wrap(creds);
        }
        finally {
            creds.fill(0);
        }
        const out = await this.send({ version: CREDSSP_VERSION, authInfo });
        this.state = 'complete';
        return out;
    }
    async step(inputToken) {
        if (this.disposed)
            throw new Error('CredSSP context is disposed');
        switch (this.state) {
            case 'start': {
                if (inputToken !== undefined)
                    throw new Error('CredSSP: first step takes no input token');
                const refused = credsspCredentialsError(this.credentials);
                if (refused)
                    throw refused;
                this.tls = new MemoryTlsClient();
                this.state = 'tls';
                return { output: await this.tls.start(), complete: false };
            }
            case 'tls': {
                if (!inputToken || inputToken.length === 0)
                    throw new Error('CredSSP: missing server TLS token');
                const tls = this.live();
                const flight = await tls.handshake(inputToken);
                if (!tls.established) {
                    if (flight.length === 0)
                        throw new Error('CredSSP: the inner TLS handshake stalled');
                    return { output: flight, complete: false };
                }
                const first = await this.afterTls();
                return { output: Buffer.concat([flight, first]), complete: false };
            }
            case 'nego':
                return { output: await this.negotiate(inputToken), complete: false };
            case 'pubkey':
                return { output: await this.verifyServer(inputToken), complete: true };
            case 'complete':
                throw new Error('CredSSP: handshake is already complete');
        }
    }
    async wrap(plaintext) {
        if (this.state !== 'complete')
            throw new Error('CredSSP wrap: context is not established');
        return this.live().write(plaintext);
    }
    async unwrap(ciphertext) {
        if (this.state !== 'complete')
            throw new Error('CredSSP unwrap: context is not established');
        return this.live().read(ciphertext);
    }
    async dispose() {
        this.disposed = true;
        this.tls?.close();
        this.tls = null;
        this.nonce?.fill(0);
        this.nonce = null;
        const inner = this.inner;
        this.inner = null;
        await inner?.dispose?.();
    }
}
export class CredSSPAuthProvider {
    deps;
    mechanism = 'credssp';
    constructor(deps = {}) {
        this.deps = deps;
    }
    createContext(target, credentials) {
        return new CredSSPSecurityContext(target, credentials, this.deps);
    }
}
//# sourceMappingURL=provider.js.map