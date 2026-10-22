import crypto from "crypto";
import { Socket } from "net";
import { EventEmitter } from "events";
import Packet from "../protocol/Packet.js";
import Request from "../protocol/smb2/Request.js";
import Response from "../protocol/smb2/Response.js";
import { headerSize } from "../protocol/smb2/Header.js";
import Smb2Packet from "../protocol/smb2/Packet.js";
import StatusCode from "../protocol/smb2/StatusCode.js";
import HeaderFlag from "../protocol/smb2/HeaderFlag.js";
import Smb2PacketType from "../protocol/smb2/PacketType.js";
import Session from "./Session.js";
import * as structureUtil from "../protocol/structureUtil.js";
import { SmbAbortError, SmbDialectError, SmbEncryptionRequiredError, SmbError, SmbSigningError } from "../errors.js";
import { signMessage, verifySignature } from "../signing.js";
import { Cipher, NonceSource, SigningAlgorithm, decryptMessage, encryptMessage, isTransformed, signMessage3, transformSessionId, verifySignature3, } from "../smb3.js";
// MS-SMB2 3.3.5.2.9: a request for a session the server no longer has
// fails with STATUS_USER_SESSION_DELETED, which the server cannot sign. It
// only ever fails the request.
const STATUS_USER_SESSION_DELETED = 0xc0000203;
class Client extends EventEmitter {
    host;
    options;
    _id = crypto.randomBytes(4).toString("hex");
    socket;
    nextMessageId = 0n;
    responseRestChunk;
    responseCallbackMap = new Map();
    sentRequests = new Map();
    connected = false;
    port = 445;
    connectTimeout = 5 * 1000;
    connectTimeoutId;
    requestTimeout = 5 * 1000;
    requestTimeoutIdMap = new Map();
    sessions = [];
    // SMB2 packet signing (MS-SMB2 3.2.4.1.1). Keys arrive from the
    // AuthProvider's sessionKey after SESSION_SETUP completes.
    sessionKeys = new Map();
    signingEnabled = false;
    // messageId -> why its response is refused (bad signature, plaintext on
    // an encrypted session, undecryptable, malformed) and the error to raise.
    failedVerifications = new Map();
    // SMB 3.x. `dialect` is set by Session after NEGOTIATE.
    dialect = 0;
    // The NEGOTIATE request and response as sent and received, for
    // FSCTL_VALIDATE_NEGOTIATE_INFO after the first TREE_CONNECT.
    negotiateExchange;
    negotiateValidated = false;
    smb3Sessions = new Map();
    encryptedTrees = new Set(); // `${sessionId}:${treeId}`
    nonces = new NonceSource();
    constructor(host, options = {}) {
        super();
        this.host = host;
        this.options = options;
        if (typeof this.options.port === "number")
            this.port = this.options.port;
        if (typeof this.options.connectTimeout === "number")
            this.connectTimeout = this.options.connectTimeout;
        if (typeof this.options.requestTimeout === "number")
            this.requestTimeout = this.options.requestTimeout;
    }
    async connect() {
        if (this.connected)
            return;
        this.socket = new Socket({ allowHalfOpen: true })
            .addListener("data", this.onData)
            .addListener("error", this.onError)
            .addListener("close", this.onClose);
        this.socket.setTimeout(0);
        this.socket.setKeepAlive(true);
        const connectPromise = new Promise((resolve, reject) => {
            this.connectTimeoutId = setTimeout(() => {
                // code ETIMEDOUT, as a system error has one: callers can read the
                // cause of an SmbConnectionError the same way for a timeout as for
                // ENOTFOUND or ECONNREFUSED. The message stays connect_timeout.
                reject(Object.assign(new Error("connect_timeout"), { code: "ETIMEDOUT" }));
            }, this.connectTimeout);
            this.socket.connect(this.port, this.host);
            this.socket.once("connect", () => {
                resolve();
            });
            this.socket.once("error", (err) => {
                reject(err);
            });
        });
        try {
            await connectPromise;
            clearTimeout(this.connectTimeoutId);
            this.connected = true;
        }
        catch (err) {
            this.destroySocket();
            throw err;
        }
    }
    createRequest(header = {}, body = {}) {
        const messageId = this.nextMessageId++;
        return new Request({
            messageId,
            clientId: this._id,
            ...header
        }, body);
    }
    async request(header, body, options) {
        const request = this.createRequest(header, body);
        return await this.send(request, options);
    }
    setSmb3Session(sessionId, state) {
        this.smb3Sessions.set(sessionId, state);
    }
    // A TREE_CONNECT response carried SMB2_SHAREFLAG_ENCRYPT_DATA: every later
    // request on that tree is encrypted, and plaintext responses are refused.
    markTreeEncrypted(sessionId, treeId) {
        const state = this.smb3Sessions.get(sessionId);
        if (!state?.encryptionKey || state.cipher === Cipher.None) {
            throw new SmbEncryptionRequiredError(`the share requires SMB encryption but this connection negotiated none (dialect 0x${this.dialect.toString(16).padStart(4, "0")})`);
        }
        this.encryptedTrees.add(`${sessionId}:${treeId}`);
    }
    unmarkTree(sessionId, treeId) {
        this.encryptedTrees.delete(`${sessionId}:${treeId}`);
    }
    encrypts(sessionId, treeId) {
        if (typeof sessionId !== "string")
            return undefined;
        const state = this.smb3Sessions.get(sessionId);
        if (!state?.encryptionKey)
            return undefined;
        if (state.encryptData || this.encryptedTrees.has(`${sessionId}:${treeId}`))
            return state;
        return undefined;
    }
    setSessionKey(sessionId, key) {
        this.sessionKeys.set(sessionId, key);
    }
    clearSessionKey(sessionId) {
        this.sessionKeys.delete(sessionId);
        this.smb3Sessions.delete(sessionId);
        for (const key of [...this.encryptedTrees])
            if (key.startsWith(`${sessionId}:`))
                this.encryptedTrees.delete(key);
    }
    enableSigning() {
        this.signingEnabled = true;
    }
    signingFor(request) {
        if (!this.signingEnabled)
            return undefined;
        // NEGOTIATE and SESSION_SETUP predate the session key and always go unsigned.
        if (request.header.type === Smb2PacketType.Negotiate)
            return undefined;
        if (request.header.type === Smb2PacketType.SessionSetup)
            return undefined;
        return this.signingKey(request.header.sessionId);
    }
    signingKey(sessionId) {
        if (typeof sessionId !== "string")
            return undefined;
        const smb3 = this.smb3Sessions.get(sessionId);
        if (smb3)
            return { key: smb3.signingKey, algorithm: smb3.signingAlgorithm };
        const key = this.sessionKeys.get(sessionId);
        return key ? { key, algorithm: SigningAlgorithm.HmacSha256 } : undefined;
    }
    async send(request, options = {}) {
        if (!this.connected)
            throw new Error("not_connected");
        const { signal } = options;
        const name = () => `${structureUtil.parseEnumValue(Smb2PacketType, request.header.type)}(${request.header.messageId})`;
        if (signal?.aborted)
            throw new SmbAbortError(`${name()} was aborted before it was sent`, signal.reason);
        // An encrypted message is not signed: AES-CCM/GCM authenticate it.
        const encryptFor = request.header.type === Smb2PacketType.Negotiate || request.header.type === Smb2PacketType.SessionSetup
            ? undefined
            : this.encrypts(request.header.sessionId, request.header.treeId);
        const signing = encryptFor ? undefined : this.signingFor(request);
        if (signing) {
            request.header.flags = (request.header.flags ?? 0) | HeaderFlag.Signed;
        }
        let message = Smb2Packet.serializeMessage(request.header, request.body);
        if (options.transform)
            message = options.transform(message);
        if (signing) {
            message = signing.algorithm === SigningAlgorithm.HmacSha256
                ? signMessage(message, signing.key)
                : signMessage3(message, signing.algorithm, signing.key);
        }
        // The bytes as sent, before encryption: the 3.1.1 preauth hash covers them.
        request.raw = message;
        const wire = encryptFor
            ? encryptMessage(message, Buffer.from(request.header.sessionId, "hex"), encryptFor.cipher, encryptFor.encryptionKey, this.nonces.next(encryptFor.cipher))
            : message;
        const messageId = request.header.messageId;
        this.sentRequests.set(messageId, {
            type: request.header.type,
            sessionId: typeof request.header.sessionId === "string" ? request.header.sessionId : undefined,
            signed: signing !== undefined,
            encrypted: encryptFor !== undefined,
        });
        this.socket.write(Smb2Packet.prefixMessage(wire));
        let onAbort;
        const sendPromise = new Promise((resolve, reject) => {
            const requestTimeoutId = setTimeout(() => {
                // A late response then has no outstanding request and is discarded.
                this.sentRequests.delete(messageId);
                this.responseCallbackMap.delete(messageId);
                const err = new Error(`request_timeout: ${name()}`);
                reject(err);
            }, this.requestTimeout);
            this.requestTimeoutIdMap.set(messageId, requestTimeoutId);
            if (signal) {
                onAbort = () => {
                    // As for a timeout: a late response is discarded.
                    this.sentRequests.delete(messageId);
                    this.responseCallbackMap.delete(messageId);
                    reject(new SmbAbortError(`${name()} was aborted`, signal.reason));
                };
                signal.addEventListener("abort", onAbort, { once: true });
            }
            const finishRequest = (response) => {
                response.request = request;
                const failure = this.failedVerifications.get(messageId);
                if (failure !== undefined) {
                    this.failedVerifications.delete(messageId);
                    reject(new failure.ErrorType(`${failure.reason}: ${structureUtil.parseEnumValue(Smb2PacketType, request.header.type)}(${messageId})`));
                    return;
                }
                if (response.header.status !== StatusCode.Success &&
                    response.header.status !== StatusCode.Pending &&
                    response.header.status !== StatusCode.MoreProcessingRequired &&
                    response.header.status !== StatusCode.FileClosed) {
                    reject(response);
                }
                else {
                    resolve(response);
                }
            };
            this.responseCallbackMap.set(messageId, finishRequest);
        });
        try {
            return await sendPromise;
        }
        finally {
            // Clear on failure too, or a failed request keeps the process alive.
            clearTimeout(this.requestTimeoutIdMap.get(messageId));
            this.requestTimeoutIdMap.delete(messageId);
            if (onAbort)
                signal?.removeEventListener("abort", onAbort);
        }
    }
    onData = (buffer) => {
        if (this.responseRestChunk) {
            buffer = Buffer.concat([this.responseRestChunk, buffer]);
            this.responseRestChunk = undefined;
        }
        // Nothing may throw out of this socket handler: that would be an
        // uncaught exception and end the process. A frame that does not
        // parse cannot be tied to its request, so it fails every pending
        // request and drops the connection.
        let chunks;
        try {
            const split = Packet.getChunks(buffer);
            chunks = split.chunks;
            this.responseRestChunk = split.restChunk;
        }
        catch (error) {
            this.failMalformed(error);
            return;
        }
        for (const chunk of chunks) {
            let message = chunk;
            let transformSession;
            if (isTransformed(chunk)) {
                const sessionId = transformSessionId(chunk).toString("hex");
                const state = this.smb3Sessions.get(sessionId);
                try {
                    if (!state?.decryptionKey)
                        throw new Error("no decryption key for this session");
                    message = decryptMessage(chunk, state.cipher, state.decryptionKey).message;
                    transformSession = sessionId;
                }
                catch {
                    // The message cannot be tied to a request it may not be from;
                    // fail every pending request and drop the connection.
                    this.failAll("an encrypted SMB response did not decrypt");
                    return;
                }
            }
            let response;
            try {
                if (message.length < headerSize)
                    throw new SmbError(`${message.length}-byte message is shorter than the SMB2 header`);
                const { header } = Smb2Packet.parseHeader(message);
                const sent = this.sentRequests.get(header.messageId);
                // No outstanding request has this MessageId: discard it (MS-SMB2
                // 3.2.5.1.2). Kept, it would answer a later request, after keys
                // exist, without being checked against that request.
                if (!sent)
                    continue;
                const refusal = this.verifyResponse(message, header, sent, transformSession);
                if (refusal !== undefined) {
                    this.refuse(header.messageId, refusal);
                    continue;
                }
                response = Response.parse(message);
            }
            catch (error) {
                this.failMalformed(error);
                return;
            }
            response.raw = message;
            this.onResponse(response);
        }
    };
    // Why a response cannot answer the request sent under its MessageId, or
    // undefined when it can (MS-SMB2 3.2.5.1). Only the decryption key and
    // the signature authenticate a response; every header field is checked
    // against the request, not trusted.
    verifyResponse(message, header, sent, transformSession) {
        if (header.type !== sent.type)
            return "response command does not match the request";
        // NEGOTIATE and the first SESSION_SETUP have no session yet; the
        // SESSION_SETUP response assigns it.
        if (sent.sessionId !== undefined && header.sessionId !== sent.sessionId)
            return "response session does not match the request";
        if (transformSession !== undefined) {
            // AES-CCM/GCM authenticated it with transformSession's key.
            return header.sessionId === transformSession ? undefined : "encrypted response session does not match its TRANSFORM header";
        }
        if (sent.encrypted)
            return "plaintext response on an encrypted session or share refused";
        const flags = header.flags ?? 0;
        if (flags & HeaderFlag.Signed) {
            // The final SESSION_SETUP response is signed with a key derived from
            // it; Session checks it once that key exists.
            if (sent.type === Smb2PacketType.SessionSetup)
                return undefined;
            const signing = this.signingKey(sent.sessionId);
            if (!signing)
                return "signed response for a session with no signing key refused";
            const ok = signing.algorithm === SigningAlgorithm.HmacSha256
                ? verifySignature(message, signing.key)
                : verifySignature3(message, signing.algorithm, signing.key);
            return ok ? undefined : "response signature verification failed";
        }
        if (!sent.signed)
            return undefined;
        // MS-SMB2 3.2.5.1.3: an interim response is never signed.
        const interim = header.status === StatusCode.Pending && (flags & HeaderFlag.Async) !== 0;
        if (interim || header.status === STATUS_USER_SESSION_DELETED)
            return undefined;
        return "unsigned response to a signed request refused";
    }
    // Rejects the request with SmbSigningError. The response is not parsed
    // and raises no "changeNotify" event.
    refuse(messageId, reason) {
        this.sentRequests.delete(messageId);
        const callback = this.responseCallbackMap.get(messageId);
        if (!callback)
            return;
        this.responseCallbackMap.delete(messageId);
        this.failedVerifications.set(messageId, { reason, ErrorType: SmbSigningError });
        callback({ header: { messageId, status: StatusCode.Success }, body: {} });
    }
    // Ends the connection after a check above this layer failed, such as a
    // VALIDATE_NEGOTIATE_INFO mismatch: pending requests fail and
    // nothing more is sent.
    terminate(reason) {
        if (this.connected)
            this.failAll(reason, SmbDialectError);
    }
    failMalformed(error) {
        this.failAll(`malformed response from server (${error instanceof Error ? error.message : String(error)})`, SmbError);
    }
    failAll(reason, ErrorType = SmbSigningError) {
        for (const [messageId, callback] of [...this.responseCallbackMap]) {
            this.responseCallbackMap.delete(messageId);
            this.failedVerifications.set(messageId, { reason, ErrorType });
            callback({ header: { messageId, status: StatusCode.Success }, body: {} });
        }
        this.sentRequests.clear();
        this.connected = false;
        this.destroySocket();
    }
    onResponse(response) {
        if (response.header.type === Smb2PacketType.ChangeNotify &&
            response.header.status === StatusCode.Success) {
            this.emit("changeNotify", response);
        }
        const messageId = response.header.messageId;
        // An async interim STATUS_PENDING (MS-SMB2 3.3.4.2) is not the answer:
        // the final response follows with the same MessageId. Samba 4.15+ and
        // Windows send one for a named-pipe READ served out of process, for
        // example. CHANGE_NOTIFY keeps its old contract: the interim resolves
        // the request and the final one arrives as a "changeNotify" event.
        const interim = response.header.status === StatusCode.Pending && ((response.header.flags ?? 0) & HeaderFlag.Async) !== 0;
        if (interim && response.header.type !== Smb2PacketType.ChangeNotify) {
            return;
        }
        // The final response ends the request. A CHANGE_NOTIFY stays
        // outstanding after its interim, until the final response arrives.
        if (!interim)
            this.sentRequests.delete(messageId);
        const callback = this.responseCallbackMap.get(messageId);
        if (callback) {
            this.responseCallbackMap.delete(messageId);
            callback(response);
        }
    }
    // Socket errors go to "error" listeners, if any. The client prints
    // nothing: the "close" that follows marks it disconnected, and pending
    // requests fail through their own timeouts. Emitting "error" with no
    // listener would throw, so skip it then.
    onError = (err) => {
        if (this.listenerCount("error") > 0)
            this.emit("error", err);
    };
    onClose = (hadError) => {
        this.connected = false;
    };
    async echo() {
        return await this.request({
            type: Smb2PacketType.Echo
        });
    }
    async authenticate(options) {
        if (!this.connected)
            await this.connect();
        const session = new Session(this);
        this.registerSession(session);
        await session.authenticateWithProvider(options);
        return session;
    }
    destroySocket() {
        this.socket
            .removeListener("data", this.onData)
            .removeListener("error", this.onError)
            .removeListener("close", this.onClose);
        this.socket.end();
        this.socket.destroy();
        delete this.socket;
    }
    registerSession(session) {
        session
            .once("authenticate", () => this.sessions.push(session))
            .once("logoff", () => this.sessions.splice(this.sessions.indexOf(session), 1));
    }
    async close() {
        if (!this.connected)
            return;
        await Promise.all(this.sessions.map(x => x.logoff()));
        this.destroySocket();
        this.connected = false;
    }
}
export default Client;
//# sourceMappingURL=Client.js.map