#!/bin/bash
# Interactive login shell as the unprivileged user inside the POC VM.
#   poc/vm-shell.sh                 # bash in /home/minimul
#   poc/vm-shell.sh -- cd www/demo-3000 && pi-jail --shell   (pass a command)
set -euo pipefail
VM="${POC_VM:-pi-jail-poc}"; POC_USER="${POC_USER:-minimul}"
uid=$(incus exec "$VM" -- id -u "$POC_USER"); gid=$(incus exec "$VM" -- id -g "$POC_USER")
[ "${1:-}" = "--" ] && shift
exec incus exec "$VM" -t --user "$uid" --group "$gid" --cwd "/home/$POC_USER" \
    --env HOME="/home/$POC_USER" --env USER="$POC_USER" --env LOGNAME="$POC_USER" \
    --env TERM="${TERM:-xterm-256color}" \
    --env XDG_RUNTIME_DIR="/run/user/$uid" \
    --env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    --env PATH="/home/$POC_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    -- bash -l ${1:+-c "$*"}
