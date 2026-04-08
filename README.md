# pi-jail

A single-file Bash launcher that runs the [`pi`](https://github.com/badlogic/pi-mono) coding agent CLI (`@mariozechner/pi-coding-agent`) inside a Docker sandbox. Node.js and npm dependencies stay off your host machine, and `pi` is scoped to the directory it was launched from — plus any `docker compose` project rooted in that same directory.

## Security model

pi-jail mounts the host docker socket into the jail container but replaces the in-container `docker` CLI with a **filtering shim** at `/usr/local/bin/docker`. The shim queries the host daemon live and only permits operations against containers whose compose project `working_dir` label matches the directory from which pi-jail was launched. Host-wide operations (`run`, `create`, `build`, `network`, `volume`, `system`, `image`, …) are blocked outright.

The jail container itself runs with:

- `--user $(id -u):$(id -g)` — no root inside the container
- `--cap-drop=ALL` — all Linux capabilities dropped
- `--security-opt=no-new-privileges` — no privilege escalation
- `--group-add` of the host docker socket GID so the unprivileged user can reach the shim-filtered socket

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

If you need true host isolation, stop pi-jail from mounting the socket at all — at which point `docker ps` / `docker exec` from inside the jail no longer work and you lose compose integration.

## Compose integration

When you launch pi-jail from a directory where a `docker compose` project is already running, it:

1. Enumerates every container labeled with `com.docker.compose.project.working_dir=$(pwd)`.
2. Enumerates every docker network those containers are attached to.
3. Attaches the jail container to each of those networks (via `--network` at create time plus `docker network connect` for any extras).

The upshot: from inside the jail, `pi` can reach your compose services by service name (`curl http://web:3000`, `psql -h db`, …) and can `docker exec`/`docker logs` them via the shim.

Use `-n/--network NAME` to attach the jail to additional networks beyond the auto-detected set.

## How it works

On first run, `pi-jail` builds a Docker image from an embedded Dockerfile (Node.js LTS on Debian Bookworm with `pi`, `gh`, and common CLI tools pre-installed) and bakes the docker shim in at `/usr/local/bin/docker`. Subsequent runs reuse the image. If you edit the script, the image is automatically rebuilt via `md5sum` change detection.

## Prerequisites

- Docker installed and running on the host
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
| `~/.pi/agent` | same path | read-write | pi configuration, sessions, extensions, skills, auth |
| `/var/run/docker.sock` | `/var/run/docker.sock` | read-write | Host docker socket, filtered by the in-container shim |

All paths are mounted at their exact host paths. The container runs as the host user's UID/GID so mounted directories are always writable with no ownership mismatch. `HOME` is passed in explicitly so `pi` can locate `~/.pi/agent` without a matching `/etc/passwd` entry.

## Included tools

The image ships with these CLI tools alongside `pi`:

- `git` — version control
- `jq` — JSON processor
- `vim` — editor
- `gh` — GitHub CLI
- `docker` CLI (shim-filtered) and `docker compose` plugin
- `curl`, `gnupg`, `build-essential`

## Testing compose integration

A `docker-compose.yml` is included to verify that `pi-jail` can reach and manage compose services from inside the jail. Bring the stack up on the **host** first:

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
