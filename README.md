# aia-jail

A single-file Bash launcher that runs the [`aia`](https://github.com/MadBomber/aia) AI assistant CLI inside a Docker sandbox. Ruby and all gem dependencies stay off your host machine, and `aia` only has access to the directory from which `aia-jail` is launched — plus any Docker containers defined within that same directory.

## How it works

On first run, `aia-jail` builds a Docker image from an embedded Dockerfile (Ruby 3.3 on Debian Bookworm with `aia` and common CLI tools pre-installed). Subsequent runs reuse the image. If you edit the script — for example to add packages — the image is automatically rebuilt via `md5sum` change detection.

## Prerequisites

- Docker installed and running
- `jq` installed on the host (used for OpenRouter key auto-detection)

## Installation

Copy the script to somewhere on your `$PATH` and make it executable:

```bash
cp aia-jail ~/.local/bin/aia-jail
chmod +x ~/.local/bin/aia-jail
```

## Usage

```
aia-jail [OPTIONS] [-- ARGS...]

Options:
  -r, --rebuild    Force rebuild of the Docker image
  -s, --shell      Start a bash shell instead of aia
  -h, --help       Show this help message

Arguments after -- are passed through to aia.
```

### Examples

```bash
# Run aia interactively (builds image on first run)
aia-jail -- --chat

# Pass arguments directly to aia
aia-jail -- --model claude-3-5-sonnet "Tell me a joke"

# Open a shell inside the container
aia-jail --shell

# Force a full image rebuild
aia-jail --rebuild
```

If `--shell` is used while a container from the same working directory is already running, the script `docker exec`s into it rather than starting a new one.

## Configuration

### API keys

Set at least one provider key before running:

| Variable | Provider |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` | OpenAI (GPT) |
| `GOOGLE_API_KEY` | Google (Gemini) |
| `OPEN_ROUTER_API_KEY` | OpenRouter |

If `OPEN_ROUTER_API_KEY` is not set but `~/.local/share/opencode/auth.json` exists, the key is read from it automatically — so credentials are shared seamlessly with [OpenCode](https://opencode.ai).

### Adding packages

To install extra packages into the image, edit the `CUSTOM_APT_PACKAGES` variable near the top of the script:

```bash
CUSTOM_APT_PACKAGES="git tmux sqlite3"
```

Save the file and the image will rebuild automatically on the next run.

## Volume mounts

The following host paths are mounted into every container:

| Host | Container | Purpose |
|---|---|---|
| `$(pwd)` | same path | Current working directory (path-mirrored for Docker-in-Docker compatibility) |
| `~/.prompts` | `/home/aia/.prompts` | aia prompt files |
| `~/.config/aia` | `/home/aia/.config/aia` | aia configuration |
| `~/.local/share/opencode` | `/home/aia/.local/share/opencode` | OpenCode data and auth |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket (enables Docker-in-Docker) |

The current directory is mounted at its exact host path so that any nested `docker` or `docker compose` commands launched from inside `aia` resolve volume paths correctly on the host.

## Included tools

The Docker image ships with these CLI tools alongside `aia`:

- `ripgrep` — fast file content search
- `fzf` — fuzzy finder
- `gh` — GitHub CLI
- `docker` CLI and `docker compose` plugin
- `openssh-client`, `dnsutils`, `jq`, `curl`, `build-essential`

## Testing Docker access

A `docker-compose.yml` is included to verify that `aia-jail` can reach Docker containers defined in the same directory.

From the `aia-jail` directory, start the test service in the background:

```bash
docker compose up -d
```

Then open a shell inside the `aia-jail` container from the same directory:

```bash
aia-jail --shell
```

From inside the container, confirm the service is visible and its log output is accessible:

```bash
# List running containers — the 'hello' service should appear
docker compose ps

# Confirm the success message printed by the container
docker compose logs hello
# => hello-1  | aia-jail docker access: OK

# Exec a command directly into the running service
docker compose exec hello sh -c "echo hello from inside alpine"
# => hello from inside alpine
```

When done, tear the service down:

```bash
docker compose down
```

## License

See [LICENSE](LICENSE) if present, or check the repository for details.
