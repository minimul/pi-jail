#!/bin/bash
# pi-jail rootless POC — runs INSIDE the Incus VM as the unprivileged user.
# Starts the rootless daemon, installs pi-jail, generates the two Rails apps
# under ~/www and brings their compose stacks up.  Idempotent.
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
POC_DIR="$HOME/poc"
log() { echo "==> [$(id -un)] $*"; }

log "rootless docker daemon"
if ! systemctl --user is-active --quiet docker; then
    dockerd-rootless-setuptool.sh install
fi
# The setup tool creates the 'rootless' context only after a successful start;
# make sure it exists even if an earlier attempt failed part-way.
docker context inspect rootless >/dev/null 2>&1 \
    || docker context create rootless --docker "host=unix://$XDG_RUNTIME_DIR/docker.sock" --description "Rootless mode" >/dev/null
docker context use rootless >/dev/null
systemctl --user enable --now docker.service >/dev/null 2>&1 || true   # survive VM reboots
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info --format '{{join .SecurityOptions ","}}' | grep -q 'name=rootless' \
    || { echo "daemon is not rootless" >&2; exit 1; }

log "install pi-jail"
install -m 0755 "$POC_DIR/pi-jail" "$HOME/.local/bin/pi-jail"

log "image for the escalation probe"
docker pull -q alpine:3.19 >/dev/null

# demo-3000 and demo-3001: same Rails app, different host ports.
bash "$POC_DIR/make-rails-app.sh" "$HOME/www/demo-3000" 3000 9222
bash "$POC_DIR/make-rails-app.sh" "$HOME/www/demo-3001" 3001 9232

for port in 3000 3001; do
    app="$HOME/www/demo-$port"
    log "demo-$port: build, migrate, up"
    (
        cd "$app"
        docker compose build
        # entrypoint waits for db, installs the good_job migration, runs db:prepare
        docker compose run --rm rails true
        docker compose up -d
    )
done

log "pi-jail image (built on first run inside the rootless daemon)"
(cd "$HOME/www/demo-3000" && pi-jail -- --help >/dev/null) || echo "pi --help returned non-zero; image is built, test.sh will report"
log "done"
