# pi-jail

A single-file Bash launcher that runs the [`pi`](https://github.com/badlogic/pi-mono) coding agent CLI (`@earendil-works/pi-coding-agent`) inside a Docker sandbox. Node.js and npm dependencies stay off your host machine, and `pi` is scoped to the directory it was launched from — plus any `docker compose` project rooted in that same directory. It is built for **rootless Docker**: the daemon, the jail and everything `pi` can reach run as your own user, never as root.

## Security model

pi-jail requires a **rootless** Docker daemon (see [Rootless docker](#rootless-docker)). It mounts the socket of your active docker context into the jail container and replaces the in-container `docker` CLI with a **filtering shim** at `/usr/local/bin/docker`. The shim queries the daemon live and only permits operations against containers whose compose project `working_dir` label matches the directory from which pi-jail was launched. Host-wide operations (`run`, `create`, `build`, `network`, `volume`, `system`, `image`, …) are blocked outright.

The jail container itself runs with:

- a rootless daemon — every process `pi` starts is your uid on the host, including "root" inside the container (`/proc/self/uid_map` in the jail reads `0 <your uid> 1`)
- `--cap-drop=ALL` — all Linux capabilities dropped, so that in-container root cannot chown, setuid, or bypass file modes
- `--security-opt=no-new-privileges` — no privilege escalation

### What the shim prevents

| Attack vector | Protected? | How |
|---|---|---|
| `docker run -v /:/host` on the host daemon | ✅ | `run`/`create` are blocked commands |
| Listing or exec-ing into unrelated host containers | ✅ | `docker ps` is force-filtered by compose project label; `exec`/`logs`/`inspect` verify every container arg is in scope |
| Pulling/building arbitrary images | ✅ | `pull`/`push`/`build`/`image`/`save`/`load` blocked |
| Managing host networks / volumes | ✅ | `network`/`volume`/`system` blocked |
| `docker compose -f /elsewhere/docker-compose.yml` | ✅ | Compose project-scope-escape flags (`-f`, `-p`, `--project-directory`, `--env-file`) blocked |
| Tamper with pi credentials | ⚠️ | `~/.pi/agent` is read-write (pi needs to write sessions & locks); protect `auth.json` with `chmod 600` on the host |

### Important caveat: this is a soft fence

The shim is a filter in front of the docker CLI, **not** a sandbox primitive. Anything inside the jail that can talk to `/var/run/docker.sock` directly (a `curl` to the Unix socket, a statically linked docker binary smuggled into the workspace, an MCP server with its own socket client) bypasses the shim entirely. Treat it as a guard rail for an obedient agent, not a boundary against an adversary with arbitrary code execution inside the jail.

Rootless Docker bounds what such a bypass can do. The daemon runs as your user inside a user namespace, so the classic `docker run -v /:/host` escalation yields your own permissions, never root. A bypass can still reach your other rootless containers and any file you can read, which is why pi-jail refuses rootful daemons by default: there the same bypass would be root on the host.

If you need true host isolation, stop pi-jail from mounting the socket at all — at which point `docker ps` / `docker exec` from inside the jail no longer work and you lose compose integration.

## Rootless docker

pi-jail refuses to start against a rootful (root-owned) daemon unless you pass `--allow-rootful`, because the mounted socket would be a root-equivalent handle to the host. One-time host setup on Ubuntu 24.04 with Docker CE already installed from Docker's apt repo:

```bash
sudo apt-get install -y docker-ce-rootless-extras uidmap dbus-user-session slirp4netns
sudo systemctl disable --now docker.service docker.socket   # recommended: no root daemon at all
dockerd-rootless-setuptool.sh install        # add --force if you keep the rootful socket around
sudo loginctl enable-linger "$USER"
docker context use rootless
docker info --format '{{join .SecurityOptions ","}}'        # must include name=rootless
sudo gpasswd -d "$USER" docker               # docker-group membership is root; you no longer need it
```

- The daemon socket is `$XDG_RUNTIME_DIR/docker.sock`. pi-jail follows `DOCKER_HOST` or the active docker context, so run `docker compose up -d` in that same context or the jail will not see your stack.
- Images live in `~/.local/share/docker`; the `pi-jail` image is rebuilt there automatically on first run.
- Inside the jail `id -u` prints 0, but that root is you: files `pi` writes are owned by your user on the host.
- Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor. Ubuntu's `apparmor` package already ships `/etc/apparmor.d/rootlesskit` for `/usr/bin/rootlesskit`; only a rootlesskit installed elsewhere (for example the tarball install into `~/bin`) needs the profile from Docker's rootless troubleshooting page.
- Compose projects that publish ports below 1024 need `net.ipv4.ip_unprivileged_port_start=0`. `mem_limit`/`cpus` need cgroup delegation (`Delegate=cpu cpuset io memory pids` in `/etc/systemd/system/user@.service.d/delegate.conf`). Services running as a non-root uid that write into bind mounts leave files owned by a subordinate uid.

A complete, tested setup lives in [`poc/`](poc/README.md): an Incus VM with rootless Docker, two Rails compose stacks and acceptance tests for the scoping and no-root guarantees.

## Compose integration

When you launch pi-jail from a directory where a `docker compose` project is already running, it:

1. Enumerates every container labeled with `com.docker.compose.project.working_dir=$(pwd)`.
2. Enumerates every docker network those containers are attached to.
3. Attaches the jail container to each of those networks (via `--network` at create time plus `docker network connect` for any extras).

The upshot: from inside the jail, `pi` can reach your compose services by service name (`curl http://web:3000`, `psql -h db`, …) and can `docker exec`/`docker logs` them via the shim.

Use `-n/--network NAME` to attach the jail to additional networks beyond the auto-detected set.

## How it works

On first run, `pi-jail` builds a Docker image from an embedded Dockerfile (Node.js LTS on Debian Bookworm with `pi`, `gh`, and common CLI tools pre-installed) and bakes the docker shim in at `/usr/local/bin/docker`. Pi's bundled Vim-like modal editor extension is copied to a stable image path and loaded automatically. Subsequent runs reuse the image. If you edit the script, the image is automatically rebuilt via `md5sum` change detection.

## Prerequisites

- Docker running in **rootless mode** on the host (see [Rootless docker](#rootless-docker)); a rootful daemon works only with `--allow-rootful`
- Your project's `docker compose up -d` already running in the directory you launch pi-jail from (optional, but required for service-name networking and compose-scoped docker access)

## Installation

```bash
cp pi-jail ~/.local/bin/pi-jail
chmod +x ~/.local/bin/pi-jail
```

## Usage

```
pi-jail [OPTIONS] [-- ARGS...]

Options:
  -e, --env KEY=VAL    Pass an environment variable to the container (repeatable)
  -n, --network NAME   Attach the jail container to an extra docker network (repeatable)
  -r, --rebuild        Force rebuild of the Docker image
      --no-cache       Rebuild without using Docker cache
  -s, --shell          Start a bash shell instead of pi
      --allow-rootful  Permit a rootful (root-owned) docker daemon
  -h, --help           Show this help message

Arguments after -- are passed through to pi.
```

### Examples

```bash
# Run pi interactively (builds the image on first run)
pi-jail

# Pass arguments directly to pi
pi-jail -- -p "Summarize this codebase"

# Pass environment variables into the container
pi-jail -e ANTHROPIC_API_KEY=sk-ant-... -e MY_VAR=hello

# Attach to an extra docker network on top of any auto-detected compose networks
pi-jail -n my-other-stack_default

# Open a shell inside the container
pi-jail --shell

# Force a full image rebuild
pi-jail --rebuild
```

If `--shell` is used while a jail container for the same working directory is already running, the script `docker exec`s into it rather than starting a new one.

### Vim-like prompt editing

The inline prompt editor loads pi's bundled modal editor extension automatically:

- `Esc` switches from insert mode to normal mode
- `i` switches to insert mode
- `a` moves right and switches to insert mode
- `h`, `j`, `k`, `l` move in normal mode
- `0` and `$` move to the start and end of the line
- `x` deletes the character under the cursor

Pressing `Esc` while already in normal mode retains pi's normal abort behavior. This is a lightweight Vim-like editor, not a complete Vim implementation.

## Configuration

### API keys

`~/.pi/agent` is mounted into the container at the same path, so credentials written there are available on every run without setting environment variables.

```bash
mkdir -p ~/.pi/agent
echo '{"openrouter":{"type":"api_key","key":"sk-or-..."}}' > ~/.pi/agent/auth.json
chmod 600 ~/.pi/agent/auth.json
```

See the pi docs for [all providers and auth file format](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/providers.md).

### Adding packages

Edit `CUSTOM_APT_PACKAGES` near the top of the script:

```bash
CUSTOM_APT_PACKAGES="jq git vim tmux sqlite3"
```

The image rebuilds automatically on the next run.

## Volume mounts

| Host | Container | Mode | Purpose |
|---|---|---|---|
| `$(pwd)` | same path | read-write | Current working directory (path-mirrored for `docker compose` compatibility) |
| `~/.pi/agent` | same path | read-write | pi configuration, sessions, extensions, auth |
| `~/oss/minimul-skills` | `~/.pi/agent/skills` | read-write | Shared host skills directory |
| active context socket, e.g. `/run/user/1000/docker.sock` | `/var/run/docker.sock` | read-write | Rootless daemon socket, filtered by the in-container shim |

All paths are mounted at their exact host paths. Under rootless Docker the container runs as uid 0, which the daemon's user namespace maps to your host uid, so mounted directories are always writable and files `pi` creates are owned by you. `HOME` is passed in explicitly so `pi` can locate `~/.pi/agent`.

## Included tools

The image ships with these CLI tools alongside `pi`:

- `git` — version control
- `jq` — JSON processor
- `vim` — external editor
- Pi's bundled Vim-like modal editor extension — inline prompt editing
- `gh` — GitHub CLI
- `docker` CLI (shim-filtered) and `docker compose` plugin
- `curl`, `gnupg`, `build-essential`

## Testing compose integration

A `docker-compose.yml` is included to verify that `pi-jail` can reach and manage compose services from inside the jail. Bring the stack up on the **host**, in the rootless docker context, first:

```bash
docker compose up -d
```

Then launch a shell in pi-jail:

```bash
pi-jail --shell
```

You should see a line like:

```
Attaching jail to networks: pi-jail_default
Compose containers in scope: jail-test-web jail-docker-access-test
```

Inside the shell, verify compose-scoped docker access works:

```bash
# ps is force-scoped to the project label — only compose services are visible
docker ps

# exec/logs work against in-scope containers
docker logs jail-docker-access-test
docker exec jail-test-web wget -qO- http://127.0.0.1:8080

# service-name networking works via the attached compose network
wget -qO- http://test-web:8080
# => OK

# host-wide commands are blocked by the shim
docker run --rm alpine sh
# => pi-jail docker shim: refusing 'docker run' is host-wide and not allowed...

docker image ls
# => pi-jail docker shim: refusing 'docker image' is host-wide and not allowed...
```

Tear down afterward from the host:

```bash
docker compose down
```

## License

MIT
