#!/usr/bin/env bash
# Verify every advertised tool is present and executable in the built image.
#
# Usage: IMAGE=my-dev-container:dev ./bin/smoke-test.sh

set -uo pipefail

IMAGE=${IMAGE:?set IMAGE to the tag under test}

# Each entry is a command line that must exit 0 inside the container. Version
# flags are used rather than --help so that a truncated or wrong-architecture
# binary fails rather than printing usage.
CHECKS=(
  "go version"
  "rustc --version"
  "cargo --version"
  "rustfmt --version"
  "node --version"
  "npm --version"
  "nvm --version"
  "kubectl version --client=true"
  "stern --version"
  "k9s version -s"
  "kargo version --client"
  # The plugin binaries directly, so the reported label names the tool rather
  # than kubectl four times over; kubectl's own dispatch to them is checked
  # further down. krew's version is a table, hence the grep. ctx and ns take no
  # version flag at all, so --help stands in: it still has to load and run the
  # binary, which is what would fail on a truncated or wrong-architecture one.
  "kubectl-krew version | grep GitTag"
  "kubectl-oidc_login --version"
  "kubectl-ctx --help"
  "kubectl-ns --help"
  "tilt version"
  "docker --version"
  "docker buildx version"
  "docker compose version"
  "aws --version"
  "claude --version"
  "curl --version"
  "wget --version"
  "hurl --version"
  "hurlfmt --version"
  "nvim --version"
  "tmux -V"
  "make --version"
  "gcc --version"
  "pgcli --version"
  "psql --version"
  "mycli --version"
  "mysql --version"
  "nats --version"
  "redis-cli --version"
  "openssl version"
  "dig -v"
  "nc -h"
  "socat -V"
  "tcpdump --version"
  "traceroute --version"
  "mtr --version"
  "ip -V"
  "ping -V"
  "git --version"
  "jj --version"
  "jq --version"
  "sudo -n true"
  "devbox-help"
)

fail=0
pass=0

run() {
  # run <command> — login shell, so /etc/profile.d/devbox.sh is sourced and
  # shell functions such as nvm exist. An interactive shell would source the
  # same file via /etc/bash.bashrc, but without a TTY it also emits job-control
  # warnings that would swamp the output; that path is checked separately below.
  docker run --rm --entrypoint /bin/bash "$IMAGE" -lc "$1" 2>&1
}

for check in "${CHECKS[@]}"; do
  if out=$(run "$check"); then
    printf '  ok    %-24s %s\n' "${check%% *}" "$(echo "$out" | grep -v '^my-dev-container' | head -1 | cut -c1-56)"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-24s %s\n' "${check%% *}" "$(echo "$out" | head -1 | cut -c1-56)"
    fail=$((fail + 1))
  fi
done

echo
echo "checking the container does not run as root"
uid=$(run 'id -u' | tr -d '[:space:]')
if [ "$uid" = "1000" ]; then
  echo "  ok    default uid is 1000"
  pass=$((pass + 1))
else
  echo "  FAIL  default uid is $uid, expected 1000"
  fail=$((fail + 1))
fi

echo
echo "checking the non-login interactive path is wired up"
# A devcontainer terminal is interactive and non-login: it reads
# /etc/bash.bashrc, never /etc/profile.d. Both have to reach devbox.sh.
if docker run --rm --entrypoint /bin/bash "$IMAGE" -ic 'type -t nvm' 2>/dev/null \
     | grep -q function; then
  echo "  ok    /etc/bash.bashrc sources devbox.sh (nvm is defined)"
  pass=$((pass + 1))
else
  echo "  FAIL  nvm is not defined in an interactive non-login shell"
  fail=$((fail + 1))
fi

echo
echo "checking run-time CA injection"
# The image ships trusting only the public roots; the proxy root is mounted at
# start. A throwaway self-signed CA stands in for it here, so the test needs no
# access to the real one.
# Staged inside the repo rather than under $TMPDIR: Docker Desktop on macOS does
# not share /var/folders by default, and an unshared bind mount source turns
# into an empty directory in the container rather than an error.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ca_dir=$(mktemp -d "$repo_root/.smoke-ca.XXXXXX")
trap 'rm -rf "$ca_dir"' EXIT
if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
     -subj "/CN=my-dev-container smoke test CA" \
     -keyout "$ca_dir/key.pem" -out "$ca_dir/smoke-test-ca.crt" >/dev/null 2>&1; then
  rm -f "$ca_dir/key.pem"

  # The entrypoint runs init-ca-certs before the command, so the certificate is
  # already in the bundle by the time this looks. The bundle is concatenated PEM
  # with no plaintext subjects, hence the decode rather than a grep over it.
  if docker run --rm \
       -v "$ca_dir:/run/secrets/ca-certificates:ro" \
       "$IMAGE" \
       bash -c 'openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt \
                  | openssl pkcs7 -print_certs -noout \
                  | grep -q "my-dev-container smoke test CA"' \
       2>/dev/null; then
    echo "  ok    mounted CA is trusted after the entrypoint runs"
    pass=$((pass + 1))
  else
    echo "  FAIL  mounted CA did not reach /etc/ssl/certs/ca-certificates.crt"
    fail=$((fail + 1))
  fi

  # openssl reads the same store, and the certificate has to be individually
  # hashed there rather than only appended to the bundle.
  if docker run --rm \
       -v "$ca_dir:/run/secrets/ca-certificates:ro" \
       "$IMAGE" \
       bash -c 'ls /etc/ssl/certs/*.0 >/dev/null && openssl verify -CApath /etc/ssl/certs /usr/local/share/ca-certificates/injected/injected-01.crt' \
       >/dev/null 2>&1; then
    echo "  ok    mounted CA is hashed into /etc/ssl/certs"
    pass=$((pass + 1))
  else
    echo "  FAIL  mounted CA was not hashed into /etc/ssl/certs"
    fail=$((fail + 1))
  fi
else
  echo "  SKIP  openssl on this host could not generate a test CA"
fi

echo
echo "checking the image ships no injected certificates of its own"
# A published image must trust only the public roots. Anything here would mean a
# private certificate had been baked into a layer.
if [ -z "$(docker run --rm --entrypoint /bin/bash "$IMAGE" \
             -c 'find /usr/local/share/ca-certificates -type f 2>/dev/null')" ]; then
  echo "  ok    no certificates baked into the image"
  pass=$((pass + 1))
else
  echo "  FAIL  the image carries certificates in /usr/local/share/ca-certificates"
  fail=$((fail + 1))
fi

echo
echo "checking kubectl dispatches the krew-installed plugins"
# krew's value is that `kubectl <plugin>` works, which needs $KREW_ROOT/bin on
# PATH for kubectl's own discovery, not just for the shell.
plugins=$(run 'kubectl plugin list 2>/dev/null')
for plugin in kubectl-krew kubectl-oidc_login kubectl-ctx kubectl-ns; do
  if echo "$plugins" | grep -q "/usr/local/krew/bin/$plugin"; then
    printf '  ok    kubectl plugin list finds %s\n' "$plugin"
    pass=$((pass + 1))
  else
    printf '  FAIL  kubectl plugin list does not find %s\n' "$plugin"
    fail=$((fail + 1))
  fi
done

echo
echo "checking the toolchain roots are writable without sudo"
# go install, cargo install, nvm install, and kubectl krew install all write
# outside $HOME.
for dir in /usr/local/cargo /usr/local/nvm /usr/local/krew/bin /home/dev/go/bin /home/dev/.local/bin; do
  if run "test -w $dir" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$dir"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s is not writable\n' "$dir"
    fail=$((fail + 1))
  fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
