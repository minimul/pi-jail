# pi-jail

A single-file Bash launcher that runs the [`pi`](https://github.com/badlogic/pi-mono) coding agent CLI (`@mariozechner/pi-coding-agent`) inside a Docker sandbox. Node.js and npm dependencies stay off your host machine, and `pi` only has access to the directory from which `pi-jail` is launched — plus any Docker containers defined within that same directory.

## Security model

The pi-jail container is **fully isolated from the host Docker daemon**. Instead of mounting the Docker socket (which grants full host-level access), pi-jail uses **Docker-in-Docker (DinD)** — a completely separate Docker daemon running inside its own container.

### Why DinD instead of docker-socket-proxy?

A Docker socket proxy (e.g. Tecnativa/docker-socket-proxy) filters by API *endpoint category*, but it cannot restrict what happens *within* allowed endpoints. Since `docker compose` requires both the Containers and POST endpoints, a proxy still allows:

- Creating privileged containers that mount the host root filesystem
- Inspecting environment variables (secrets, API keys) of all host containers
- Exec-ing into any container on the host

DinD eliminates all of these vectors by giving the pi-jail container its own isolated daemon with its own container/image/network/volume namespace.

### What DinD prevents

| Attack vector | Protected? | How |
|---|---|---|
| Mount host filesystem via `docker run -v /:/host` | ✅ | DinD's "host" is its own isolated filesystem |
| Read secrets from other containers | ✅ | Other containers don't exist in the DinD daemon |
| Exec into other containers | ✅ | Other containers don't exist in the DinD daemon |
| Create privileged containers | ✅ | Privileged inside DinD is scoped to DinD, not the real host |
| Access host Docker socket | ✅ | Socket is never mounted into pi-jail |
| Tamper with pi credentials | ✅ | `~/.pi/agent` is mounted read-only |

### Trade-offs

- The DinD sidecar requires `--privileged` for its own container (it runs a Docker daemon). This is standard for DinD and does not grant privileges to the pi-jail container.
- Images pulled inside DinD are stored in the DinD container's filesystem, not the host's image cache. They persist as long as the `pi-jail-dind` container exists.

## How it works

On first run, `pi-jail` builds a Docker image from an embedded Dockerfile (Node.js LTS on Debian Bookworm with `pi` and common CLI tools pre-installed). It also starts a `pi-jail-dind` sidecar container running an isolated Docker daemon. Subsequent runs reuse both. If you edit the script — for example to add packages — the image is automatically rebuilt via `md5sum` change detection.

## Prerequisites

- Docker installed and running

## Installation

Copy the script to somewhere on your `$PATH` and make it executable:

```bash
cp pi-jail ~/.local/bin/pi-jail
chmod +x ~/.local/bin/pi-jail
```

## Usage

```
pi-jail [OPTIONS] [-- ARGS...]

Options:
  -r, --rebuild    Force rebuild of the Docker image
  -s, --shell      Start a bash shell instead of pi
  -h, --help       Show this help message

Arguments after -- are passed through to pi.
```

### Examples

```bash
# Run pi interactively (builds the image on first run)
pi-jail

# Pass arguments directly to pi
pi-jail -- -p "Summarize this codebase"

# Open a shell inside the container
pi-jail --shell

# Force a full image rebuild
pi-jail --rebuild
```

If `--shell` is used while a container from the same working directory is already running, the script `docker exec`s into it rather than starting a new one.

## Configuration

### API keys

`~/.pi/agent` is mounted into the container as **read-only**, so credentials written there are available on every run without setting environment variables.

For example, to configure OpenRouter:

```bash
mkdir -p ~/.pi/agent
echo '{"openrouter":{"type":"api_key","key":"sk-or-..."}}' > ~/.pi/agent/auth.json
chmod 600 ~/.pi/agent/auth.json
```

See the pi docs for [all providers and auth file format](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/providers.md).

### Adding packages

To install extra packages into the image, edit the `CUSTOM_APT_PACKAGES` variable near the top of the script:

```bash
CUSTOM_APT_PACKAGES="jq git tmux sqlite3"
```

Save the file and the image will rebuild automatically on the next run.

## Volume mounts

| Host | Container | Mode | Purpose |
|---|---|---|---|
| `$(pwd)` | same path | read-write | Current working directory (path-mirrored for Docker compose compatibility) |
| `~/.pi/agent` | same path | **read-only** | pi configuration, sessions, extensions, skills, auth |

The Docker socket (`/var/run/docker.sock`) is **not** mounted into the pi-jail container. Docker access is provided via `DOCKER_HOST=tcp://<dind-ip>:2375` pointing to the isolated `pi-jail-dind` sidecar daemon.

All paths are mounted at their exact host paths. The container runs as the host user's UID/GID (`-u $(id -u):$(id -g)`) so mounted directories are always writable with no ownership mismatch. `HOME` is passed in explicitly so `pi` can locate `~/.pi/agent` without a matching `/etc/passwd` entry.

## DinD sidecar management

The DinD daemon runs as a long-lived container named `pi-jail-dind`. It starts automatically on the first `pi-jail` invocation and restarts unless stopped.

```bash
# Check DinD status
docker ps --filter name=pi-jail-dind

# Stop the DinD daemon
docker stop pi-jail-dind

# Remove the DinD daemon (also removes all images/containers inside it)
docker rm -f pi-jail-dind
```

## Included tools

The Docker image ships with these CLI tools alongside `pi`:

- `git` — version control
- `jq` — JSON processor
- `gh` — GitHub CLI
- `docker` CLI and `docker compose` plugin
- `curl`, `gnupg`, `build-essential`

## Testing Docker access

A `docker-compose.yml` is included to verify that `pi-jail` can reach Docker containers defined in the same directory.

Open a shell inside the `pi-jail` container from the `pi-jail` directory:

```bash
pi-jail --shell
```

From inside the container, start the test service and verify access:

```bash
# Start the test service
docker compose up -d

# List running containers — the 'hello' service should appear
docker compose ps

# Confirm the success message printed by the container
docker compose logs hello
# => hello-1  | pi-jail docker access: OK

# Exec a command directly into the running service
docker compose exec hello sh -c "echo hello from inside alpine"
# => hello from inside alpine

# Tear down
docker compose down
```

### Verifying isolation

From inside the pi-jail container, confirm that the host is not accessible:

```bash
# No Docker socket — should fail
ls -la /var/run/docker.sock
# => ls: cannot access '/var/run/docker.sock': No such file or directory

# Only compose containers visible — no host containers
docker ps -a
# => (only your compose services)

# Cannot see host filesystem even through Docker
docker run --rm -v /:/host alpine cat /host/etc/hostname
# => (shows DinD hostname, not host machine hostname)
```

## License

MIT
