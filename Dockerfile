# syntax=docker/dockerfile:1.7

# my-dev-container: a devcontainer image (https://containers.dev/) carrying the
# language toolchains, cluster tooling, database clients, and network utilities
# used day to day, so a project checkout needs nothing installed on the host.
#
# Base is Debian rather than Alpine because rustup, the AWS CLI v2 installer,
# the Claude Code binary, and the Node release tarballs are all glibc-only.
#
# Everything downloaded from upstream is pinned in versions.env and verified
# against checksums.txt (or, for the AWS CLI, a GPG signature).

ARG DEBIAN_TAG=13-slim


# ---------------------------------------------------------------------------
# fetch: download and verify upstream release binaries
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS fetch

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Extra roots needed to reach upstream download hosts through an intercepting
# corporate proxy. Empty on a clean checkout. See certs/README.md.
COPY certs/ /usr/local/share/ca-certificates/extra/
RUN set -eu; \
    if ls /usr/local/share/ca-certificates/extra/*.crt >/dev/null 2>&1; then \
      update-ca-certificates; \
    else \
      echo "no extra CAs supplied, using public roots only"; \
    fi

ARG TARGETARCH
WORKDIR /dl

COPY versions.env checksums.txt ./

# Every artifact is downloaded to a file named <tool>-<arch>, which is the same
# name checksums.txt records, so a single sha256sum -c covers the whole set.
# A build fails here if upstream replaces an artifact under an existing tag.
RUN <<'EOF'
set -eu
. ./versions.env

case "${TARGETARCH}" in
  amd64) RARCH=x86_64; NVIM_ARCH=x86_64 ;;
  arm64) RARCH=aarch64; NVIM_ARCH=arm64 ;;
  *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;;
esac

fetch() {
  # fetch <id> <url>
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$1" "$2"
}

fetch "go-${TARGETARCH}" \
  "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz"
fetch "rustup-${TARGETARCH}" \
  "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RARCH}-unknown-linux-gnu/rustup-init"
fetch "nvm-noarch" \
  "https://github.com/nvm-sh/nvm/archive/refs/tags/v${NVM_VERSION}.tar.gz"
fetch "kubectl-${TARGETARCH}" \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"
fetch "stern-${TARGETARCH}" \
  "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${TARGETARCH}.tar.gz"
fetch "k9s-${TARGETARCH}" \
  "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz"
fetch "nats-${TARGETARCH}" \
  "https://github.com/nats-io/natscli/releases/download/v${NATS_VERSION}/nats-${NATS_VERSION}-linux-${TARGETARCH}.zip"
fetch "hurl-${TARGETARCH}" \
  "https://github.com/Orange-OpenSource/hurl/releases/download/${HURL_VERSION}/hurl-${HURL_VERSION}-${RARCH}-unknown-linux-gnu.tar.gz"
fetch "neovim-${TARGETARCH}" \
  "https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz"
fetch "docker-${TARGETARCH}" \
  "https://download.docker.com/linux/static/stable/${RARCH}/docker-${DOCKER_VERSION}.tgz"
fetch "buildx-${TARGETARCH}" \
  "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-${TARGETARCH}"
fetch "compose-${TARGETARCH}" \
  "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${RARCH}"

grep -E -- "-(${TARGETARCH}|noarch)\$" checksums.txt >expected.txt
test -s expected.txt
sha256sum -c expected.txt
EOF

# /out is copied wholesale into the runtime stage and mirrors its filesystem
# layout. /tools holds artifacts that later builder stages consume but the
# runtime image does not ship (the rustup installer, the nvm scripts).
#
# Each archive is extracted into its own directory: several of them place loose
# files at the top level, and a shared directory would let one clobber another.
RUN <<'EOF'
set -eu
. ./versions.env
mkdir -p /out/usr/local/bin /out/usr/local/lib/docker/cli-plugins /tools

unpack() {
  # unpack <tool> — extract /dl/<tool>-<arch> into /tmp/x/<tool> and cd there.
  d="/tmp/x/$1"
  mkdir -p "$d"
  case "$1" in
    nats) unzip -qo "/dl/$1-${TARGETARCH}" -d "$d" ;;
    nvm)  tar -xzf "/dl/$1-noarch" -C "$d" ;;
    *)    tar -xzf "/dl/$1-${TARGETARCH}" -C "$d" ;;
  esac
  cd "$d"
}

# Go ships as a complete GOROOT tree; keep it whole under /usr/local/go.
unpack go
cp -a go /out/usr/local/go

# Neovim's tarball is already laid out as an install prefix (bin, lib, share).
unpack neovim
cp -a nvim-linux-*/. /out/usr/local/

