# CA certificates

Two separate things live under this heading, and they are deliberately kept
apart so that the published image never carries a private certificate.

## Run time — how the proxy root reaches the container

The runtime image trusts only the public roots as built. On a workstation
behind an intercepting proxy it needs the proxy root, because the tools inside
open their own TLS connections: `go mod download`, `cargo`, `npm`, `aws`, and
`claude` all fail with `x509: certificate signed by unknown authority` (or the
curl/OpenSSL equivalent) without it.

That root is supplied when the container starts. The entrypoint runs
`init-ca-certs`, which reads:

- `$CA_CERT_SECRET` — a PEM file, or a directory of them. Defaults to
  `/run/secrets/ca-certificates`.
- `$CA_CERT_PEM_B64` — a base64-encoded PEM bundle, for contexts that can only
  pass environment variables. It is visible in `docker inspect`, so prefer the
  file.

It splits whatever it finds into one certificate per file under
`/usr/local/share/ca-certificates/injected`, discards anything that does not
parse, warns about expired certificates, and runs `update-ca-certificates
--fresh`. Removing the source and restarting untrusts them again. With no
source present it is a no-op, so the same image works on and off the network.

`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE` all point at
`/etc/ssl/certs/ca-certificates.crt`, the bundle `update-ca-certificates`
regenerates, because Node, requests-based Python tools, and botocore each carry
their own root list rather than reading the OpenSSL store. Go on Linux reads
that bundle directly.

### One known limitation

Python 3.13 and later verify certificate chains with OpenSSL's strict flags on
by default. The Zscaler root marks its `basicConstraints` extension `CA:TRUE`
but not `critical`, which strict verification rejects:

```
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
Basic Constraints of CA cert not marked critical
```

curl, OpenSSL, Node, and Go all accept the same chain, and so does the Python
that ships inside the AWS CLI. This is a property of the certificate itself, not
of how it is installed, so it applied equally when the root was baked into the
image; nothing in this repo can change it. In practice it is latent, because
interception is applied per host and none of the hosts Python tooling reaches
(pypi.org among them) are currently intercepted. If a Python tool does start
failing this way against an intercepted host, the fix is a reissued root with
the extension marked critical, not a change here.

### Exporting the Zscaler root on macOS

```sh
make cert-export
```

which is:

```sh
mkdir -p ~/.config/ca-certificates
security find-certificate -a -c "Zscaler" -p /Library/Keychains/System.keychain \
  > ~/.config/ca-certificates/zscaler-root.crt
openssl x509 -in ~/.config/ca-certificates/zscaler-root.crt -noout -subject -enddate
```

`.devcontainer/devcontainer.json` bind-mounts that directory read-only onto
`/run/secrets/ca-certificates`, and `make shell` mounts it when it exists.

### Supplying it other ways

A plain `docker run`:

```sh
docker run --rm -it \
  -v ~/.config/ca-certificates:/run/secrets/ca-certificates:ro \
  ghcr.io/bdnelson/my-dev-container:latest bash
```

Compose, where a `secrets:` entry lands at `/run/secrets/<name>` already:

```yaml
services:
  dev:
    image: ghcr.io/bdnelson/my-dev-container:latest
    secrets: [ca-certificates]

secrets:
  ca-certificates:
    file: ~/.config/ca-certificates/zscaler-root.crt
```

Environment only, where no file can be mounted:

```sh
docker run --rm -it \
  -e CA_CERT_PEM_B64="$(base64 < ~/.config/ca-certificates/zscaler-root.crt)" \
  ghcr.io/bdnelson/my-dev-container:latest bash
```

Re-run `sudo init-ca-certs` inside a running container after changing the
source; it is idempotent.

## Build time — this directory

This directory is only for building the image **locally, from behind the
proxy**. Any `.crt` file dropped here is installed into the builder stages so
they can reach the upstream download hosts. It is not copied into the runtime
image, and CI builds with the directory empty.

The contents are gitignored. Only this README and `.keep` are tracked, so that
`COPY certs/ ...` succeeds on a clean checkout. An empty directory is valid and
the build skips `update-ca-certificates`.

If you pull the published image instead of building it, this directory is
irrelevant.
