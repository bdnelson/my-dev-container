# shellcheck shell=bash
# Interactive shell setup for the devcontainer.
#
# Sourced from /etc/bash.bashrc as well as /etc/profile.d, because a VS Code or
# `devcontainer exec` terminal is an interactive non-login shell.

# Debian's /etc/profile assigns PATH outright rather than extending it, so a
# login shell arrives here having discarded the PATH set by ENV in the image.
# Re-adding the toolchain directories here covers both cases: it restores them
# for a login shell and is a no-op for the non-login shell that still has them.
devbox_path_prepend() {
  case ":${PATH}:" in
    *":$1:"*) ;;
    *) PATH="$1:${PATH}" ;;
  esac
}

for _devbox_dir in \
  /opt/dbcli/bin \
  "${NVM_DIR:-/usr/local/nvm}/current/bin" \
  /usr/local/go/bin \
  "${CARGO_HOME:-/usr/local/cargo}/bin" \
  "${HOME:-/home/dev}/go/bin" \
  "${HOME:-/home/dev}/.local/bin"
do
  [ -d "$_devbox_dir" ] && devbox_path_prepend "$_devbox_dir"
done
unset _devbox_dir
export PATH

# nvm is a shell function, not a binary, so it only exists in shells that source
# this. Sourcing nvm.sh also selects the default alias, which puts the same Node
# on PATH that $NVM_DIR/current points at for non-interactive shells.
if [ -s "${NVM_DIR:-/usr/local/nvm}/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "${NVM_DIR:-/usr/local/nvm}/nvm.sh"
fi

if [ -s /usr/share/bash-completion/bash_completion ]; then
  # shellcheck disable=SC1091
  . /usr/share/bash-completion/bash_completion
fi

alias k=kubectl
alias kg='kubectl get'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias vi=nvim
alias vim=nvim

# An interactive login shell reaches this file twice: once through
# /etc/profile.d, and again because Debian's /etc/profile also sources
# /etc/bash.bashrc. The flag is deliberately not exported, so a new shell still
# gets its own banner and completions.
if [ -n "${PS1:-}" ] && [ -z "${_devbox_interactive_done:-}" ]; then
  _devbox_interactive_done=1

  # Generated rather than shipped: completion has to match the version of the
  # tool actually installed, and it is cheap enough to build once per shell.
  if command -v kubectl >/dev/null 2>&1; then
    . <(kubectl completion bash)
    complete -o default -F __start_kubectl k
  fi

  PS1='\[\e[35m\]\u@devbox\[\e[0m\]:\w\$ '
  echo "my-dev-container — run 'devbox-help' for the installed tools and idioms."
fi
