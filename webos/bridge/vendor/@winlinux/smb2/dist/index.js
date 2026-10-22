// Public entry point: connect() plus the public types, the typed errors,
// and the auth-contract types the caller needs to supply an AuthProvider.
export { connect, SmbSession, DEFAULT_PORT, DEFAULT_REQUEST_TIMEOUT_MS, MAX_BUFFERED_FILE_BYTES, } from "./smb-session.js";
export { SmbError, SmbAccessDeniedError, SmbNotFoundError, SmbAlreadyExistsError, SmbSharingViolationError, SmbAuthError, SmbSigningError, SmbDialectError, SmbTimeoutError, SmbConnectionError, SmbFileTooLargeError, SmbEncryptionRequiredError, SmbNotADirectoryError, SmbIsADirectoryError, SmbDirectoryNotEmptyError, SmbAbortError, } from "./errors.js";
//# sourceMappingURL=index.js.map