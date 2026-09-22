#!/bin/bash
# pi-jail rootless POC — HOST side.  Creates an Ubuntu 24.04 Incus VM, provisions
# rootless Docker + the 'minimul' user + two Rails compose stacks under
# /home/minimul/www, installs pi-jail and runs the acceptance tests.
# Re-runnable: every step is idempotent.
#
#   POC_VM=pi-jail-poc POC_CPU=6 POC_MEM=12GiB POC_DISK=60GiB poc/vm-up.sh
set -euo pipefail
VM="${POC_VM:-pi-jail-poc}"
IMAGE="${POC_IMAGE:-images:ubuntu/24.04/cloud}"
CPU="${POC_CPU:-6}"; MEM="${POC_MEM:-12GiB}"; DISK="${POC_DISK:-60GiB}"
POC_USER="${POC_USER:-minimul}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
log() { echo "==> [host] $*"; }

if ! incus info "$VM" >/dev/null 2>&1; then
    log "launching VM $VM from $IMAGE ($CPU cpu, $MEM, $DISK disk)"
    incus launch "$IMAGE" "$VM" --vm -c limits.cpu="$CPU" -c limits.memory="$MEM" -d root,size="$DISK"
else
    log "VM $VM already exists; reusing it"
    incus start "$VM" >/dev/null 2>&1 || true
fi

log "waiting for the incus agent"
until incus exec "$VM" -- true >/dev/null 2>&1; do sleep 2; done
log "waiting for cloud-init and DNS"
incus exec "$VM" -- sh -c 'command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1 || true'
until incus exec "$VM" -- getent hosts download.docker.com >/dev/null 2>&1; do sleep 2; done

log "provisioning as root (docker-ce, rootless extras, user $POC_USER, no rootful daemon)"
incus file push -p --mode 0755 "$REPO/poc/provision-root.sh" "$VM/root/poc/provision-root.sh"
incus exec "$VM" --env POC_USER="$POC_USER" -- bash /root/poc/provision-root.sh

uid=$(incus exec "$VM" -- id -u "$POC_USER")
gid=$(incus exec "$VM" -- id -g "$POC_USER")
log "pushing pi-jail, rails-compose.yml and the user-side scripts (uid $uid)"
for f in pi-jail poc/rails-compose.yml poc/provision-user.sh poc/make-rails-app.sh poc/test.sh; do
    incus file push -p --mode 0755 --uid "$uid" --gid "$gid" \
        "$REPO/$f" "$VM/home/$POC_USER/poc/$(basename "$f")"
done

as_user() {
    incus exec "$VM" --user "$uid" --group "$gid" --cwd "/home/$POC_USER" \
        --env HOME="/home/$POC_USER" --env USER="$POC_USER" --env LOGNAME="$POC_USER" \
        --env XDG_RUNTIME_DIR="/run/user/$uid" \
        --env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        --env PATH="/home/$POC_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        -- "$@"
}

log "provisioning as $POC_USER (rootless daemon, rails apps, compose up, pi-jail image)"
as_user bash "/home/$POC_USER/poc/provision-user.sh"

log "acceptance tests"
as_user bash "/home/$POC_USER/poc/test.sh"
