# pi-jail rootless proof of concept (Incus VM)

Builds a throwaway Ubuntu 24.04 VM that proves the rootless conversion end to end:

1. Docker runs **rootless** inside the VM; the rootful `docker.service`, its socket and the system `containerd` are disabled.
2. `pi-jail` (this repo's script) runs inside the VM against that daemon.
3. `minimul` is the local VM user: uid 1000, no sudo, not in the `docker` group.
4. `/home/minimul/www` exists.
5. `www/demo-3000` and `www/demo-3001` are Rails apps using `poc/rails-compose.yml` as their `compose.yml` (rails, db, redis, sidekiq, good_job, playwright), on host ports 3000 and 3001.
6. A pi-jail started in `demo-3000` can only see and manage `demo-3000-*` containers; `demo-3001` is refused by the shim and is not on the jail's network.
7. Nothing that originates from pi-jail can run as root: in the jail `uid_map` reads `0 1000 1`, capabilities are empty, and a deliberate shim bypass that mounts `/` still cannot read `/etc/shadow` or write `/root`.
8. pi-jail can edit the code it was launched on: files it creates or changes in the launch directory land on the VM owned by the unprivileged user, and the other app's source tree is not mounted into the jail at all.

## Testing a real application

The checks read the container names, host ports and service list from compose
itself, so they are not tied to the generated apps. Point them at any two
compose projects:

```bash
POC_APP_A=~/www/myapp-3000 POC_APP_B=~/www/myapp-3001 poc/test.sh
```

Under rootless Docker a dev image whose `Dockerfile` switches to a non-root
uid cannot write its own bind-mounted tree. Keep it working under both daemons
with a compose override that defaults to the image's user:

```yaml
    # Rootless: set RUN_AS_USER=0:0 in .env (container root is your host user).
    # Unset or empty keeps the image default.
    user: "${RUN_AS_USER:-}"
```

## Run it (on the host)

```bash
poc/vm-up.sh          # ~15 min first time: VM, apt, rails new, bundle install, image pulls, tests
poc/vm-shell.sh       # login shell as minimul inside the VM
poc/vm-down.sh        # delete the VM
```

Requirements: `incus` on the host with the `images:` remote, KVM, and roughly 12 GiB RAM and 60 GiB disk to spare (`POC_CPU`, `POC_MEM`, `POC_DISK`, `POC_VM` override the defaults). `vm-up.sh` is re-runnable; every step is idempotent, so a failed run can simply be started again.

Try it by hand afterwards:

```bash
poc/vm-shell.sh
cd www/demo-3000
pi-jail --shell
docker ps                       # only demo-3000-*
docker exec demo-3001-rails-1 true   # refused: out of scope
curl -s http://rails:3000/ | head -3
cat /proc/self/uid_map          # 0 1000 1  → "root" here is minimul
```

## What the scripts do

| File | Runs as | Purpose |
|---|---|---|
| `vm-up.sh` | host | launch the VM, push files, run the two provisioning scripts, run the tests |
| `provision-root.sh` | VM root | docker-ce + `docker-ce-rootless-extras`, disable rootful daemon, create `minimul`, subuid/subgid, cgroup delegation, an AppArmor userns profile for rootlesskit if the distro did not ship one, `loginctl enable-linger` |
| `provision-user.sh` | VM minimul | `dockerd-rootless-setuptool.sh install`, `docker context use rootless`, install pi-jail, generate both apps, `compose build/run/up`, build the pi-jail image |
| `make-rails-app.sh` | VM minimul | `rails new` inside a rootless container, plus the files `rails-compose.yml` expects (`.env`, `Dockerfile-dev`, `Dockerfile-dev-postgres`, `config/sidekiq.yml`, entrypoint) |
| `test.sh` | VM minimul | acceptance checks for requirements 1–8, one `PASS`/`FAIL`/`LIMIT` line each (`POC_APP_A`/`POC_APP_B` retarget it) |

## Reading the test output

Every check prints `PASS` or `FAIL`; the script exits 1 if anything failed. One line is printed as `LIMIT`: from inside the jail, `curl --unix-socket /var/run/docker.sock` still lists `demo-3001` containers. That is the documented soft fence of the shim, unchanged by the conversion. What rootless changes is what such a bypass can do: the same test suite proves it cannot become root. A hard per-project fence would need an API-level filter (socket proxy or authorization plugin) or a dedicated rootless daemon per project.

## Notes on the compose file under rootless

- `mem_limit`/`mem_reservation` on `playwright` need cgroup v2 delegation; `provision-root.sh` installs `Delegate=cpu cpuset io memory pids` for `user@.service`.
- A service that mounts `/var/run/docker.sock` must use `${XDG_RUNTIME_DIR}/docker.sock` instead; under rootless that path does not exist.
- Files written by `rails`/`sidekiq` into the bind mount are owned by `minimul` on the VM, because container root maps to the daemon's user. Services that run as a non-root uid (postgres does, but it writes to a named volume) would create files owned by a subordinate uid.
- `RAILS_HOST` defaults to `127.0.0.1`; rootlesskit's port forwarder binds that on the VM, so the apps are reachable only from inside the VM (`curl 127.0.0.1:3000`).
