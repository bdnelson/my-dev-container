#!/usr/bin/env bash
#
# Create the host paths the devcontainer bind-mounts, before Docker sees them.
#
# `docker run --mount type=bind` refuses to start when the source path does not
# exist; only the older `-v` form creates it on the fly. Both the devcontainer
# CLI and the VS Code extension emit `--mount`, and devcontainer.json has no way
# to make a mount conditional, so a host that has never run kargo dies with
#
#   invalid mount config for type "bind": bind source path does not exist
#
# Creating the paths up front keeps the mount list uniform: nothing in
# devcontainer.json has to be commented out because a tool is not configured
# yet. An empty directory mounts as an empty directory, which is what every
# consumer in the image already handles.
#
# Run from devcontainer.json's initializeCommand, which executes on the host.

set -euo pipefail

config="${1:-$(dirname "$0")/../.devcontainer/devcontainer.json}"

# Mount sources that are single files. Everything else in the list is a
# directory, and creating a directory where the image expects a file would
# leave, say, git reading an unreadable ~/.gitconfig.
is_file() {
  case "$1" in
    */.gitconfig | */.gitignore) return 0 ;;
    *) return 1 ;;
  esac
}

# Read the ${localEnv:HOME}-relative bind sources out of the mount list itself,
# so this cannot drift from devcontainer.json. The pattern is anchored to the
# opening quote, so the // comment lines in that block cannot match.
while IFS= read -r rel; do
  path="$HOME/$rel"

  if [ -e "$path" ]; then
    continue
  fi

  if is_file "$path"; then
    mkdir -p "$(dirname "$path")"
    : > "$path"
  else
    mkdir -p "$path"
  fi

  printf 'created %s\n' "$path"
done < <(sed -n 's/^[[:space:]]*"source=\${localEnv:HOME}\/\([^,"]*\).*/\1/p' "$config")
