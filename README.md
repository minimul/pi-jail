# pi-jail

A single-file Bash launcher that runs the [`pi`](https://github.com/badlogic/pi-mono) coding agent CLI (`@mariozechner/pi-coding-agent`) inside a Docker sandbox. Node.js and npm dependencies stay off your host machine, and `pi` only has access to the directory from which `pi-jail` is launched — plus any Docker containers defined within that same directory.

## How it works

On first run, `pi-jail` builds a Docker image from an embedded Dockerfile (Node.js LTS on Debian Bookworm with `pi` and common CLI tools pre-installed). Subsequent runs reuse the image. If you edit the script — for example to add packages — the image is automatically rebuilt via `md5sum` change detection.

## Prerequisites

- Docker installed and running
- `jq` installed on the host (used for OpenRouter key auto-detection)

## Installation

Copy the `pi-jail` script to somewhere on your `$PATH` and make it executable:

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

See the `pi` docs for setting up a model subscription.

For OpenRouter do this:

```sh
echo '{"openrouter":{"type":"api_key","key":"sk-or-..."}}' > ~/.pi/agent/auth.json
```


### Adding packages

To install extra packages into the image, edit the `CUSTOM_APT_PACKAGES` variable near the top of the script:

```bash
CUSTOM_APT_PACKAGES="git tmux sqlite3"
```

Save the file and the image will rebuild automatically on the next run.

## Volume mounts

| Host | Container | Purpose |
|---|---|---|
| `$(pwd)` | same path | Current working directory (path-mirrored for Docker-in-Docker compatibility) |
| `~/.pi/agent` | same path | pi configuration, sessions, extensions, skills |
| `~/.local/share/opencode` | same path | OpenCode data and auth |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket (enables Docker-in-Docker) |

All host paths are mounted at their exact host paths. The container runs as the host user's UID/GID (`-u $(id -u):$(id -g)`) so mounted directories are always writable with no ownership mismatch. `HOME` is passed in explicitly so `pi` can locate `~/.pi/agent` without a matching `/etc/passwd` entry.

## Included tools

The Docker image ships with these CLI tools alongside `pi`:

- `ripgrep` — fast file content search
- `fzf` — fuzzy finder
- `git` — version control
- `gh` — GitHub CLI
- `docker` CLI and `docker compose` plugin
- `openssh-client`, `dnsutils`, `jq`, `curl`, `build-essential`

## Testing Docker access

A `docker-compose.yml` is included to verify that `pi-jail` can reach Docker containers defined in the same directory.

From the `pi-jail` directory, start the test service in the background:

```bash
docker compose up -d
```

Then open a shell inside the `pi-jail` container from the same directory:

```bash
pi-jail --shell
```

From inside the container, confirm the service is visible and its log output is accessible:

```bash
# List running containers — the 'hello' service should appear
docker compose ps

# Confirm the success message printed by the container
docker compose logs hello
# => hello-1  | pi-jail docker access: OK

# Exec a command directly into the running service
docker compose exec hello sh -c "echo hello from inside alpine"
# => hello from inside alpine
```

When done, tear the service down:

```bash
docker compose down
```

## License

MIT
