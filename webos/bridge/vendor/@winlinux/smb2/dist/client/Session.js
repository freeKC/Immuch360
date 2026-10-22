import Tree from "./Tree.js";
import { EventEmitter } from "events";
import Dialect from "../protocol/smb2/Dialect.js";
import StatusCode from "../protocol/smb2/StatusCode.js";
import { generateGuid } from "../protocol/util.js";
import PacketType from "../protocol/smb2/PacketType.js";
import { SmbAccessDeniedError, SmbAuthError, SmbDialectError, SmbEncryptionRequiredError, SmbSigningError, throwForStatus, toSmbError, } from "../errors.js";
import { smbSessionKey } from "../signing.js";
import { Cipher, DIALECT_202, DIALECT_210, DIALECT_300, DIALECT_302, DIALECT_311, HASH_SHA512, PREAUTH_INITIAL, SMB2_GLOBAL_CAP_ENCRYPTION, SMB2_SESSION_FLAG_ENCRYPT_DATA, SMB2_SESSION_FLAG_IS_GUEST, SMB2_SESSION_FLAG_IS_NULL, SigningAlgorithm, appendNegotiateContexts, deriveKeys, dialectName, parseNegotiateContexts, preauthUpdate, verifySignature3, } from "../smb3.js";
import crypto from "node:crypto";
// MS-SMB2 2.2.4 NEGOTIATE Response SecurityMode flags.
export const SMB2_SIGNING_ENABLED = 0x01;
export const SMB2_SIGNING_REQUIRED = 0x02;
// MS-SMB2 2.2.31: FSCTL_VALIDATE_NEGOTIATE_INFO and SMB2_0_IOCTL_IS_FSCTL.
const FSCTL_VALIDATE_NEGOTIATE_INFO = 0x00140204;
const SMB2_0_IOCTL_IS_FSCTL = 0x00000001;
// What servers older than the IOCTL (SMB 2.x only) answer it with. The
// answer is signed, so it cannot be forged on the wire.
const VALIDATION_UNKNOWN = new Set([
    0xc00000bb, // STATUS_NOT_SUPPORTED
    0xc0000010, // STATUS_INVALID_DEVICE_REQUEST
    0xc0000128, // STATUS_FILE_CLOSED
]);
class Session extends EventEmitter {
    client;
    _id;
    authenticated = false;
    security = { dialect: "", signingAlgorithm: "HMAC-SHA256", cipher: "none", encryptData: false, signing: false };
    connectedTrees = [];
    constructor(client) {
        super();
        this.client = client;
    }
    async connectTree(path) {
        const tree = new Tree(this);
        this.registerTree(tree);
        await tree.connect(path);
        return tree;
    }
    createRequest(header = {}, body = {}) {
        return this.client.createRequest({
            sessionId: this._id,
            ...header
        }, body);
    }
    async request(header = {}, body = {}, options) {
        return await this.client.request({
            sessionId: this._id,
            ...header
        }, body, options);
    }
    // Generic SESSION_SETUP loop driven by the AuthProvider contract: the
    // first token goes out, each STATUS_MORE_PROCESSING_REQUIRED response blob
    // feeds back into ctx.step(), and the loop repeats on this same
    // connection until STATUS_SUCCESS. A non-empty STATUS_SUCCESS blob also
    // goes to ctx.step() while the context is incomplete (Kerberos AP-REP).
    // This module never sees passwords.
    async authenticateWithProvider(options) {
        if (this.authenticated)
            return;
        const signingMode = options.signing ?? "auto";
        const offerSmb3 = (options.maxDialect ?? "3.1.1") !== "2.1";
        const offered = offerSmb3
            ? [DIALECT_202, DIALECT_210, DIALECT_300, DIALECT_302, DIALECT_311]
            : [Dialect.Smb202, Dialect.Smb210];
        // 3.1.1 negotiate contexts: SHA-512 preauth integrity, AES-128-GCM then
        // AES-128-CCM, AES-GMAC then AES-CMAC (MS-SMB2 2.2.3.1).
        const salt = crypto.randomBytes(32);
        const negotiateResponse = await this.request({
            type: PacketType.Negotiate
        }, {
            dialects: offered,
            // SIGNING_REQUIRED too in "required" mode: the server learns
            // the client's policy, and VALIDATE_NEGOTIATE_INFO checks it.
            securityMode: signingMode === "required" ? SMB2_SIGNING_ENABLED | SMB2_SIGNING_REQUIRED : SMB2_SIGNING_ENABLED,
            clientGuid: generateGuid(),
            ...(offerSmb3 ? { capabilities: SMB2_GLOBAL_CAP_ENCRYPTION } : {}),
        }, offerSmb3 ? {
            transform: (message) => appendNegotiateContexts(message, {
                salt,
                ciphers: [Cipher.Aes128Gcm, Cipher.Aes128Ccm],
                signing: [SigningAlgorithm.AesGmac, SigningAlgorithm.AesCmac],
            }),
        } : undefined);
        const dialect = negotiateResponse.body.dialectRevision;
        if (!offered.includes(dialect)) {
            throw new SmbDialectError(`server negotiated dialect 0x${dialect.toString(16).padStart(4, "0")}, which was not offered (offered ${offered.map(dialectName).join(", ")})`);
        }
        this.client.dialect = dialect;
        const negotiateSent = negotiateResponse.request?.raw;
        const negotiateReceived = negotiateResponse.raw;
        if (negotiateSent && negotiateReceived)
            this.client.negotiateExchange = { sent: negotiateSent, received: negotiateReceived };
        let cipher = Cipher.None;
        let signingAlgorithm = dialect >= DIALECT_300 ? SigningAlgorithm.AesCmac : SigningAlgorithm.HmacSha256;
        let preauth;
        if (dialect === DIALECT_311) {
            const raw = negotiateResponse.raw;
            const sent = negotiateResponse.request?.raw;
            if (!raw || !sent)
                throw new SmbDialectError("SMB 3.1.1 needs the raw NEGOTIATE exchange for preauth integrity");
            const contexts = parseNegotiateContexts(raw);
            if (contexts.hashAlgorithm !== HASH_SHA512) {
                throw new SmbDialectError(`server picked preauth hash ${contexts.hashAlgorithm ?? "none"}; only SHA-512 is supported`);
            }
            if (contexts.cipher !== Cipher.None && contexts.cipher !== Cipher.Aes128Gcm && contexts.cipher !== Cipher.Aes128Ccm) {
                throw new SmbDialectError(`server picked cipher 0x${contexts.cipher.toString(16)}, which was not offered`);
            }
            cipher = contexts.cipher;
            if (contexts.signing === SigningAlgorithm.AesGmac)
                signingAlgorithm = SigningAlgorithm.AesGmac;
            else if (contexts.signing !== undefined && contexts.signing !== SigningAlgorithm.AesCmac) {
                throw new SmbDialectError(`server picked signing algorithm 0x${contexts.signing.toString(16)}, which was not offered`);
            }
            preauth = preauthUpdate(preauthUpdate(PREAUTH_INITIAL, sent), raw);
        }
        else if ((dialect === DIALECT_300 || dialect === DIALECT_302) && (negotiateResponse.body.capabilities & SMB2_GLOBAL_CAP_ENCRYPTION)) {
            cipher = Cipher.Aes128Ccm;
        }
        this.security = {
            dialect: dialectName(dialect),
            signingAlgorithm: signingAlgorithm === SigningAlgorithm.AesGmac ? "AES-GMAC" : signingAlgorithm === SigningAlgorithm.AesCmac ? "AES-CMAC" : "HMAC-SHA256",
            cipher: cipher === Cipher.Aes128Gcm ? "AES-128-GCM" : cipher === Cipher.Aes128Ccm ? "AES-128-CCM" : "none",
            encryptData: false,
            signing: false,
        };
        const securityMode = negotiateResponse.body.securityMode;
        const serverSigningEnabled = (securityMode & SMB2_SIGNING_ENABLED) !== 0;
        const serverSigningRequired = (securityMode & SMB2_SIGNING_REQUIRED) !== 0;
        if (signingMode === "required" && !serverSigningEnabled && !serverSigningRequired) {
            throw new SmbSigningError("signing mode is 'required' but the server offers no packet signing");
        }
        const ctx = options.authProvider.createContext({ host: this.client.host, service: "cifs" }, options.credentials);
        // 3.1.1: the session's preauth hash starts from the connection's and
        // takes every SESSION_SETUP request and every MORE_PROCESSING response;
        // the final response is not hashed (MS-SMB2 3.2.5.3.1).
        let sessionHash = preauth;
        const setup = async (token) => {
            const response = await this.sessionSetup(token);
            if (sessionHash) {
                const sent = response.request?.raw;
                if (!sent)
                    throw new SmbDialectError("SMB 3.1.1 needs the raw SESSION_SETUP request for preauth integrity");
                sessionHash = preauthUpdate(sessionHash, sent);
                if (response.header.status === StatusCode.MoreProcessingRequired) {
                    sessionHash = preauthUpdate(sessionHash, response.raw);
                }
            }
            return response;
        };
        try {
            let out = await ctx.step();
            let setupResponse = await setup(out.output ?? Buffer.alloc(0));
            this._id = setupResponse.header.sessionId;
            while (setupResponse.header.status === StatusCode.MoreProcessingRequired) {
                out = await ctx.step(setupResponse.body.buffer);
                setupResponse = await setup(out.output ?? Buffer.alloc(0));
            }
            if (setupResponse.header.status !== StatusCode.Success) {
                throwForStatus(setupResponse.header.status, "session setup");
            }
            // Kerberos mutual auth: the AP-REP arrives with STATUS_SUCCESS and
            // only it completes the context. NTLM is complete here already.
            const finalToken = setupResponse.body.buffer;
            if (!ctx.complete && finalToken && finalToken.length > 0) {
                await ctx.step(finalToken);
            }
            if (!ctx.complete) {
                throw new SmbAuthError("server accepted the session but the auth context is not complete");
            }
            // The auth layer hands over the full GSS key; SMB2 owns the
            // 16-byte rule (MS-SMB2 3.2.5.3.1).
            const gssKey = ctx.sessionKey;
            const sessionKey = gssKey && gssKey.length > 0 ? smbSessionKey(gssKey) : undefined;
            // The contract getter returns a copy; smb2 keeps only the derived key.
            gssKey?.fill(0);
            if ((serverSigningRequired || signingMode === "required") && !sessionKey) {
                const mechanism = ctx.negotiatedMechanism ?? options.authProvider.mechanism;
                throw new SmbSigningError(mechanism === "kerberos"
                    ? "packet signing is required but the Kerberos provider supplies no session key; " +
                        "install @winlinux/krb-session-key (it needs a C compiler and the Kerberos headers) " +
                        "so that Kerberos can sign SMB2 packets"
                    : "packet signing is required but the auth provider supplied no session key");
            }
            const sessionFlags = setupResponse.body.sessionFlags ?? 0;
            // A guest or anonymous session proves nothing about the account and
            // cannot sign. Refuse it when real credentials were given (the
            // server fell back to guest) or when signing is required.
            const anonymous = (sessionFlags & (SMB2_SESSION_FLAG_IS_GUEST | SMB2_SESSION_FLAG_IS_NULL)) !== 0;
            if (anonymous) {
                const as = sessionFlags & SMB2_SESSION_FLAG_IS_NULL ? "anonymous" : "guest";
                const { password, keytab, useTicketCache } = options.credentials;
                if (password || keytab || useTicketCache) {
                    throw new SmbAuthError(`the server signed the session in as ${as}, not as the given account`);
                }
                if (serverSigningRequired || signingMode === "required") {
                    throw new SmbSigningError(`signing is required but the server signed the session in as ${as}, which cannot sign`);
                }
            }
            const encryptData = (sessionFlags & SMB2_SESSION_FLAG_ENCRYPT_DATA) !== 0;
            if (encryptData && (!sessionKey || cipher === Cipher.None)) {
                throw new SmbEncryptionRequiredError(`the server requires SMB encryption for this session, but ${sessionKey ? `no cipher was negotiated (dialect ${dialectName(dialect)})` : "the auth provider supplied no session key"}`);
            }
            if (sessionKey && dialect >= DIALECT_300) {
                const keys = deriveKeys(dialect, sessionKey, sessionHash);
                // 3.x servers sign the final SESSION_SETUP response with the new
                // signing key (MS-SMB2 3.3.5.5.3). It is the proof that the server
                // holds the session key, so every 3.x session with a key requires
                // it; only a guest or anonymous session, allowed above, may
                // leave it unsigned. Check it here: the key did not exist when the
                // response arrived.
                const finalRaw = setupResponse.raw;
                if (finalRaw && (setupResponse.header.flags ?? 0) & 0x8) {
                    if (!verifySignature3(finalRaw, signingAlgorithm, keys.signingKey)) {
                        throw new SmbSigningError("the final SESSION_SETUP response signature does not verify");
                    }
                }
                else if (!anonymous) {
                    throw new SmbSigningError(`the server did not sign the final SESSION_SETUP response (required for SMB ${dialectName(dialect)})`);
                }
                this.client.setSmb3Session(this._id, {
                    signingKey: keys.signingKey,
                    signingAlgorithm,
                    cipher,
                    ...(cipher !== Cipher.None ? { encryptionKey: keys.encryptionKey, decryptionKey: keys.decryptionKey } : {}),
                    encryptData,
                });
                this.security = { ...this.security, encryptData };
            }
            else if (sessionKey) {
                this.client.setSessionKey(this._id, sessionKey);
            }
            if ((serverSigningEnabled || serverSigningRequired) && sessionKey) {
                this.client.enableSigning();
                this.security = { ...this.security, signing: true };
            }
        }
        catch (error) {
            // @winlinux/auth: Kerberos rejected the password (no NTLM fallback).
            if (error instanceof Error && error.name === "KerberosCredentialError") {
                throw new SmbAuthError(`session setup: ${error.message}`);
            }
            const typed = toSmbError(error, "session setup");
            // A server with server-wide EncryptData and RejectUnencryptedAccess
            // refuses an unencrypted session (an SMB 2.x dialect, or 3.x without
            // a cipher) with STATUS_ACCESS_DENIED (MS-SMB2 3.3.5.5); the same
            // status also means the account may not log on over the network. No
            // session exists yet, so nothing can probe which.
            if (typed instanceof SmbAccessDeniedError && !(typed instanceof SmbEncryptionRequiredError) && cipher === Cipher.None) {
                throw new SmbAccessDeniedError("access denied: session setup; the account cannot log on to this server, " +
                    `or the server requires SMB encryption for every session and this connection negotiated none (dialect ${dialectName(dialect)})`, typed.status);
            }
            throw typed;
        }
        finally {
            await ctx.dispose?.();
        }
        this.authenticated = true;
        this.emit("authenticate", this);
    }
    // FSCTL_VALIDATE_NEGOTIATE_INFO, once per connection after the
    // first TREE_CONNECT. Below SMB 3.1.1 nothing authenticates the NEGOTIATE,
    // so an on-path attacker could have lowered the dialect or the security
    // mode. The client sends what it offered, in a signed IOCTL, and the
    // server answers with what it chose; the answer must match the NEGOTIATE
    // response, or the connection ends (MS-SMB2 3.3.5.15.12). 3.1.1 is left
    // out: its preauth hash covers the NEGOTIATE, and a 3.1.1 server drops a
    // connection that sends this IOCTL. A session without signing (no session
    // key) cannot authenticate the answer, so it does not send it.
    async validateNegotiate(tree) {
        const client = this.client;
        const exchange = client.negotiateExchange;
        if (!exchange || client.negotiateValidated || client.dialect >= DIALECT_311 || !this.security.signing)
            return;
        client.negotiateValidated = true;
        const { sent, received } = exchange;
        const fail = (ErrorType, message) => {
            client.terminate(message);
            throw new ErrorType(message);
        };
        // The NEGOTIATE request body (MS-SMB2 2.2.3) as sent.
        const count = sent.readUInt16LE(64 + 2);
        const input = Buffer.alloc(24 + 2 * count);
        sent.copy(input, 0, 64 + 8, 64 + 12); // Capabilities
        sent.copy(input, 4, 64 + 12, 64 + 28); // ClientGuid
        sent.copy(input, 20, 64 + 4, 64 + 6); // SecurityMode
        input.writeUInt16LE(count, 22);
        sent.copy(input, 24, 64 + 36, 64 + 36 + 2 * count); // Dialects
        let response;
        try {
            response = await tree.request({ type: PacketType.InputOutputControl }, {
                ctlCode: FSCTL_VALIDATE_NEGOTIATE_INFO,
                maxOutputResponse: 24,
                flags: SMB2_0_IOCTL_IS_FSCTL,
                buffer: input,
            });
        }
        catch (error) {
            if (error instanceof SmbSigningError)
                return fail(SmbSigningError, `FSCTL_VALIDATE_NEGOTIATE_INFO: ${error.message}`);
            const status = error?.header?.status;
            if (typeof status !== "number")
                throw error;
            if (client.dialect < DIALECT_300 && VALIDATION_UNKNOWN.has(status))
                return;
            return fail(SmbDialectError, `the server refused FSCTL_VALIDATE_NEGOTIATE_INFO (status 0x${status.toString(16).padStart(8, "0")})`);
        }
        const status = response.header.status;
        if (status !== StatusCode.Success) {
            if (client.dialect < DIALECT_300 && VALIDATION_UNKNOWN.has(status))
                return;
            return fail(SmbDialectError, `the server refused FSCTL_VALIDATE_NEGOTIATE_INFO (status 0x${status.toString(16).padStart(8, "0")})`);
        }
        // VALIDATE_NEGOTIATE_INFO response (MS-SMB2 2.2.32.6) at OutputOffset.
        const raw = response.raw;
        const offset = response.body.outputOffset;
        const length = response.body.outputCount;
        if (!raw || length < 24 || offset < 64 || offset + 24 > raw.length) {
            return fail(SmbDialectError, "the server's FSCTL_VALIDATE_NEGOTIATE_INFO answer is malformed");
        }
        const answer = raw.subarray(offset, offset + 24);
        const mismatched = [];
        if (answer.readUInt32LE(0) !== received.readUInt32LE(64 + 24))
            mismatched.push("capabilities");
        if (!answer.subarray(4, 20).equals(received.subarray(64 + 8, 64 + 24)))
            mismatched.push("server GUID");
        if (answer.readUInt16LE(20) !== received.readUInt16LE(64 + 2))
            mismatched.push("security mode");
        if (answer.readUInt16LE(22) !== client.dialect)
            mismatched.push("dialect");
        if (mismatched.length > 0) {
            fail(SmbDialectError, `the server's FSCTL_VALIDATE_NEGOTIATE_INFO answer does not match its NEGOTIATE response (${mismatched.join(", ")}); the negotiation was tampered with`);
        }
    }
    async sessionSetup(token) {
        return await this.request({ type: PacketType.SessionSetup }, { buffer: token });
    }
    registerTree(tree) {
        tree
            .once("connect", () => this.connectedTrees.push(tree))
            .once("disconnect", () => this.connectedTrees.splice(this.connectedTrees.indexOf(tree), 1));
    }
    async logoff() {
        if (!this.authenticated)
            return;
        this.authenticated = false;
        await Promise.all(this.connectedTrees.map(x => x.disconnect()));
        await this.request({ type: PacketType.LogOff });
        this.client.clearSessionKey(this._id);
        delete this._id;
        this.emit("logoff", this);
    }
}
export default Session;
//# sourceMappingURL=Session.js.map