# Build-time and runtime CA certificates

Drop any additional root CAs needed to reach upstream hosts here as PEM files
with a `.crt` extension. The build installs them into every builder stage **and**
into the runtime image.

The contents of this directory are gitignored. Only this README and `.keep` are
tracked, so that `COPY certs/ ...` succeeds on a clean checkout.

## Why the runtime image trusts them too

This differs from `debug-toolbox`, whose runtime image deliberately trusts only
the public roots because it runs in-cluster. This image runs on a workstation
sitting behind the same intercepting proxy as the host, and the tools inside it
open their own TLS connections at runtime: `go mod download`, `cargo`, `npm`,
`aws`, and `claude` all fail with `x509: certificate signed by unknown
authority` (or the curl/OpenSSL equivalent) without the proxy root in the
container's trust store.

Note that Go and Node do not read the OpenSSL trust store the same way. Go on
Linux reads `/etc/ssl/certs/ca-certificates.crt`, which `update-ca-certificates`
regenerates, so it picks these up. Node uses its own bundled root list; the
image sets `NODE_EXTRA_CA_CERTS` to the system bundle for that reason.

## Exporting the Zscaler root on macOS

```sh
security find-certificate -a -c "Zscaler" -p /Library/Keychains/System.keychain \
  > certs/zscaler-root.crt
```

Verify it is the expected root before trusting it in a build:

```sh
openssl x509 -in certs/zscaler-root.crt -noout -subject -enddate
```

## Building off the corporate network

No action needed. An empty `certs/` directory is valid; the build skips the
`update-ca-certificates` step when no `.crt` files are present.
