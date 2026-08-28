#!/usr/bin/env bash
# Install the linters `make lint` runs: hadolint and shellcheck.
#
# Both are dropped into a repo-local directory (.tools/bin by default) rather
# than onto the host, so nothing outside the checkout is touched and the
# versions here cannot drift into other projects. `make lint` puts that
# directory on PATH.
#
# Versions live here rather than in versions.env: that file pins artifacts baked
# into the image, and these are host-side development tools that never enter a
# layer. They are also not tracked by bin/check-upstream.sh.
#
# Usage: bin/install-lint-tools.sh [destination-dir]

set -euo pipefail

HADOLINT_VERSION=${HADOLINT_VERSION:-2.15.1}
SHELLCHECK_VERSION=${SHELLCHECK_VERSION:-0.11.0}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest=${1:-$repo_root/.tools/bin}
mkdir -p "$dest"

case "$(uname -s)" in
  Linux)  hadolint_os=linux;  shellcheck_os=linux  ;;
  Darwin) hadolint_os=macos;  shellcheck_os=darwin ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

# Both projects name their assets with the uname spelling of the architecture,
# except that hadolint writes arm64 where the other writes aarch64.
case "$(uname -m)" in
  x86_64|amd64)  hadolint_arch=x86_64; shellcheck_arch=x86_64  ;;
  arm64|aarch64) hadolint_arch=arm64;  shellcheck_arch=aarch64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# installed <name> <wanted-version>: true when the pinned version is already in
# place, so a re-run is a no-op.
installed() {
  local name=$1 want=$2
  [ -x "$dest/$name" ] && "$dest/$name" --version 2>&1 | grep -qF "$want"
}

if installed hadolint "$HADOLINT_VERSION"; then
  echo "hadolint $HADOLINT_VERSION already installed"
else
  url="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-${hadolint_os}-${hadolint_arch}"
  echo "fetching $url"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$workdir/hadolint" "$url"
  install -m 0755 "$workdir/hadolint" "$dest/hadolint"
fi

if installed shellcheck "$SHELLCHECK_VERSION"; then
  echo "shellcheck $SHELLCHECK_VERSION already installed"
else
  url="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${shellcheck_os}.${shellcheck_arch}.tar.xz"
  echo "fetching $url"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$workdir/shellcheck.tar.xz" "$url"
  tar -xJf "$workdir/shellcheck.tar.xz" -C "$workdir" \
    "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
  install -m 0755 "$workdir/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$dest/shellcheck"
fi

echo
"$dest/hadolint" --version
"$dest/shellcheck" --version | sed -n 's/^version: /shellcheck /p'
echo
echo "installed into $dest; \`make lint\` picks them up from there"
