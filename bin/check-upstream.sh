#!/usr/bin/env bash
# Compare the pins in versions.env against the current upstream releases.
#
# Reports drift only. Bumping is a manual edit to versions.env followed by
# `make update-versions`, so that a version change is always a reviewable diff.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

set -a
# shellcheck disable=SC1091
source versions.env
set +a

gh_latest() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p'
}

pypi_latest() {
  curl -fsSL "https://pypi.org/pypi/$1/json" \
    | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1
}

report() {
  # report <name> <pinned> <latest>
  if [ "$2" = "$3" ]; then
    printf '  %-16s %-14s current\n' "$1" "$2"
  else
    printf '  %-16s %-14s -> %s\n' "$1" "$2" "$3"
  fi
}

# Go and rustup publish their current stable version as a plain file rather
# than a GitHub release.
go_latest() {
  curl -fsSL 'https://go.dev/dl/?mode=json' \
    | sed -n 's/.*"version": *"go\([0-9][^"]*\)".*/\1/p' | head -1
}

rustup_latest() {
  curl -fsSL https://static.rust-lang.org/rustup/release-stable.toml \
    | sed -n "s/^version *= *'\([^']*\)'.*/\1/p"
}

rust_latest() {
  curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml \
    | sed -n '/^\[pkg.rust\]/,/^\[/ s/^version *= *"\([0-9.]*\).*/\1/p' | head -1
}

# The Node LTS line this image tracks. Reports the newest release carrying an
# lts codename, which is what `nvm install --lts` would pick.
node_lts_latest() {
  curl -fsSL https://nodejs.org/dist/index.json \
    | tr '}' '\n' | grep '"lts":"' | sed -n 's/.*"version":"v\([^"]*\)".*/\1/p' | head -1
}

docker_static_latest() {
  curl -fsSL https://download.docker.com/linux/static/stable/x86_64/ \
    | grep -o 'docker-[0-9][0-9.]*\.tgz' | sed 's/docker-//; s/\.tgz//' \
    | sort -V | tail -1
}

report go       "$GO_VERSION"       "$(go_latest)"
report rustup   "$RUSTUP_VERSION"   "$(rustup_latest)"
report rust     "$RUST_VERSION"     "$(rust_latest)"
report nvm      "$NVM_VERSION"      "$(gh_latest nvm-sh/nvm)"
report node     "$NODE_VERSION"     "$(node_lts_latest)"
report kubectl  "$KUBECTL_VERSION"  "$(curl -fsSL https://dl.k8s.io/release/stable.txt | tr -d v)"
report stern    "$STERN_VERSION"    "$(gh_latest stern/stern)"
report k9s      "$K9S_VERSION"      "$(gh_latest derailed/k9s)"
report kargo    "$KARGO_VERSION"    "$(gh_latest akuity/kargo)"
report krew     "$KREW_VERSION"     "$(gh_latest kubernetes-sigs/krew)"
report tilt     "$TILT_VERSION"     "$(gh_latest tilt-dev/tilt)"
report jj       "$JJ_VERSION"       "$(gh_latest jj-vcs/jj)"
report neovim   "$NEOVIM_VERSION"   "$(gh_latest neovim/neovim)"
report hurl     "$HURL_VERSION"     "$(gh_latest Orange-OpenSource/hurl)"
report nats     "$NATS_VERSION"     "$(gh_latest nats-io/natscli)"
report docker   "$DOCKER_VERSION"   "$(docker_static_latest)"
report buildx   "$BUILDX_VERSION"   "$(gh_latest docker/buildx)"
report compose  "$COMPOSE_VERSION"  "$(gh_latest docker/compose)"
report awscli   "$AWSCLI_VERSION"   "$(curl -fsSL https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst | sed -n 's/^\(2\.[0-9.]*\)$/\1/p' | head -1)"
report pgcli    "$PGCLI_VERSION"    "$(pypi_latest pgcli)"
report mycli    "$MYCLI_VERSION"    "$(pypi_latest mycli)"