install -m 0755 "/dl/kubectl-${TARGETARCH}" /out/usr/local/bin/kubectl

unpack stern
install -m 0755 stern /out/usr/local/bin/stern

unpack k9s
install -m 0755 k9s /out/usr/local/bin/k9s

unpack nats
install -m 0755 "nats-${NATS_VERSION}-linux-${TARGETARCH}/nats" /out/usr/local/bin/nats

unpack hurl
install -m 0755 hurl-*/bin/hurl /out/usr/local/bin/hurl
install -m 0755 hurl-*/bin/hurlfmt /out/usr/local/bin/hurlfmt

# Only the client. This image talks to the host's daemon over a mounted socket
# (docker-outside-of-docker); the dockerd and containerd binaries in the same
# bundle would never be run.
unpack docker
install -m 0755 docker/docker /out/usr/local/bin/docker

install -m 0755 "/dl/buildx-${TARGETARCH}" \
  /out/usr/local/lib/docker/cli-plugins/docker-buildx
install -m 0755 "/dl/compose-${TARGETARCH}" \
  /out/usr/local/lib/docker/cli-plugins/docker-compose

# Consumed by the rust and node stages, not shipped.
install -m 0755 "/dl/rustup-${TARGETARCH}" /tools/rustup-init
unpack nvm
mkdir -p /tools/nvm
cp -a nvm-*/. /tools/nvm/
EOF

# AWS CLI v2 is verified against its published GPG signature rather than a
# pinned digest, because AWS does not guarantee byte-stable archives per
# version. The signing key is vendored so the build does not depend on a
# keyserver being reachable; its fingerprint is checked before use.
ARG AWSCLI_PUBKEY_FINGERPRINT=FB5DB77FD5C118B80511ADA8A6310ACC4672475C
COPY aws-cli-public-key.asc /dl/aws-cli-public-key.asc
RUN <<'EOF'
set -eu
. /dl/versions.env

case "${TARGETARCH}" in
  amd64) RARCH=x86_64 ;;
  arm64) RARCH=aarch64 ;;
esac

export GNUPGHOME=/tmp/gnupg
mkdir -p "$GNUPGHOME"
chmod 0700 "$GNUPGHOME"
gpg --batch --import /dl/aws-cli-public-key.asc
gpg --batch --with-colons --fingerprint "${AWSCLI_PUBKEY_FINGERPRINT}" >/dev/null

cd /tmp
curl -fsSL --retry 3 -o awscli.zip \
  "https://awscli.amazonaws.com/awscli-exe-linux-${RARCH}-${AWSCLI_VERSION}.zip"
curl -fsSL --retry 3 -o awscli.zip.sig \
  "https://awscli.amazonaws.com/awscli-exe-linux-${RARCH}-${AWSCLI_VERSION}.zip.sig"
gpg --batch --verify awscli.zip.sig awscli.zip

# The installer writes absolute symlinks into --bin-dir, so it has to install
# to the paths the runtime image will actually use. Stage the result into /out
# afterwards rather than pointing --install-dir at /out.
unzip -q awscli.zip
./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
mkdir -p /out/usr/local/bin
cp -a /usr/local/aws-cli /out/usr/local/
cp -a /usr/local/bin/aws /usr/local/bin/aws_completer /out/usr/local/bin/
rm -rf /tmp/aws awscli.zip awscli.zip.sig "$GNUPGHOME"
EOF


