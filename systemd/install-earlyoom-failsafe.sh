#!/usr/bin/env bash
# Install the cross-stack memory failsafe: spark-mem.sh library, spark-panic
# executable, and the spark-earlyoom.service unit. See the README section
# "Cross-stack memory failsafe (earlyoom + spark-panic)" for what each piece
# does.
#
# Design note: these three artifacts are installed by COPY, not symlink.
# earlyoom runs as a system service (root) and invokes spark-panic at OOM
# pressure — exactly the moment you cannot afford to read through a symlink
# into the operator's home directory, nor have the live code path mutate
# under a branch checkout. The user-shell tools in ~/.local/bin (llm-switch,
# flux-gen, docker-llm-switch) ARE symlinked — different blast radius.
#
# Usage:
#   sudo systemd/install-earlyoom-failsafe.sh           # install
#   sudo systemd/install-earlyoom-failsafe.sh --uninstall
#   systemd/install-earlyoom-failsafe.sh --check        # verify only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_MEM="$REPO_ROOT/docker/lib/spark-mem.sh"
SRC_PANIC="$REPO_ROOT/tools/spark-panic"
SRC_UNIT="$REPO_ROOT/systemd/units/spark-earlyoom.service"

DST_MEM="/usr/local/lib/spark-mem.sh"
DST_PANIC="/usr/local/bin/spark-panic"
DST_UNIT="/etc/systemd/system/spark-earlyoom.service"

usage() {
    cat <<EOF
Usage: $0 [--install|--uninstall|--check]

  --install    (default) Copy spark-mem.sh, spark-panic, and the
               spark-earlyoom.service unit into place; daemon-reload;
               enable --now the service.
  --uninstall  Stop and disable the service; remove the three files.
  --check      Verify install state without modifying anything.
EOF
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "error: $1 requires root (re-run with sudo)" >&2
        exit 1
    fi
}

require_sources() {
    local missing=0
    for f in "$SRC_MEM" "$SRC_PANIC" "$SRC_UNIT"; do
        if [[ ! -f "$f" ]]; then
            echo "error: source not found: $f" >&2
            missing=1
        fi
    done
    [[ $missing -eq 0 ]] || exit 1
}

check_state() {
    echo "==> Install state"
    for pair in "$SRC_MEM:$DST_MEM" "$SRC_PANIC:$DST_PANIC" "$SRC_UNIT:$DST_UNIT"; do
        local src="${pair%%:*}" dst="${pair##*:}"
        if [[ ! -e "$dst" ]]; then
            printf '  [missing]  %s\n' "$dst"
        elif [[ -L "$dst" ]]; then
            printf '  [symlink]  %s -> %s  (expected a copy)\n' "$dst" "$(readlink "$dst")"
        elif cmp -s "$src" "$dst"; then
            printf '  [ok]       %s\n' "$dst"
        else
            printf '  [drift]    %s differs from %s\n' "$dst" "$src"
        fi
    done
    echo "==> systemd"
    systemctl is-enabled spark-earlyoom.service 2>&1 | sed 's/^/  enabled: /' || true
    systemctl is-active  spark-earlyoom.service 2>&1 | sed 's/^/  active:  /' || true
}

ensure_earlyoom_pkg() {
    if ! command -v earlyoom >/dev/null 2>&1; then
        echo "==> Installing earlyoom (apt)"
        apt-get update -qq
        apt-get install -y earlyoom
    fi
}

install_all() {
    require_root "--install"
    require_sources
    ensure_earlyoom_pkg

    # If a previous symlink-style install is in place, replace it cleanly.
    for dst in "$DST_MEM" "$DST_PANIC" "$DST_UNIT"; do
        if [[ -L "$dst" ]]; then
            echo "==> Removing legacy symlink: $dst"
            rm -f "$dst"
        fi
    done

    echo "==> Installing $DST_MEM (0644 root:root)"
    install -m 0644 -o root -g root "$SRC_MEM"   "$DST_MEM"

    echo "==> Installing $DST_PANIC (0755 root:root)"
    install -m 0755 -o root -g root "$SRC_PANIC" "$DST_PANIC"

    echo "==> Installing $DST_UNIT (0644 root:root)"
    install -m 0644 -o root -g root "$SRC_UNIT"  "$DST_UNIT"

    echo "==> systemctl daemon-reload"
    systemctl daemon-reload

    echo "==> systemctl enable --now spark-earlyoom.service"
    systemctl enable --now spark-earlyoom.service

    echo "==> Done."
    systemctl --no-pager --lines=0 status spark-earlyoom.service || true
}

uninstall_all() {
    require_root "--uninstall"

    if systemctl list-unit-files spark-earlyoom.service >/dev/null 2>&1; then
        echo "==> Stopping and disabling spark-earlyoom.service"
        systemctl disable --now spark-earlyoom.service || true
    fi

    for dst in "$DST_UNIT" "$DST_PANIC" "$DST_MEM"; do
        if [[ -e "$dst" || -L "$dst" ]]; then
            echo "==> Removing $dst"
            rm -f "$dst"
        fi
    done

    systemctl daemon-reload
    echo "==> Done."
}

case "${1:---install}" in
    --install|"") install_all ;;
    --uninstall)  uninstall_all ;;
    --check)      check_state ;;
    -h|--help)    usage ;;
    *)            usage; exit 1 ;;
esac
