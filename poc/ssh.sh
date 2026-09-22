#!/bin/bash
# poc/ssh.sh [-u USER] [CMD...]  — ssh into the POC VM using .poc/ (default user: root).
# Used from the sandbox after vm-grant-access.sh ran on the host.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/.poc/vm.env"
U=root
if [ "${1:-}" = "-u" ]; then U=$2; shift 2; fi
HOST="$POC_VM_IP"; PORT=22
if [ -n "${POC_SSH_PROXY_PORT:-}" ] && ! timeout 3 bash -c "exec 3<>/dev/tcp/$HOST/22" 2>/dev/null; then
    HOST=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}'); PORT=$POC_SSH_PROXY_PORT
fi
exec ssh -i "$REPO/.poc/id_ed25519" -p "$PORT" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$REPO/.poc/known_hosts" \
    -o ConnectTimeout=10 -o LogLevel=ERROR "$U@$HOST" "$@"
