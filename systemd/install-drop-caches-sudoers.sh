#!/usr/bin/env bash
# Install a tightly-scoped sudoers rule that lets the invoking user drop the
# kernel page cache without a password. See HANDOFF.md (2026-05-23) for the
# rationale — the obvious `sh -c "sync; echo 3 > ..."` form does NOT work
# because sudoers treats `;` as a Cmnd_Spec separator and sudo does exact
# argv matching.
#
# Usage:
#   sudo systemd/install-drop-caches-sudoers.sh           # install
#   sudo systemd/install-drop-caches-sudoers.sh --uninstall
#   systemd/install-drop-caches-sudoers.sh --check        # verify only

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/drop-caches"
TARGET_USER="${SUDO_USER:-${USER}}"

usage() {
    cat <<EOF
Usage: $0 [--install|--uninstall|--check]

  --install    (default) Write $SUDOERS_FILE for user '$TARGET_USER'
  --uninstall  Remove $SUDOERS_FILE
  --check      Verify the rule works without modifying anything
EOF
}

resolve_tee() {
    local tee_path
    tee_path="$(command -v tee || true)"
    if [[ -z "$tee_path" ]]; then
        echo "error: tee not found in PATH" >&2
        exit 1
    fi
    # Follow symlinks so sudoers gets the canonical path it will match against.
    readlink -f "$tee_path"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "error: $1 requires root (re-run with sudo)" >&2
        exit 1
    fi
}

check_rule() {
    echo "==> Verifying drop_caches rule for user '$TARGET_USER'"
    if ! sudo -n -l -U "$TARGET_USER" 2>/dev/null | grep -q "tee /proc/sys/vm/drop_caches"; then
        echo "  rule not active for $TARGET_USER" >&2
        return 1
    fi
    echo "  rule present"
    echo "==> Live test: sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"
    sync
    if echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null; then
        echo "  OK — page cache dropped"
    else
        echo "  FAILED — sudo denied the write" >&2
        return 1
    fi
}

install_rule() {
    require_root "--install"
    local tee_path
    tee_path="$(resolve_tee)"

    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        echo "error: target user '$TARGET_USER' does not exist" >&2
        exit 1
    fi

    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    cat >"$tmp" <<EOF
# Installed by systemd/install-drop-caches-sudoers.sh
# Allows '$TARGET_USER' to drop the kernel page cache without a password.
# Usage: sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
$TARGET_USER ALL=(root) NOPASSWD: $tee_path /proc/sys/vm/drop_caches
EOF

    # visudo -c -f validates syntax before we move it into place.
    if ! visudo -c -f "$tmp" >/dev/null; then
        echo "error: generated sudoers file failed visudo validation" >&2
        exit 1
    fi

    install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
    echo "==> Installed $SUDOERS_FILE"
    echo "    user=$TARGET_USER  tee=$tee_path"
    echo "==> Test with:  sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null"
}

uninstall_rule() {
    require_root "--uninstall"
    if [[ -f "$SUDOERS_FILE" ]]; then
        rm -f "$SUDOERS_FILE"
        echo "==> Removed $SUDOERS_FILE"
    else
        echo "==> $SUDOERS_FILE not present; nothing to do"
    fi
}

case "${1:---install}" in
    --install|"") install_rule ;;
    --uninstall)  uninstall_rule ;;
    --check)      check_rule ;;
    -h|--help)    usage ;;
    *)            usage; exit 1 ;;
esac
