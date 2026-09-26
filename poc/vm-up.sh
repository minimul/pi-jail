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
die() { echo "==> [host] ERROR: $*" >&2; exit 1; }
# retry N CMD...: run CMD up to N times, 2 s apart, until it succeeds.
retry() { local n=$1; shift; for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

# The VM resolves names but cannot connect out.  Its DNS is answered by incus
# on this host, so the host is not forwarding its traffic; say how to fix that.
no_egress() {
    local vm_ip bridge
    vm_ip=$(incus exec "$VM" -- hostname -I 2>/dev/null | awk '{print $1}') || true
    bridge=$(ip route get "$vm_ip" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p') || true
    bridge=${bridge:-incusbr0}
    {
        echo "==> [host] ERROR: the VM resolves $1 but cannot connect to it (IPv4, port 443)."
        echo "    Its DNS is answered by incus on this host, so the host is most likely not"
        echo "    forwarding the VM's traffic on $bridge."
        if systemctl is-active --quiet docker.service 2>/dev/null; then
            echo "    Rootful Docker runs here and sets the iptables FORWARD policy to DROP"
            echo "    (check: sudo iptables -S FORWARD | head -1).  Let the VM through, then re-run $0:"
            echo "        sudo iptables -I DOCKER-USER -i $bridge -j ACCEPT"
            echo "        sudo iptables -I DOCKER-USER -o $bridge -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
            echo "    These rules do not survive a reboot."
        else
            echo "    Check the host firewall's FORWARD chain (sudo iptables -S FORWARD), then re-run $0."
        fi
    } >&2
    exit 1
}

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
retry 60 incus exec "$VM" -- getent hosts download.docker.com \
    || die "the VM cannot resolve download.docker.com after 2 minutes; incus's dnsmasq on this host serves its DNS"

# Working DNS proves little, and without forwarding every apt and image
# download fails deep into provisioning.  IPv4 is what the rootless daemon
# pulls over.
log "checking the VM can reach the internet"
for h in download.docker.com registry-1.docker.io; do
    retry 3 incus exec "$VM" -- timeout 5 bash -c \
        'read -r ip _ < <(getent ahostsv4 "$1") && exec 3<>"/dev/tcp/$ip/443"' _ "$h" \
        || no_egress "$h"
done

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
