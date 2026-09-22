#!/bin/bash
# pi-jail rootless POC — acceptance tests.  Runs INSIDE the VM as the
# unprivileged user (vm-up.sh does this last).  Prints one PASS/FAIL/LIMIT
# line per check and exits 1 if anything FAILed.  LIMIT lines are known,
# documented limits of the shim (soft fence), not regressions.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
ME=$(id -un); A="$HOME/www/demo-3000"; B="$HOME/www/demo-3001"
PASS=0; FAIL=0
pass()  { PASS=$((PASS+1)); echo "PASS  $*"; }
fail()  { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
limit() { echo "LIMIT $*"; }
check() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }
# Feed a bash snippet on stdin to a pi-jail started in DIR; only lines the
# snippet prefixes with "@@ " come back (pi-jail's own chatter is dropped).
in_jail() { (cd "$1" && pi-jail --shell 2>/dev/null) | sed -n 's/^@@ //p'; }
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
wait_http() { for _ in $(seq 1 90); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" = 200 ] && return 0; sleep 2; done; return 1; }

echo "== 1. Docker is rootless =="
check "active docker context is 'rootless'"            test "$(docker context show)" = rootless
check "daemon reports name=rootless"                    sh -c "docker info --format '{{join .SecurityOptions \",\"}}' | grep -q name=rootless"
check "rootful docker.service inactive"                 sh -c "! systemctl is-active --quiet docker.service"
check "no /var/run/docker.sock on the VM"               test ! -e /var/run/docker.sock
check "user-level docker.service active"                systemctl --user is-active --quiet docker
check "no root-owned dockerd/containerd processes"      sh -c "! pgrep -u root -x dockerd && ! pgrep -u root -x containerd"

echo "== 2. pi-jail runs =="
check "pi-jail -- --help exits 0 from demo-3000"       sh -c "cd '$A' && pi-jail -- --help"

echo "== 3. VM user =="
check "user minimul exists"                             id minimul
check "minimul has no sudo"                             sh -c "! sudo -n true"
check "minimul not in sudo/admin/docker groups"         sh -c "! id -nG minimul | grep -Ewq 'sudo|admin|docker'"

echo "== 4. www =="
check "/home/minimul/www exists"                        test -d /home/minimul/www

echo "== 5. Rails apps with compose =="
for d in "$A" "$B"; do
    n=$(basename "$d")
    check "$n: compose.yml, Gemfile, Dockerfile-dev present" sh -c "test -f '$d/compose.yml' && test -f '$d/Gemfile' && test -f '$d/Dockerfile-dev'"
    running=$(cd "$d" && docker compose ps --status running --services 2>/dev/null | sort | tr '\n' ' ')
    check "$n: 6 services running (got: ${running:-none})"    sh -c "[ $(echo "$running" | wc -w) -ge 6 ]"
done
check "demo-3000 answers 200 on 127.0.0.1:3000"        wait_http http://127.0.0.1:3000/
check "demo-3001 answers 200 on 127.0.0.1:3001"        wait_http http://127.0.0.1:3001/
check "files written by containers are owned by $ME"    test "$(stat -c %U "$A/log/development.log")" = "$ME"

echo "== 6. pi-jail in demo-3000 only reaches demo-3000 containers =="
OUT=$(in_jail "$A" <<'EOF'
echo "@@ ps=$(docker ps --format '{{.Names}}' | sort | tr '\n' ' ')"
docker exec demo-3000-rails-1 true >/dev/null 2>&1 && echo "@@ exec_own=ok" || echo "@@ exec_own=denied"
docker exec demo-3001-rails-1 true >/dev/null 2>&1 && echo "@@ exec_other=ok" || echo "@@ exec_other=denied"
docker logs demo-3001-db-1 >/dev/null 2>&1 && echo "@@ logs_other=ok" || echo "@@ logs_other=denied"
docker stop demo-3001-redis-1 >/dev/null 2>&1 && echo "@@ stop_other=ok" || echo "@@ stop_other=denied"
docker run --rm alpine:3.19 true >/dev/null 2>&1 && echo "@@ run=ok" || echo "@@ run=denied"
docker compose -f /home/minimul/www/demo-3001/compose.yml ps >/dev/null 2>&1 && echo "@@ compose_f=ok" || echo "@@ compose_f=denied"
echo "@@ compose_ps=$(docker compose ps --format '{{.Name}}' 2>/dev/null | sort | tr '\n' ' ')"
echo "@@ http_own=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://rails:3000/)"
echo "@@ http_other=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://demo-3001-rails-1:3000/)"
echo "@@ raw=$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json | jq -r '.[].Names[0]' | sed 's@^/@@' | sort | tr '\n' ' ')"
EOF
)
ps_names=$(get ps)
check "docker ps lists only demo-3000-* (got: ${ps_names:-none})" sh -c "[ -n '$ps_names' ] && ! echo '$ps_names' | grep -q demo-3001"
check "docker exec on own container allowed"            test "$(get exec_own)" = ok
check "docker exec on demo-3001 refused"               test "$(get exec_other)" = denied
check "docker logs on demo-3001 refused"               test "$(get logs_other)" = denied
check "docker stop on demo-3001 refused"               test "$(get stop_other)" = denied
check "docker run refused"                              test "$(get run)" = denied
check "docker compose -f <other project> refused"       test "$(get compose_f)" = denied
check "docker compose ps scoped (got: $(get compose_ps))" sh -c "! echo '$(get compose_ps)' | grep -q demo-3001"
check "http://rails:3000 reachable from the jail"       test "$(get http_own)" = 200
check "demo-3001's rails unreachable from the jail (different network)" test "$(get http_other)" != 200
if echo "$(get raw)" | grep -q demo-3001; then
    limit "raw socket (shim bypass) still lists demo-3001 containers: documented soft fence; a hard fence needs an API proxy/authz plugin"
else
    pass "raw socket does not list demo-3001"
fi
OUT=$(in_jail "$B" <<'EOF'
echo "@@ ps=$(docker ps --format '{{.Names}}' | sort | tr '\n' ' ')"
EOF
)
ps_names=$(get ps)
check "pi-jail in demo-3001: docker ps lists only demo-3001-* (got: ${ps_names:-none})" sh -c "[ -n '$ps_names' ] && ! echo '$ps_names' | grep -q demo-3000"

echo "== 7. nothing originating from pi-jail runs as root =="
OUT=$(in_jail "$A" <<'EOF'
echo "@@ uid_map=$(head -1 /proc/self/uid_map | tr -s ' ' | sed 's/^ //')"
echo "@@ caps=$(awk '/^CapEff/ {print $2}' /proc/self/status)"
echo "@@ nnp=$(awk '/^NoNewPrivs/ {print $2}' /proc/self/status)"
# Worst case: bypass the shim, talk to the daemon API directly, mount / into a container.
cid=$(curl -s --unix-socket /var/run/docker.sock -X POST -H 'Content-Type: application/json' \
  'http://localhost/containers/create?name=pi-jail-escalation-probe' \
  -d '{"Image":"alpine:3.19","Cmd":["sh","-c","id; cat /host/etc/shadow; touch /host/root/pwned-by-pi-jail"],"HostConfig":{"Binds":["/:/host"]}}' | jq -r .Id)
curl -s -o /dev/null --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/$cid/start"
curl -s -o /dev/null --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/$cid/wait"
echo "@@ probe=$(curl -s --unix-socket /var/run/docker.sock "http://localhost/containers/$cid/logs?stdout=1&stderr=1" | tr -cd '[:print:]\n' | tr '\n' ' ')"
curl -s -o /dev/null --unix-socket /var/run/docker.sock -X DELETE "http://localhost/containers/$cid?force=1"
EOF
)
check "jail uid 0 is host uid $(id -u) (uid_map: $(get uid_map))"  test "$(get uid_map)" = "0 $(id -u) 1"
check "jail has no capabilities (CapEff=0)"              test "$(get caps)" = 0000000000000000
check "jail has NoNewPrivs=1"                            test "$(get nnp)" = 1
probe=$(get probe)
if [[ "$probe" == *"shadow"*"Permission denied"* && "$probe" == *"pwned-by-pi-jail"*"Permission denied"* && "$probe" != *"root:"*":0:0:"* ]]; then
    pass "shim-bypass probe mounting / cannot read /etc/shadow or write /root"
else
    fail "shim-bypass probe mounting / could read /etc/shadow or write /root ($probe)"
fi
( cd "$A" && pi-jail --shell <<'EOF' >/dev/null 2>&1
sleep 25
EOF
) &
sleep 8
owner=$(ps -eo user=,args= | awk '/[s]leep 25$/ {print $1; exit}')
check "process started inside the jail runs as '$ME' on the VM (got: ${owner:-none})" test "$owner" = "$ME"
wait

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
