#!/bin/bash
# pi-jail rootless POC — acceptance tests.  Runs INSIDE the VM as the
# unprivileged user (vm-up.sh does this last).  Prints one PASS/FAIL/LIMIT
# line per check and exits 1 if anything FAILed.  LIMIT lines are known,
# documented limits of the shim (soft fence), not regressions.
#
# The two app directories default to the ones provision-user.sh generates.
# Point them at any two compose projects to test a real application:
#   POC_APP_A=~/www/foo-3000 POC_APP_B=~/www/foo-3001 poc/test.sh
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
ME=$(id -un)
A="${POC_APP_A:-$HOME/www/demo-3000}"; B="${POC_APP_B:-$HOME/www/demo-3001}"
AN=$(basename "$A"); BN=$(basename "$B")
PASS=0; FAIL=0
pass()  { PASS=$((PASS+1)); echo "PASS  $*"; }
fail()  { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
limit() { echo "LIMIT $*"; }
check() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }
# Feed a bash snippet on stdin to a pi-jail started in DIR; only lines the
# snippet prefixes with "@@ " come back (pi-jail's own chatter is dropped).
# Extra KEY=VALUE arguments are injected as shell assignments ahead of the
# snippet, so a quoted heredoc can still reference the caller's values.
in_jail() {
    local dir=$1 kv; shift
    { for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done; cat; } \
    | (cd "$dir" && pi-jail --shell 2>/dev/null) | sed -n 's/^@@ //p'
}
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
wait_http() { for _ in $(seq 1 90); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" = 200 ] && return 0; sleep 2; done; return 1; }
# Ask compose itself for the project's names and ports, so the checks follow
# whatever the app's compose.yml and .env declare.
svc_container() { (cd "$1" && docker compose ps "$2" --format '{{.Name}}' 2>/dev/null | head -1); }
rails_port()    { (cd "$1" && docker compose config --format json 2>/dev/null \
                    | jq -r '.services.rails.ports[0].published // empty'); }
svc_count()     { (cd "$1" && docker compose config --services 2>/dev/null | wc -l); }

A_RAILS=$(svc_container "$A" rails); B_RAILS=$(svc_container "$B" rails)
B_DB=$(svc_container "$B" db);       B_REDIS=$(svc_container "$B" redis)
A_PORT=$(rails_port "$A");           B_PORT=$(rails_port "$B")
: "${A_PORT:=3000}"; : "${B_PORT:=3001}"

echo "== 1. Docker is rootless =="
check "active docker context is 'rootless'"            test "$(docker context show)" = rootless
check "daemon reports name=rootless"                    sh -c "docker info --format '{{join .SecurityOptions \",\"}}' | grep -q name=rootless"
check "rootful docker.service inactive"                 sh -c "! systemctl is-active --quiet docker.service"
check "no /var/run/docker.sock on the VM"               test ! -e /var/run/docker.sock
check "user-level docker.service active"                systemctl --user is-active --quiet docker
check "no root-owned dockerd/containerd processes"      sh -c "! pgrep -u root -x dockerd && ! pgrep -u root -x containerd"

echo "== 2. pi-jail runs =="
check "pi-jail -- --help exits 0 from $AN"              sh -c "cd '$A' && pi-jail -- --help"

echo "== 3. VM user =="
check "user $ME exists"                                 id "$ME"
check "$ME has no sudo"                                 sh -c "! sudo -n true"
check "$ME not in sudo/admin/docker groups"             sh -c "! id -nG '$ME' | grep -Ewq 'sudo|admin|docker'"

echo "== 4. www =="
check "$HOME/www exists"                                test -d "$HOME/www"

echo "== 5. Rails apps with compose =="
for d in "$A" "$B"; do
    n=$(basename "$d"); want=$(svc_count "$d")
    check "$n: compose.yml, Gemfile, Dockerfile-dev present" sh -c "test -f '$d/compose.yml' && test -f '$d/Gemfile' && test -f '$d/Dockerfile-dev'"
    running=$(cd "$d" && docker compose ps --status running --services 2>/dev/null | sort | tr '\n' ' ')
    check "$n: all $want compose services running (got: ${running:-none})" \
        sh -c "[ $(echo "$running" | wc -w) -ge ${want:-6} ]"
done
check "$AN answers 200 on 127.0.0.1:$A_PORT"            wait_http "http://127.0.0.1:$A_PORT/"
check "$BN answers 200 on 127.0.0.1:$B_PORT"            wait_http "http://127.0.0.1:$B_PORT/"
logfile=$(ls -t "$A"/log/*.log 2>/dev/null | head -1)
check "files written by containers are owned by $ME (${logfile##*/})" \
    sh -c "test -n '$logfile' && [ \"\$(stat -c %U '$logfile')\" = '$ME' ]"

echo "== 6. pi-jail in $AN only reaches $AN containers =="
OUT=$(in_jail "$A" "OWN_RAILS=$A_RAILS" "OTHER=$BN" "OTHER_RAILS=$B_RAILS" \
               "OTHER_DB=$B_DB" "OTHER_REDIS=$B_REDIS" "OTHER_DIR=$B" <<'EOF'
echo "@@ ps=$(docker ps --format '{{.Names}}' | sort | tr '\n' ' ')"
docker exec "$OWN_RAILS" true >/dev/null 2>&1 && echo "@@ exec_own=ok" || echo "@@ exec_own=denied"
docker exec "$OTHER_RAILS" true >/dev/null 2>&1 && echo "@@ exec_other=ok" || echo "@@ exec_other=denied"
docker logs "$OTHER_DB" >/dev/null 2>&1 && echo "@@ logs_other=ok" || echo "@@ logs_other=denied"
docker stop "$OTHER_REDIS" >/dev/null 2>&1 && echo "@@ stop_other=ok" || echo "@@ stop_other=denied"
docker run --rm alpine:3.19 true >/dev/null 2>&1 && echo "@@ run=ok" || echo "@@ run=denied"
docker compose -f "$OTHER_DIR/compose.yml" ps >/dev/null 2>&1 && echo "@@ compose_f=ok" || echo "@@ compose_f=denied"
echo "@@ compose_ps=$(docker compose ps --format '{{.Name}}' 2>/dev/null | sort | tr '\n' ' ')"
echo "@@ http_own=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://rails:3000/)"
echo "@@ http_other=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$OTHER_RAILS:3000/")"
echo "@@ raw=$(curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json | jq -r '.[].Names[0]' | sed 's@^/@@' | sort | tr '\n' ' ')"
EOF
)
ps_names=$(get ps)
check "docker ps lists only $AN containers (got: ${ps_names:-none})" sh -c "[ -n '$ps_names' ] && ! echo '$ps_names' | grep -q '$BN'"
check "docker exec on own container allowed"            test "$(get exec_own)" = ok
check "docker exec on $BN refused"                      test "$(get exec_other)" = denied
check "docker logs on $BN refused"                      test "$(get logs_other)" = denied
check "docker stop on $BN refused"                      test "$(get stop_other)" = denied
check "docker run refused"                              test "$(get run)" = denied
check "docker compose -f <other project> refused"       test "$(get compose_f)" = denied
check "docker compose ps scoped (got: $(get compose_ps))" sh -c "! echo '$(get compose_ps)' | grep -q '$BN'"
check "http://rails:3000 reachable from the jail"       test "$(get http_own)" = 200
check "$BN's rails unreachable from the jail (different network)" test "$(get http_other)" != 200
if echo "$(get raw)" | grep -q "$BN"; then
    limit "raw socket (shim bypass) still lists $BN containers: documented soft fence; a hard fence needs an API proxy/authz plugin"
