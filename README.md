# claudec

Run [Claude Code](https://claude.ai/claude-code) inside an Apple [`container`](https://apple.github.io/container/), with persistent profiles and per-project memory isolation, while isolating the rest of your system from Claude Code's access.

(This is mostly vibe-coded for my own use case, just to set expectations. Contributions are very welcome though!)

## Requirements

- macOS 15+ (Due to Apple `container` requirements)
- Apple `container` CLI installed and running

## Installation

**1. Install the `container` CLI**

Follow the official Apple instructions to install and start the `container` daemon. The easiest way is `brew install container`. Other than Apple `container`, there should be nothing Apple-specific in the main script. More container runtime support contributions are welcome!

**2. Install `claudec`**

It's a simple shell script, so clone the repo and symlink it is enough:

```sh
git clone https://github.com/laosb/claudec.git
ln -s "$PWD/claudec/claudec" /usr/local/bin/claudec
```

## Usage

```sh
# Start Claude Code in the current directory
claudec

# Pass arguments to Claude Code
claudec --help
claudec "explain this codebase"

# Open a shell in the container (for debugging or manual setup)
claudec sh
```

On first run, the container will install swiftly, a Swift toolchain, and Claude Code into the profile directory. Subsequent runs skip this and start immediately. This behavior is designed for my own usage, but you can modify [Dockerfile](./Dockerfile) to build a custom image with everything you use pre-installed if you prefer.

### Profiles

A profile is a persistent `/home/claude` that survives container restarts. Profiles let you maintain separate Claude Code authentication, memory, and settings per context (e.g. work vs. personal).

```sh
# Use the "work" profile
CLAUDEC_PROFILE=work claudec

# Or set it for your whole session
export CLAUDEC_PROFILE=work
claudec
```

Profiles are stored at `~/.claudec/profiles/<name>/`.

### Project memory isolation

Each workspace is mounted at `/workspace/<sha256 of canonical path>` inside the container. This ensures Claude Code keeps separate project memory for each directory, even across symlinks or different relative paths to the same location.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDEC_PROFILE` | `default` | Profile name. Maps to `~/.claudec/profiles/<name>`. |
| `CLAUDEC_PROFILE_DIR` | `~/.claudec/profiles/<CLAUDEC_PROFILE>` | Full path to the profile directory. Overrides `CLAUDEC_PROFILE`. |
| `CLAUDEC_IMAGE` | `ghcr.io/laosb/claudec:latest` | Container image to use. |
| `CLAUDEC_WORKSPACE` | `$PWD` | Host directory to mount as the workspace. |

## Building the image yourself

```sh
git clone https://github.com/laosb/claudec.git
cd claudec
docker build -t claudec .
CLAUDEC_IMAGE=claudec claudec
```
