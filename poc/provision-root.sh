#!/bin/bash
# pi-jail rootless POC — runs INSIDE the Incus VM as root (via vm-up.sh).
# Installs Docker CE + rootless extras, disables the rootful daemon entirely,
# creates the unprivileged VM user (no sudo, no docker group) and prepares the
# host for a rootless daemon on Ubuntu 24.04.  Idempotent.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
POC_USER="${POC_USER:-minimul}"
log() { echo "==> [root] $*"; }

log "base packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg git jq uidmap dbus-user-session slirp4netns \
    iptables apparmor-utils systemd-container >/dev/null

log "docker apt repo"
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin docker-ce-rootless-extras >/dev/null

log "disable the rootful daemon (no root-owned docker socket exists on this VM)"
systemctl disable --now docker.service docker.socket containerd.service >/dev/null 2>&1 || true
rm -f /var/run/docker.sock

log "user $POC_USER: local VM user, no sudo, no docker group"
if ! id -u "$POC_USER" >/dev/null 2>&1; then
    # Cloud images ship an 'ubuntu' user at uid 1000; free the uid so $POC_USER
    # gets 1000 like on the real host.
    if id -u ubuntu >/dev/null 2>&1 && [ "$(id -u ubuntu)" = 1000 ]; then
        userdel -r ubuntu >/dev/null 2>&1 || true
    fi
    useradd -m -s /bin/bash -u 1000 "$POC_USER" 2>/dev/null || useradd -m -s /bin/bash "$POC_USER"
fi
for g in sudo admin docker; do gpasswd -d "$POC_USER" "$g" >/dev/null 2>&1 || true; done
POC_UID=$(id -u "$POC_USER"); POC_GID=$(id -g "$POC_USER")
chown "$POC_UID:$POC_GID" "/home/$POC_USER"

log "subordinate uid/gid ranges for the user namespace"
grep -q "^$POC_USER:" /etc/subuid || usermod --add-subuids 100000-165535 "$POC_USER"
grep -q "^$POC_USER:" /etc/subgid || usermod --add-subgids 100000-165535 "$POC_USER"

log "cgroup v2 delegation (the compose file uses mem_limit on playwright)"
mkdir -p /etc/systemd/system/user@.service.d
cat > /etc/systemd/system/user@.service.d/delegate.conf <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
systemctl daemon-reload

log "AppArmor: Ubuntu 24.04 restricts unprivileged user namespaces; rootlesskit needs a profile"
RLK=$(command -v rootlesskit || echo /usr/bin/rootlesskit)
if ! grep -rqs "$RLK" /etc/apparmor.d/ 2>/dev/null; then
    profile_name=$(echo "$RLK" | sed -e 's@^/@@' -e 's@/@.@g')
    cat > "/etc/apparmor.d/$profile_name" <<EOF
abi <abi/4.0>,
include <tunables/global>

$RLK flags=(unconfined) {
  userns,

  include if exists <local/$profile_name>
}
EOF
    systemctl restart apparmor.service
fi

log "linger: the user manager (and the rootless dockerd) runs without a login session"
loginctl enable-linger "$POC_USER"
for _ in $(seq 1 30); do [ -S "/run/user/$POC_UID/bus" ] && break; sleep 1; done
[ -S "/run/user/$POC_UID/bus" ] || { echo "user bus for $POC_USER did not come up" >&2; exit 1; }

log "directories"
# One level at a time: 'install -d' leaves intermediate components owned by
# root, and the rootless daemon needs ~/.local writable for its data root.
for d in www .local .local/bin .local/share oss oss/minimul-skills .pi .pi/agent poc; do
    install -d -o "$POC_UID" -g "$POC_GID" "/home/$POC_USER/$d"
done
chown "$POC_UID:$POC_GID" "/home/$POC_USER/poc"/* 2>/dev/null || true

if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$POC_UID" -g "$POC_GID" "/home/$POC_USER/.ssh"
    install -m 600 -o "$POC_UID" -g "$POC_GID" /root/.ssh/authorized_keys "/home/$POC_USER/.ssh/authorized_keys"
fi

cat > /etc/profile.d/rootless-docker.sh <<'EOF'
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export PATH="$HOME/.local/bin:$PATH"
EOF
log "done (uid=$POC_UID)"