else
    pass "raw socket does not list $BN"
fi
OUT=$(in_jail "$B" <<'EOF'
echo "@@ ps=$(docker ps --format '{{.Names}}' | sort | tr '\n' ' ')"
EOF
)
ps_names=$(get ps)
check "pi-jail in $BN: docker ps lists only $BN containers (got: ${ps_names:-none})" sh -c "[ -n '$ps_names' ] && ! echo '$ps_names' | grep -q '$AN'"

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

echo "== 8. pi-jail can edit the code in its launch directory =="
# A file created on the VM before the jail starts must be visible inside it,
# and edits made inside must land on the VM owned by $ME - that is the whole
# point of the path-mirrored bind mount.
HOST_PROBE="$A/.pi-jail-host-probe"
JAIL_PROBE="$A/.pi-jail-write-probe"
CODE_REL=$( (cd "$A" && ls config/application.rb Rakefile config.ru 2>/dev/null | head -1) )
rm -f "$HOST_PROBE" "$JAIL_PROBE"
echo "written on the VM" > "$HOST_PROBE"
before=$( [ -n "$CODE_REL" ] && sha256sum "$A/$CODE_REL" | cut -d' ' -f1)
OUT=$(in_jail "$A" "CODE_REL=${CODE_REL:-}" "OTHER_DIR=$B" <<'EOF'
echo "@@ pwd=$(pwd)"
echo "@@ host_file=$(cat .pi-jail-host-probe 2>/dev/null || echo MISSING)"
printf 'written inside the jail\n' > .pi-jail-write-probe 2>/dev/null \
    && echo "@@ create=ok" || echo "@@ create=denied"
if [ -n "$CODE_REL" ] && [ -f "$CODE_REL" ]; then
    cp "$CODE_REL" /tmp/orig 2>/dev/null
    printf '\n# pi-jail write probe\n' >> "$CODE_REL" 2>/dev/null \
        && echo "@@ modify=ok" || echo "@@ modify=denied"
    grep -q 'pi-jail write probe' "$CODE_REL" 2>/dev/null \
        && echo "@@ modify_readback=ok" || echo "@@ modify_readback=failed"
    cp /tmp/orig "$CODE_REL" 2>/dev/null \
        && echo "@@ restore=ok" || echo "@@ restore=failed"
else
    echo "@@ modify=no-code-file"
fi
mkdir -p .pi-jail-probe-dir 2>/dev/null && rmdir .pi-jail-probe-dir 2>/dev/null \
    && echo "@@ mkdir=ok" || echo "@@ mkdir=denied"
[ -e "$OTHER_DIR" ] && echo "@@ other_tree=visible" || echo "@@ other_tree=absent"
EOF
)
check "jail's working directory is $A (got: $(get pwd))"  test "$(get pwd)" = "$A"
check "a file written on the VM is readable in the jail"  test "$(get host_file)" = "written on the VM"
check "the jail can create a file in the launch directory" test "$(get create)" = ok
check "the jail can create a directory in the launch directory" test "$(get mkdir)" = ok
check "the jail can edit an existing source file (${CODE_REL:-none})" test "$(get modify)" = ok
check "the edit reads back inside the jail"               test "$(get modify_readback)" = ok
check "the jail restored the source file"                 test "$(get restore)" = ok
check "a file created in the jail exists on the VM"       test -f "$JAIL_PROBE"
check "it is owned by $ME on the VM (got: $(stat -c %U "$JAIL_PROBE" 2>/dev/null || echo none))" \
    sh -c "[ \"\$(stat -c %U '$JAIL_PROBE' 2>/dev/null)\" = '$ME' ]"
check "its content is what the jail wrote"                sh -c "grep -qx 'written inside the jail' '$JAIL_PROBE' 2>/dev/null"
after=$( [ -n "$CODE_REL" ] && sha256sum "$A/$CODE_REL" | cut -d' ' -f1)
check "the source file is byte-identical again on the VM" test -n "$before" -a "$before" = "$after"
check "$BN's source tree is not mounted into the jail"    test "$(get other_tree)" = absent
rm -f "$HOST_PROBE" "$JAIL_PROBE"

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