# ---------------------------------------------------------------------------
# rust: run the verified rustup installer to lay down the pinned toolchain
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS rust

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY certs/ /usr/local/share/ca-certificates/extra/
RUN set -eu; \
    if ls /usr/local/share/ca-certificates/extra/*.crt >/dev/null 2>&1; then \
      update-ca-certificates; \
    fi

# Outside $HOME so that a devcontainer which mounts a volume over the home
# directory does not hide the toolchain.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin

COPY --from=fetch /tools/rustup-init /usr/local/bin/rustup-init
COPY versions.env /tmp/versions.env

# The minimal profile plus explicit components: rust-docs is the bulk of the
# default profile and is not useful in a container with no browser. rust-src
# and rust-analyzer are what an editor needs for completion and go-to-definition.
RUN <<'EOF'
set -eu
. /tmp/versions.env
rustup-init -y \
  --no-modify-path \
  --profile minimal \
  --default-toolchain "${RUST_VERSION}" \
  --component rustfmt --component clippy --component rust-src --component rust-analyzer
rm -rf "${CARGO_HOME}/registry" "${CARGO_HOME}/git"
EOF


# ---------------------------------------------------------------------------
# node: install nvm and the default Node version into a shared NVM_DIR
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS node

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY certs/ /usr/local/share/ca-certificates/extra/
RUN set -eu; \
    if ls /usr/local/share/ca-certificates/extra/*.crt >/dev/null 2>&1; then \
      update-ca-certificates; \
    fi

ENV NVM_DIR=/usr/local/nvm

COPY --from=fetch /tools/nvm ${NVM_DIR}
COPY versions.env /tmp/versions.env

# nvm verifies the Node tarball against nodejs.org's SHASUMS256.txt on its own,
# which is why the Node release is not listed in checksums.txt.
#
# $NVM_DIR/current is a stable path for the default version, so PATH in the
# runtime image does not have to name a version number. nvm itself manages
# $NVM_DIR/alias/default for interactive `nvm use`.
SHELL ["/bin/bash", "-c"]
RUN <<'EOF'
set -euo pipefail
. /tmp/versions.env
. "${NVM_DIR}/nvm.sh"
nvm install "${NODE_VERSION}"
nvm alias default "${NODE_VERSION}"
nvm cache clear
ln -s "${NVM_DIR}/versions/node/v${NODE_VERSION}" "${NVM_DIR}/current"
EOF


# ---------------------------------------------------------------------------
# python: build the virtualenv holding pgcli and mycli
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS python

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates build-essential python3 python3-dev python3-venv \
      libpq-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY certs/ /usr/local/share/ca-certificates/extra/
RUN set -eu; \
    if ls /usr/local/share/ca-certificates/extra/*.crt >/dev/null 2>&1; then \
      update-ca-certificates; \
    fi

COPY requirements.txt /tmp/requirements.txt

# --require-hashes makes pip refuse anything not pinned in requirements.txt,
# including transitive dependencies.
#
# The venv's bundled pip is used as-is. Upgrading it first would pull an
# unpinned package from PyPI, which is the one thing this stage exists to
# avoid.
RUN python3 -m venv /opt/dbcli \
    && /opt/dbcli/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements.txt \
    && find /opt/dbcli -name '__pycache__' -type d -prune -exec rm -rf {} +


# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS runtime

# ARG rather than ENV: noninteractive is right for the build, but leaving it
# set in the shipped image changes how apt and other tools behave for someone
# working interactively inside the container.
ARG DEBIAN_FRONTEND=noninteractive

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      # shell and session
      bash bash-completion tmux less ncurses-term tzdata locales sudo \
      # transport and certificates
      ca-certificates curl wget openssl gnupg openssh-client \
      # network diagnostics
      dnsutils iproute2 iputils-ping mtr-tiny netcat-openbsd socat tcpdump traceroute \
      # compiler toolchain: cgo, native crates, and anything with a Makefile
      build-essential make pkg-config libssl-dev zlib1g-dev libcap2-bin \
      # source control and general shell tooling
      git jq ripgrep file procps unzip zip xz-utils \
      # raw database clients
      postgresql-client default-mysql-client redis-tools \
      # python runtime for the pgcli/mycli venv
      python3 libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Unlike a cluster-side image, this one runs on a workstation behind the same
# intercepting proxy at runtime: go mod download, cargo, npm, and claude all
# make their own TLS connections from inside the container. The extra roots are
# therefore installed here as well, not just in the builder stages.
COPY certs/ /usr/local/share/ca-certificates/extra/
RUN set -eu; \
    if ls /usr/local/share/ca-certificates/extra/*.crt >/dev/null 2>&1; then \
      update-ca-certificates; \
    fi

# The user is created before the toolchains are copied in so that ownership can
# be set by COPY --chown. A `chown -R` afterwards would rewrite every file into
# a new layer, which costs the better part of a gigabyte for the Rust and Node
# trees alone.
#
# The uid/gid are build args so they can be matched to the host user when bind
# mounts would otherwise land root-owned files in the workspace.
RUN <<EOF
set -eu
groupadd --gid ${USER_GID} ${USERNAME}
useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME}
echo "${USERNAME} ALL=(root) NOPASSWD:ALL" >/etc/sudoers.d/${USERNAME}
chmod 0440 /etc/sudoers.d/${USERNAME}
# /commandhistory is a named-volume mount point (see devcontainer.json). Docker
# creates a missing mount point root-owned, so it has to exist here first.
mkdir -p /home/${USERNAME}/go/bin /home/${USERNAME}/.local/bin /home/${USERNAME}/.kube /commandhistory
chown -R ${USER_UID}:${USER_GID} /home/${USERNAME} /commandhistory
EOF

# Read-only at runtime, so these stay root-owned.
COPY --from=fetch  /out/     /
COPY --from=python /opt/dbcli  /opt/dbcli
COPY rootfs/ /

# Written to at runtime by `cargo install`, `rustup toolchain add`, and
# `nvm install`, so they belong to the container user. They live outside $HOME
# so that mounting a volume over the home directory cannot hide them.
COPY --from=rust --chown=${USER_UID}:${USER_GID} /usr/local/rustup  /usr/local/rustup
COPY --from=rust --chown=${USER_UID}:${USER_GID} /usr/local/cargo   /usr/local/cargo
COPY --from=node --chown=${USER_UID}:${USER_GID} /usr/local/nvm     /usr/local/nvm

ENV TZ=US/Eastern \
    LANG=C.UTF-8 \
    GOROOT=/usr/local/go \
    GOPATH=/home/${USERNAME}/go \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    NVM_DIR=/usr/local/nvm \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PATH=/home/${USERNAME}/.local/bin:/home/${USERNAME}/go/bin:/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/nvm/current/bin:/opt/dbcli/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# A devcontainer terminal is an interactive non-login shell, which reads
# /etc/bash.bashrc and never touches /etc/profile.d. Source it from there too,
# or nvm, the aliases, and the banner only appear under `bash -l`.
RUN echo '. /etc/profile.d/devbox.sh' >> /etc/bash.bashrc

# Capturing as a non-root user needs the capability on the binary. NET_RAW
# alone, deliberately: a file capability that is not in the container's bounding
# set makes execve fail outright with EPERM, and Docker's default set carries
# NET_RAW but not NET_ADMIN. Adding NET_ADMIN here would leave tcpdump
# unrunnable in any container started without an explicit --cap-add.
#
# Promiscuous mode does need NET_ADMIN; run `sudo tcpdump` in a container
# started with --cap-add=NET_ADMIN, or pass -p to capture without it.
#
# ping and mtr need no equivalent: Debian ships mtr-packet setuid root and
# iputils-ping with its own file capabilities.
RUN setcap cap_net_raw+eip /usr/bin/tcpdump

USER ${USERNAME}
WORKDIR /home/${USERNAME}
ENV HOME=/home/${USERNAME}

# Claude Code installs under $HOME: the launcher in ~/.local/bin, versions in
# ~/.local/share/claude. Credentials and settings live in ~/.claude, which is
# a separate directory and can be bind-mounted from the host without hiding the
# binary. The installer verifies its download against a signed release
# manifest, so there is no entry for it in checksums.txt.
COPY versions.env /tmp/versions.env
RUN set -eu; \
    . /tmp/versions.env; \
    curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"; \
    "${HOME}/.local/bin/claude" --version

# Devcontainers normally override this, but a plain `docker run` of the image
# should stay up so it can be exec'd into.
CMD ["sleep", "infinity"]

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="my-dev-container" \
      org.opencontainers.image.description="Devcontainer image: Go/Rust/Node toolchains, kubectl/k9s/stern, AWS CLI, database clients, network diagnostics, neovim, and Claude Code." \
      org.opencontainers.image.vendor="Brian Nelson" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"
