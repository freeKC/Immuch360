import { BasicAuthProvider } from './basic.js';
import { CredSSPAuthProvider } from './credssp/provider.js';
import { KerberosAuthProvider } from './kerberos.js';
import { NegotiateAuthProvider } from './negotiate.js';
import { NtlmAuthProvider } from './ntlm/provider.js';
export function createAuthProvider(mechanism) {
    switch (mechanism) {
        case 'basic':
            return new BasicAuthProvider();
        case 'ntlm':
            return new NtlmAuthProvider();
        case 'kerberos':
            return new KerberosAuthProvider();
        case 'negotiate':
            return new NegotiateAuthProvider();
        case 'credssp':
            // Only an explicit request selects it; negotiate never does.
            return new CredSSPAuthProvider();
        default:
            throw new Error(`Unknown auth mechanism: ${mechanism}`);
    }
}
export { BasicAuthProvider } from './basic.js';
export { CredSSPAuthProvider, credsspCredentialsError } from './credssp/provider.js';
export { KerberosAuthProvider, checkKeytabFile, kerberosHostError, kerberosSessionKeyAvailable, keytabCredentialsError, } from './kerberos.js';
export { NegotiateAuthProvider, KerberosCredentialError } from './negotiate.js';
export { NtlmAuthProvider } from './ntlm/provider.js';
export { hasWinRMMessageProtection } from './winrm-extension.js';
export { channelBindingsHash, packGssChannelBindings } from './channel-bindings.js';
//# sourceMappingURL=index.js.map