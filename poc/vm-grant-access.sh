#!/bin/bash
# pi-jail rootless POC — HOST side.  Gives an agent running in a sandbox on
# this host (e.g. claude-jail in this repo dir) SSH access to the POC VM:
#   - launches the VM if it does not exist yet
#   - creates an ssh keypair under .poc/ (git-ignored) if missing
#   - installs openssh-server in the VM and authorises the key for root and,
#     if the user already exists, for minimul
#   - writes the VM address to .poc/vm.env
# Re-runnable.  Optional: POC_SSH_PROXY_PORT=2222 also forwards that host port
# to the VM's sshd, for sandboxes that cannot route to the incus bridge.
set -euo pipefail
VM="${POC_VM:-pi-jail-poc}"
IMAGE="${POC_IMAGE:-images:ubuntu/24.04/cloud}"
CPU="${POC_CPU:-6}"; MEM="${POC_MEM:-12GiB}"; DISK="${POC_DISK:-60GiB}"
POC_USER="${POC_USER:-minimul}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="$REPO/.poc"; KEY="$KEYDIR/id_ed25519"
log() { echo "==> [host] $*"; }

if ! incus info "$VM" >/dev/null 2>&1; then
    log "launching VM $VM from $IMAGE ($CPU cpu, $MEM, $DISK disk)"
    incus launch "$IMAGE" "$VM" --vm -c limits.cpu="$CPU" -c limits.memory="$MEM" -d root,size="$DISK"
else
    incus start "$VM" >/dev/null 2>&1 || true
fi
log "waiting for the incus agent"
until incus exec "$VM" -- true >/dev/null 2>&1; do sleep 2; done
incus exec "$VM" -- sh -c 'command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1 || true'
until incus exec "$VM" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; do sleep 2; done

mkdir -p "$KEYDIR"
grep -qx '.poc/' "$REPO/.gitignore" 2>/dev/null || echo '.poc/' >> "$REPO/.gitignore"
if [ ! -f "$KEY" ]; then
    log "generating agent keypair $KEY"
    ssh-keygen -q -t ed25519 -N '' -C "pi-jail-poc-agent" -f "$KEY"
fi

log "sshd + authorized key in the VM"
incus file push --mode 0644 "$KEY.pub" "$VM/tmp/agent.pub"
incus exec "$VM" --env POC_USER="$POC_USER" -- bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    command -v sshd >/dev/null || { apt-get update -qq; apt-get install -y -qq openssh-server >/dev/null; }
    printf "PermitRootLogin prohibit-password\nPasswordAuthentication no\n" > /etc/ssh/sshd_config.d/90-poc.conf
    install -d -m 700 /root/.ssh
    grep -qsf /tmp/agent.pub /root/.ssh/authorized_keys || cat /tmp/agent.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if id -u "$POC_USER" >/dev/null 2>&1; then
        h=$(getent passwd "$POC_USER" | cut -d: -f6)
        install -d -m 700 -o "$POC_USER" -g "$POC_USER" "$h/.ssh"
        grep -qsf /tmp/agent.pub "$h/.ssh/authorized_keys" || cat /tmp/agent.pub >> "$h/.ssh/authorized_keys"
        chown "$POC_USER:$POC_USER" "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
    fi
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
'

IP=$(incus exec "$VM" -- hostname -I | awk '{print $1}')
{
    echo "POC_VM=$VM"
    echo "POC_VM_IP=$IP"
    echo "POC_USER=$POC_USER"
    if [ -n "${POC_SSH_PROXY_PORT:-}" ]; then
        incus config device show "$VM" | grep -q '^ssh-proxy:' \
            || incus config device add "$VM" ssh-proxy proxy \
                 listen="tcp:0.0.0.0:$POC_SSH_PROXY_PORT" connect=tcp:127.0.0.1:22 >/dev/null
        echo "POC_SSH_PROXY_PORT=$POC_SSH_PROXY_PORT"
    fi
} > "$KEYDIR/vm.env"
log "VM $VM is at $IP; details in .poc/vm.env"
echo "    ssh -i $KEY -o StrictHostKeyChecking=accept-new root@$IP"
