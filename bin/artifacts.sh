#!/usr/bin/env bash
# Shared artifact URL table.
#
# Sourced by update-versions.sh (to regenerate checksums) and mirrored by the
# Dockerfile's fetch stage. Every artifact has a stable id of the form
# <tool>-<arch>, which is also the local filename and the name recorded in
# checksums.txt. Architecture-independent artifacts use <tool>-noarch.
#
# ARCH is a Go/Docker style arch (amd64, arm64). RARCH is the Rust/uname style
# spelling (x86_64, aarch64) that some projects use in their asset names.

set -euo pipefail

# shellcheck disable=SC2034  # consumed by the scripts that source this file
TOOLS=(go rustup kubectl stern k9s kargo jj nats hurl neovim docker buildx compose)
# shellcheck disable=SC2034
NOARCH_TOOLS=(nvm)
# shellcheck disable=SC2034
ARCHES=(amd64 arm64)

rust_arch() {
  case "$1" in
    amd64) echo x86_64 ;;
    arm64) echo aarch64 ;;
    *) echo "unsupported arch: $1" >&2; return 1 ;;
  esac
}

# artifact_url <tool> <arch>
artifact_url() {
  local tool=$1 arch=$2 rarch
  if [ "$arch" != noarch ]; then
    rarch=$(rust_arch "$arch")
  fi
  case "$tool" in
    go)
      echo "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" ;;
    rustup)
      echo "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rarch}-unknown-linux-gnu/rustup-init" ;;
    nvm)
      echo "https://github.com/nvm-sh/nvm/archive/refs/tags/v${NVM_VERSION}.tar.gz" ;;
    kubectl)
      echo "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" ;;
    stern)
      echo "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${arch}.tar.gz" ;;
    k9s)
      echo "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${arch}.tar.gz" ;;
    kargo)
      # Published as a bare binary, not an archive.
      echo "https://github.com/akuity/kargo/releases/download/v${KARGO_VERSION}/kargo-linux-${arch}" ;;
    jj)
      # musl only: upstream publishes no glibc Linux build, and the static
      # binary runs unchanged on Debian.
      echo "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-${rarch}-unknown-linux-musl.tar.gz" ;;
    nats)
      echo "https://github.com/nats-io/natscli/releases/download/v${NATS_VERSION}/nats-${NATS_VERSION}-linux-${arch}.zip" ;;
    hurl)
      echo "https://github.com/Orange-OpenSource/hurl/releases/download/${HURL_VERSION}/hurl-${HURL_VERSION}-${rarch}-unknown-linux-gnu.tar.gz" ;;
    neovim)
      # Neovim's asset names use x86_64 but plain arm64, so neither the Go nor
      # the Rust spelling covers both.
      case "$arch" in
        amd64) echo "https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-x86_64.tar.gz" ;;
        arm64) echo "https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-arm64.tar.gz" ;;
      esac ;;
    docker)
      echo "https://download.docker.com/linux/static/stable/${rarch}/docker-${DOCKER_VERSION}.tgz" ;;
    buildx)
      echo "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-${arch}" ;;
    compose)
      echo "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${rarch}" ;;
    *)
      echo "unknown tool: $tool" >&2; return 1 ;;
  esac
}
