#!/usr/bin/env bash
set -euo pipefail

# Normal removal keeps user-managed configuration and console data.  Application
# files, generated cache, logs, and the service unit are always disposable.
APPLICATION_DIR=/opt/pixelquest
CONFIG_DIR=/etc/pixelquest
DATA_DIR=/var/lib/pixelquest
CACHE_DIR=/var/cache/pixelquest
LOG_DIR=/var/log/pixelquest
RUN_DIR=/run/pixelquest
SERVICE_NAME=pixelquest.service
SERVICE_USER=pixelquest
COMMAND_LINK=/usr/local/bin/pixelquest

[[ ${EUID} -eq 0 ]] || {
    echo 'run as root: sudo ./uninstall.sh [--purge]' >&2
    exit 1
}

case "${1:-}" in
    "")
        purge=false
        ;;
    --purge)
        purge=true
        ;;
    *)
        echo "usage: $0 [--purge]" >&2
        exit 2
        ;;
esac

# Stopping first removes the transient systemd runtime directory cleanly before
# deleting the unit.  The command is harmless when nothing is installed/running.
systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME"

# Remove only the symlink created by this installer.  A user-replaced command
# must not be deleted as part of uninstalling Pixel Quest.
if [[ -L "$COMMAND_LINK" ]] &&
    [[ "$(readlink "$COMMAND_LINK")" == "$APPLICATION_DIR/bin/pixelquest" ]]; then
    rm -f "$COMMAND_LINK"
fi

# Built cores live with the replaceable application under /opt.  Cache, logs,
# and the socket are likewise disposable and are removed by every uninstall.
rm -rf \
    "$APPLICATION_DIR" \
    "$CACHE_DIR" \
    "$LOG_DIR" \
    "$RUN_DIR"

if [[ $purge == true ]]; then
    # Purge is intentionally the only mode that removes ROMs, saves, and state.
    rm -rf "$CONFIG_DIR" "$DATA_DIR"
    userdel "$SERVICE_USER" 2>/dev/null || true
    groupdel "$SERVICE_USER" 2>/dev/null || true

    echo 'Pixel Quest and its configuration and game data were removed.'
else
    echo 'Pixel Quest was removed. Configuration and game data remain in /etc/pixelquest and /var/lib/pixelquest.'
fi

systemctl daemon-reload
