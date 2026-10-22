import { OID_KRB5, OID_NTLMSSP, unframeSpnego } from './spnego.js';
import { KerberosSecurityContext } from './kerberos.js';
import { NtlmSecurityContext } from './ntlm/provider.js';
// Kerberos failures that mean "wrong or unusable credentials": the KDC
// already counted a bad password (or the account is locked). Falling back to
// NTLM with the same password would count a second failure against the
// account-lockout threshold, so these fail the handshake instead.
const CREDENTIAL_FAILURE = /preauthentication failed|password incorrect|PREAUTH_FAILED|credentials have been revoked|CLIENT_REVOKED|account locked|locked out|password has expired|KEY_EXPIRED/i;
export class KerberosCredentialError extends Error {
    name = 'KerberosCredentialError';
    code = 'KRB_CREDENTIALS';
    constructor(cause) {
        super(`Kerberos rejected the credentials (no NTLM fallback, to avoid a second bad-password count): ${cause.message}`, { cause });
    }
}
// The Kerberos leg offers the IETF Kerberos OID only. Windows may name it
// with the Microsoft Kerberos OID in supportedMech; both are Kerberos.
const OID_MS_KRB5 = '1.2.840.48018.1.2.2';
const KERBEROS_OIDS = new Set([OID_KRB5, OID_MS_KRB5]);
function credentialFailure(err) {
    if (err instanceof KerberosCredentialError)
        return err;
    if (err instanceof Error && CREDENTIAL_FAILURE.test(err.message))
        return new KerberosCredentialError(err);
    return null;
}
export class NegotiateSecurityContext {
    target;
    credentials;
    kerberosDeps;
    inner = null;
    won = null;
    constructor(target, credentials, kerberosDeps) {
        this.target = target;
        this.credentials = credentials;
        this.kerberosDeps = kerberosDeps;
    }
    get complete() {
        return this.inner?.complete ?? false;
    }
    get negotiatedMechanism() {
        return this.won ?? undefined;
    }
    get sessionKey() {
        return this.inner?.sessionKey;
    }
    // The Kerberos leg's channel binding state; NTLM binds through
    // its own AV pair and reports nothing here.
    get channelBound() {
        return this.inner?.channelBound === true;
    }
    // The WinRM extension of the mechanism that won (Kerberos offers it with
    // the addon; NTLM never does, WinRM uses its wrap() instead).
    get wrapWinRM() {
        return this.inner?.wrapWinRM;
    }
    get unwrapWinRM() {
        return this.inner?.unwrapWinRM;
    }
    startKerberos() {
        const ctx = new KerberosSecurityContext(this.target, this.credentials, this.kerberosDeps);
        this.inner = ctx;
        return ctx;
    }
    // A keytab has no password, and neither has the ticket cache on
    // its own, so NTLM cannot run: the Kerberos failure is final, and the
    // caller sees it rather than "NTLM needs a password". With a password,
    // NTLM takes over; that includes a missing `kerberos` package, which is
    // an optional dependency.
    fallBackToNtlm(kerberosError) {
        if (this.credentials.keytab !== undefined || this.credentials.password === undefined) {
            if (kerberosError instanceof Error)
                throw kerberosError;
            throw new Error(this.credentials.keytab !== undefined ? 'a keytab works with Kerberos only' : 'Negotiate needs a password for NTLM');
        }
        const prev = this.inner;
        const ctx = new NtlmSecurityContext(this.target, this.credentials);
        this.inner = ctx;
        this.won = 'ntlm';
        void prev?.dispose?.().catch(() => undefined);
        return ctx;
    }
    async step(inputToken) {
        if (!this.inner) {
            const kerberos = this.startKerberos();
            try {
                const res = await kerberos.step(inputToken);
                this.won = 'kerberos';
                return res;
            }
            catch (err) {
                // A client-side failure before any Kerberos token went out (no
                // realm, no ticket, no KDC, unknown SPN): NTLM takes over, unless
                // the KDC rejected the password (lockout guard).
                const denied = credentialFailure(err);
                if (denied)
                    throw denied;
                return await this.fallBackToNtlm(err).step();
            }
        }
        if (this.won !== 'kerberos')
            return await this.inner.step(inputToken);
        // The Kerberos token has gone to the server, which must not be able to
        // move the exchange to the weaker NTLM. A supportedMech the
        // client did not offer is refused (RFC 4178 4.2.2); a reject, a
        // malformed token or a failed AP-REP or mechListMIC is fatal.
        if (inputToken && inputToken.length > 0) {
            let supportedMech;
            try {
                const framed = unframeSpnego(inputToken);
                if (framed.kind === 'resp')
                    supportedMech = framed.supportedMech;
            }
            catch {
                // Not a SPNEGO token; the Kerberos context reports the error.
            }
            if (supportedMech !== undefined && !KERBEROS_OIDS.has(supportedMech)) {
                const name = supportedMech === OID_NTLMSSP ? 'NTLM' : supportedMech;
                throw new Error(`Negotiate: the server picked ${name}, which was not offered (only Kerberos was); no fallback after the Kerberos token`);
            }
        }
        try {
            return await this.inner.step(inputToken);
        }
        catch (err) {
            throw credentialFailure(err) ?? err;
        }
    }
    async wrap(plaintext) {
        if (!this.inner?.wrap)
            throw new Error('Negotiate wrap: context is not established');
        return this.inner.wrap(plaintext);
    }
    async unwrap(ciphertext) {
        if (!this.inner?.unwrap)
            throw new Error('Negotiate unwrap: context is not established');
        return this.inner.unwrap(ciphertext);
    }
    async dispose() {
        await this.inner?.dispose?.();
    }
}
export class NegotiateAuthProvider {
    kerberosDeps;
    mechanism = 'negotiate';
    constructor(kerberosDeps = {}) {
        this.kerberosDeps = kerberosDeps;
    }
    createContext(target, credentials) {
        return new NegotiateSecurityContext(target, credentials, this.kerberosDeps);
    }
}
//# sourceMappingURL=negotiate.js.map