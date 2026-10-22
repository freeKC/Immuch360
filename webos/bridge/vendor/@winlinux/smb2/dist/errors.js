// Typed errors. SMB status codes come from MS-ERREF; the non-protocol
// errors (dialect, signing policy, timeouts, size caps) carry no status.
export class SmbError extends Error {
    status;
    constructor(message, status) {
        super(status === undefined ? message : `${message} (status 0x${status.toString(16).padStart(8, "0")})`);
        this.name = this.constructor.name;
        this.status = status;
    }
}
export class SmbAccessDeniedError extends SmbError {
}
export class SmbNotFoundError extends SmbError {
}
export class SmbAlreadyExistsError extends SmbError {
}
export class SmbSharingViolationError extends SmbError {
}
export class SmbAuthError extends SmbError {
}
export class SmbSigningError extends SmbError {
}
export class SmbDialectError extends SmbError {
}
export class SmbTimeoutError extends SmbError {
}
export class SmbConnectionError extends SmbError {
}
export class SmbFileTooLargeError extends SmbError {
}
// Shape errors for the file operations: the path is a file where a
// directory was needed, a directory where a file was needed, or a directory
// that still has entries.
export class SmbNotADirectoryError extends SmbError {
}
export class SmbIsADirectoryError extends SmbError {
}
export class SmbDirectoryNotEmptyError extends SmbError {
}
// A share (or the server) requires SMB encryption that this connection did
// not negotiate: a dialect below SMB 3.0, or no cipher in common (the
// client offers AES-128-GCM and AES-128-CCM). Subclass of
// SmbAccessDeniedError because the wire status is STATUS_ACCESS_DENIED;
// callers that only know the parent class keep working.
export class SmbEncryptionRequiredError extends SmbAccessDeniedError {
}
// The caller's AbortSignal fired. The name is 'AbortError', as for
// fetch() and other Node APIs, and as WinRMAbortError in @winlinux/winrm.
// The aborted call sends no more requests and closes its file or directory
// handle before it rejects; the session stays usable. `cause` is the
// signal's reason.
export class SmbAbortError extends SmbError {
    name = "AbortError";
    constructor(message, cause) {
        super(message);
        if (cause !== undefined)
            this.cause = cause;
    }
}
// Rejects before any request goes out when the signal is already aborted.
export function throwIfAborted(signal, context) {
    if (signal?.aborted)
        throw new SmbAbortError(`${context} was aborted`, signal.reason);
}
export const formatStatus = (status) => `0x${status.toString(16).padStart(8, "0")}`;
// Maps an SMB2 error status to a typed error. Never returns.
export function throwForStatus(status, context) {
    switch (status) {
        case 0xc0000022: // STATUS_ACCESS_DENIED
            throw new SmbAccessDeniedError(`access denied: ${context}`, status);
        case 0xc0000034: // STATUS_OBJECT_NAME_NOT_FOUND
        case 0xc000003a: // STATUS_OBJECT_PATH_NOT_FOUND
        case 0xc0000225: // STATUS_NOT_FOUND
            throw new SmbNotFoundError(`no such file or directory: ${context}`, status);
        case 0xc00000cc: // STATUS_BAD_NETWORK_NAME
            throw new SmbNotFoundError(`share not found: ${context}`, status);
        case 0xc0000103: // STATUS_NOT_A_DIRECTORY
            throw new SmbNotADirectoryError(`not a directory: ${context}`, status);
        case 0xc00000ba: // STATUS_FILE_IS_A_DIRECTORY
            throw new SmbIsADirectoryError(`is a directory: ${context}`, status);
        case 0xc0000101: // STATUS_DIRECTORY_NOT_EMPTY
            throw new SmbDirectoryNotEmptyError(`directory not empty: ${context}`, status);
        case 0xc0000035: // STATUS_OBJECT_NAME_COLLISION
            throw new SmbAlreadyExistsError(`already exists: ${context}`, status);
        case 0xc0000043: // STATUS_SHARING_VIOLATION
            throw new SmbSharingViolationError(`sharing violation (file in use): ${context}`, status);
        case 0xc000006d: // STATUS_LOGON_FAILURE
        case 0xc000006e: // STATUS_ACCOUNT_RESTRICTION
        case 0xc000006f: // STATUS_INVALID_LOGON_HOURS
        case 0xc0000070: // STATUS_INVALID_WORKSTATION
        case 0xc0000071: // STATUS_PASSWORD_EXPIRED
        case 0xc0000072: // STATUS_ACCOUNT_DISABLED
            throw new SmbAuthError(`authentication failed during ${context}`, status);
        default:
            throw new SmbError(`SMB request failed during ${context}`, status);
    }
}
// Translates a low-level request failure into a typed error. SMB response
// rejections (which carry header.status) become SmbError; anything else
// (timeouts, socket errors, fs errors) passes through untouched, except the
// client's request_timeout which becomes SmbTimeoutError.
export function toSmbError(error, context) {
    // An abort names the call that was aborted, not the request in flight.
    if (error instanceof SmbAbortError)
        return new SmbAbortError(`${context} was aborted`, error.cause);
    if (error instanceof SmbError)
        return error;
    const status = error?.header?.status;
    if (typeof status === "number") {
        try {
            throwForStatus(status, context);
        }
        catch (typed) {
            return typed;
        }
    }
    if (error instanceof Error && error.message.startsWith("request_timeout")) {
        return new SmbTimeoutError(`request timed out during ${context}: ${error.message}`);
    }
    return error;
}
//# sourceMappingURL=errors.js.map