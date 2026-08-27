# my-dev-container

A [devcontainer](https://containers.dev/) image that carries the language
toolchains, cluster tooling, database clients, and network diagnostics used day
to day, so that a project checkout needs nothing installed on the host beyond
Docker and an editor.

It is a sibling of `debug-toolbox`, not a variant of it. That image is a
cluster-side troubleshooting shell that must stay small; this one is a
workstation development environment with compilers, a writable toolchain, and
sudo. The build machinery is the same in both, and the two overlap in the tools
they share.

Neither image carries a private certificate. This one needs the corporate proxy
root to be useful on a workstation, so it takes it at container start instead of
at build time, which is what lets the image be built and published from public
CI. See [Corporate proxy](#corporate-proxy).

## What is inside

| Area | Tools |
| --- | --- |
| Languages | Go, Rust (rustup, cargo, clippy, rustfmt, rust-analyzer, rust-src), Node via nvm |
| Kubernetes | kubectl, k9s, stern, kargo, krew (with the oidc-login, ctx, and ns plugins) |
| Containers | docker CLI, buildx, compose (against the host daemon) |
| Version control | git, jj (Jujutsu) |
| HTTP | curl, wget, hurl, hurlfmt |
| Databases | pgcli, psql, mycli, mysql, redis-cli |
| Messaging | nats |
| Cloud | AWS CLI v2 |
| Editing | neovim, tmux |
| Build | make, gcc/g++, pkg-config, libssl-dev |
| Network | dig, nc, socat, tcpdump, traceroute, mtr, ip, ping, openssl |
| Agents | Claude Code (`claude`) |

Run `devbox-help` inside the container for versions and connection idioms.

The image is roughly 4 GB, most of it the Rust toolchain, GOROOT, and the Node
and AWS CLI trees. Toolchain directories are given their ownership by
`COPY --chown` rather than a later `chown -R`, which would otherwise duplicate
those trees into a second layer and add close to a gigabyte.

## Using it

The image is published to GitHub Container Registry, so the usual path is to
pull rather than build:

```sh
docker pull ghcr.io/bdnelson/my-dev-container:latest
```

With VS Code, open the folder you want to work in and point it at this
definition, or copy `.devcontainer/devcontainer.json` into that project and
change `build` to `"image": "ghcr.io/bdnelson/my-dev-container:latest"`.

Before the first run behind the proxy, export the root once:

```sh
make cert-export      # writes ~/.config/ca-certificates/zscaler-root.crt
```

With the devcontainer CLI:

```sh
make build
devcontainer up --workspace-folder /path/to/project
```

Without a devcontainer runtime at all:

```sh
make shell      # throwaway container with this repo mounted at /work
```

### Host integration

The container user's uid and gid have to match the host user's. A bind mount
carries the host's numeric ownership through unchanged, so a mismatch makes the
workspace look like it belongs to someone else from inside the container:
`git status` fails with "detected dubious ownership in repository", and anything
the container writes comes back to the host owned by the wrong user. This is no
longer a Linux-only concern -- Docker Desktop's old osxfs remapped ownership on
the way through, but VirtioFS and gRPC-FUSE do not.

So that the definition stays usable by anyone, the `USER_UID` and `USER_GID`
build args read `HOST_UID` and `HOST_GID` from the host environment and fall
back to 1000 when neither is set. Export them once:

```sh
echo "export HOST_UID=$(id -u)" >> ~/.zshenv
echo "export HOST_GID=$(id -g)" >> ~/.zshenv
```

`~/.zshenv` rather than `~/.zshrc`, because a devcontainer runtime is not
necessarily started from an interactive login shell and would inherit nothing
from one that is. `$UID` and `$EUID` cannot be used directly: they are shell
variables, not exported, so the devcontainer runtime cannot see them. Confirm
what was substituted with `devcontainer read-configuration --workspace-folder .`
before a rebuild, or `id -u` inside the running container afterwards.

The fallback is silent, so an unset `HOST_UID` on a host whose uid is not 1000
brings the ownership problem back. On a Linux host `updateRemoteUserUID` covers
that case anyway by rewriting the user at run time. On macOS the primary group
is usually staff (gid 20), which is already dialout in Debian; the Dockerfile
joins the existing group in that case rather than failing the build.

The definition bind-mounts `/var/run/docker.sock` so the container's docker CLI
drives the host daemon. It also mounts `~/.kube`, `~/.aws`, `~/.claude`,
`~/.ssh`, and the `nvim`, `jj`, `git`, and `k8s` directories under
`~/.config` from the host; remove any of those from `mounts` if you would rather
keep them out of the container. Bash history is kept in a named volume so it survives a rebuild.

The socket's group ownership comes from the host and is not knowable at build
time, so `postStartCommand` runs `sudo init-docker-socket` to reconcile it. Run
that by hand if docker reports a permission error after attaching.

`tcpdump` carries `cap_net_raw+eip`, so captures work as the `dev` user without
sudo. It is deliberately not given `cap_net_admin` as a file capability: a file
capability outside the container's bounding set makes `execve` fail with EPERM,
and Docker's default set has `NET_RAW` but not `NET_ADMIN`, so that would leave
`tcpdump` unrunnable under a plain `docker run`. Promiscuous mode still needs
`NET_ADMIN`, which the devcontainer grants; use `sudo tcpdump` for it, or pass
`-p`.

### Toolchain layout

The toolchains live outside `$HOME` so that mounting a volume over the home
directory cannot hide them, and are owned by `dev` so that `go install`,
`cargo install`, and `nvm install` work without sudo:

```
/usr/local/go        GOROOT              /home/dev/go       GOPATH
/usr/local/cargo     CARGO_HOME          /usr/local/rustup  RUSTUP_HOME
/usr/local/nvm       NVM_DIR             /usr/local/nvm/current  default Node
/usr/local/krew      KREW_ROOT           /usr/local/krew/bin     kubectl plugins
/opt/dbcli           pgcli/mycli venv    /home/dev/.local/bin    claude
```

`KREW_ROOT` is set away from krew's own default of `~/.krew` for the same
reason, and the symlinks krew writes into `$KREW_ROOT/bin` are absolute, so the
build installs plugins at the path the running container uses rather than
relocating them afterwards. `kubectl krew install` works without sudo, and
`kubectl plugin list` picks up anything installed that way because
`$KREW_ROOT/bin` is on `PATH`.

`nvm` is a shell function; it exists only in shells that source
`/etc/profile.d/devbox.sh`, which `/etc/bash.bashrc` does. Non-interactive
contexts get the default Node from `/usr/local/nvm/current/bin` on `PATH`.

## Corporate proxy

TLS to several upstream hosts is intercepted, so both the build and the tools
inside the running container need the proxy root. The two get it from different
places on purpose.

**At run time**, the root is injected. The image ships trusting only the public
roots; the entrypoint runs `init-ca-certs`, which reads a PEM file, or a
directory of them, from `/run/secrets/ca-certificates` (override with
`$CA_CERT_SECRET`, or pass `$CA_CERT_PEM_B64` where no file can be mounted),
splits it, validates it, and regenerates the trust store. `devcontainer.json`
bind-mounts `~/.config/ca-certificates` read-only onto that path, and `make
shell` mounts it when it exists. With nothing mounted the step is a no-op, so
the same image works on and off the network. Run `sudo init-ca-certs` inside a
running container after changing the source.

Node, requests-based Python tools, and botocore each keep their own root list
rather than reading the OpenSSL store, so `NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE` are all pointed at
`/etc/ssl/certs/ca-certificates.crt`, the bundle `update-ca-certificates`
regenerates.

**At build time**, only a local build needs anything: drop the root in `certs/`
as a `.crt` file and the builder stages install it so they can reach the
upstream download hosts. It never reaches the runtime image. CI builds with the
directory empty, and an empty `certs/` is valid anywhere.

`certs/README.md` has the export commands and the Compose and `docker run`
forms.

## Pinning and updates

Every artifact fetched from upstream is pinned in `versions.env` and verified
during the build:

- Release binaries and archives are checked against `checksums.txt`, which
  `make update-versions` regenerates by downloading each artifact for both
  architectures.
- The AWS CLI v2 installer is verified against its published GPG signature,
  using the vendored `aws-cli-public-key.asc` and a fingerprint check.
- `pgcli` and `mycli` install from a hash-pinned `requirements.txt` under
  `pip --require-hashes`, regenerated by `make update-requirements`.
- The Node tarball is verified by nvm against `SHASUMS256.txt`, and the Claude
  Code binary by its installer against a signed release manifest. Neither is
  listed in `checksums.txt` for that reason.

One thing is deliberately not pinned: the versions of the plugins krew installs
(`oidc-login`, `ctx`, `ns`). krew resolves a plugin from its index at the moment
of the build and has no flag for requesting a particular version, so a plugin
moves when the index moves. The archives are still verified, by krew, against
the SHA-256 in the index manifest. krew itself is pinned in `versions.env` like
everything else, and the resolved versions are printed by `kubectl krew list` in
the build log and by `devbox-help` in the running container.

`make check-upstream` reports which pins have newer releases. Bumping is always
a manual edit to `versions.env` followed by `make update-versions`, so a version
change shows up as a reviewable diff.

## Verifying a build

```sh
make test      # builds, then checks every advertised tool runs in the image
make lint      # hadolint + shellcheck
make scan      # trivy, HIGH/CRITICAL, fixed only
make sbom      # syft, SPDX JSON
```

`make test` also generates a throwaway self-signed CA, mounts it as the
run-time secret, and asserts both that it ends up trusted and that the image
itself carries no certificates of its own.

## Publishing

`.github/workflows/build.yml` builds each architecture on a native runner
(`ubuntu-24.04` and `ubuntu-24.04-arm`, rather than arm64 under QEMU, which
takes hours for the Rust, Node, and pip stages), runs the smoke test against
each, pushes both by digest, and only then stitches them into a tagged manifest
at `ghcr.io/bdnelson/my-dev-container`. A pull request builds and smoke-tests
both architectures without publishing anything.

Tags are `latest` and `edge` on the default branch, the version and `major.minor`
for a `v*` tag, and the full commit SHA for every build.

## Layout

```
Dockerfile              five stages: fetch, rust, node, python, runtime
versions.env            every upstream version pin
checksums.txt           generated; verified by the fetch stage
requirements.txt        generated; hash-pinned pgcli/mycli
bin/                    pin maintenance and the smoke test
rootfs/                 files copied verbatim into the image
certs/                  build-time proxy roots (gitignored except README/.keep)
.devcontainer/          devcontainer.json
.github/workflows/      multi-arch build and publish to GHCR
```
