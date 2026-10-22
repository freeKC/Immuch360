export class BasicAuthProvider {
    mechanism = 'basic';
    createContext(_target, credentials) {
        if (!credentials.username)
            throw new Error('Basic auth needs a username');
        if (credentials.keytab !== undefined)
            throw new Error('Basic auth cannot use a keytab; a keytab works with Kerberos only');
        const token = Buffer.from(`${credentials.username}:${credentials.password ?? ''}`, 'utf8').toString('base64');
        let done = false;
        return {
            step: async () => {
                done = true;
                return { output: Buffer.from(token, 'ascii'), complete: true };
            },
            get complete() {
                return done;
            },
            negotiatedMechanism: 'basic',
        };
    }
}
//# sourceMappingURL=basic.js.map