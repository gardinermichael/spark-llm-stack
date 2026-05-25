#!/usr/bin/env bash
# Install the user-shell CLI tools into ~/.local/bin/ as symlinks pointing
# back into the repo. Symlinks (not copies) are deliberate here — these are
# personal dev tools, and tracking HEAD is the point: `git pull` immediately
# refreshes the binary your shell will run next.
#
# This is the OPPOSITE policy from systemd/install-earlyoom-failsafe.sh,
# which intentionally copies because it serves a root system service.
#
# Usage:
#   tools/install-user-cli.sh             # install (no sudo)
#   tools/install-user-cli.sh --uninstall
#   tools/install-user-cli.sh --check

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"

# name -> source path (relative to REPO_ROOT)
TOOLS=(
    "llm-switch:systemd/llm-switch"
    "flux-gen:tools/flux-gen"
    "docker-llm-switch:docker/docker-llm-switch"
    "tok-log:tools/tok-log"
)

usage() {
    cat <<EOF
Usage: $0 [--install|--uninstall|--check]

  --install    (default) Symlink each tool into $BIN_DIR
  --uninstall  Remove the symlinks (only if they point into this repo)
  --check      Show install state without modifying anything
EOF
}

ensure_bin_dir() {
    if [[ ! -d "$BIN_DIR" ]]; then
        echo "==> Creating $BIN_DIR"
        mkdir -p "$BIN_DIR"
    fi
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "warning: $BIN_DIR is not on \$PATH — add it to your shell rc" >&2 ;;
    esac
}

install_tools() {
    ensure_bin_dir
    for entry in "${TOOLS[@]}"; do
        local name="${entry%%:*}"
        local rel="${entry#*:}"
        local src="$REPO_ROOT/$rel"
        local dst="$BIN_DIR/$name"

        if [[ ! -f "$src" ]]; then
            echo "error: source missing: $src" >&2
            exit 1
        fi
        if [[ ! -x "$src" ]]; then
            echo "==> chmod +x $src"
            chmod +x "$src"
        fi

        # If something is already there, only overwrite if it's a symlink we
        # own (points into this repo) or another symlink. Refuse to clobber
        # a regular file silently.
        if [[ -e "$dst" && ! -L "$dst" ]]; then
            echo "error: $dst exists and is not a symlink — refusing to overwrite" >&2
            exit 1
        fi

        ln -sfn "$src" "$dst"
        echo "==> $dst -> $src"
    done
    echo "==> Done."
}

uninstall_tools() {
    for entry in "${TOOLS[@]}"; do
        local name="${entry%%:*}"
        local rel="${entry#*:}"
        local src="$REPO_ROOT/$rel"
        local dst="$BIN_DIR/$name"

        if [[ ! -L "$dst" ]]; then
            echo "  [skip]    $dst (not a symlink)"
            continue
        fi
        local target
        target="$(readlink "$dst")"
        if [[ "$target" != "$src" ]]; then
            echo "  [skip]    $dst -> $target (not pointing into this repo)"
            continue
        fi
        rm -f "$dst"
        echo "  [removed] $dst"
    done
}

check_state() {
    echo "==> Install state (BIN_DIR=$BIN_DIR)"
    for entry in "${TOOLS[@]}"; do
        local name="${entry%%:*}"
        local rel="${entry#*:}"
        local src="$REPO_ROOT/$rel"
        local dst="$BIN_DIR/$name"

        if [[ ! -e "$dst" && ! -L "$dst" ]]; then
            printf '  [missing]  %s\n' "$dst"
        elif [[ -L "$dst" ]]; then
            local target; target="$(readlink "$dst")"
            if [[ "$target" == "$src" ]]; then
                printf '  [ok]       %s -> %s\n' "$dst" "$target"
            else
                printf '  [foreign]  %s -> %s  (expected %s)\n' "$dst" "$target" "$src"
            fi
        else
            printf '  [file]     %s  (not a symlink)\n' "$dst"
        fi
    done
}

case "${1:---install}" in
    --install|"") install_tools ;;
    --uninstall)  uninstall_tools ;;
    --check)      check_state ;;
    -h|--help)    usage ;;
    *)            usage; exit 1 ;;
esac
