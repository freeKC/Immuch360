test_authority.pem: a self signed certificate made once with openssl for the widget tests of the trusted
certificates ("Immuch360 Test Authority", P-256, valid 100 years). The certificate only: its private key was never
kept, so nothing can be signed with it. The TLS tests make their certificates and keys at test time instead.
