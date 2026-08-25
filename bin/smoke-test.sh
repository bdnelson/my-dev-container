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
echo "checking the toolchain roots are writable without sudo"
# go install, cargo install, and nvm install all write outside $HOME.
for dir in /usr/local/cargo /usr/local/nvm /home/dev/go/bin /home/dev/.local/bin; do
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
