# Project Settings

`agentc` supports per-project configuration via a `settings.json` file placed in an `.agentc/` folder. This lets you commit default agent settings alongside your project so every team member (and CI) gets the same configuration without extra CLI flags.

## Quick Start

Create `.agentc/settings.json` in your project root:

```json
{
  "agent": {
    "image": "my-org/dev-image:latest",
    "configurations": ["claude"],
    "cpus": 4,
    "memoryMiB": 4096,
    "excludes": ["node_modules", ".git"]
  }
}
```

Then run `agentc` from anywhere inside the project tree — the settings are automatically discovered.

## How Settings Are Found

When `agentc` is invoked, it searches for a settings file starting from the current working directory and walking upward through parent directories until the filesystem root. At each directory level it checks for `settings.json` inside candidate folders. The first valid settings file found wins; the search does not continue further.

You can override this search by specifying the folder path directly:

```sh
agentc run --agentc-folder /path/to/settings-folder
```

When `--agentc-folder` is used, no upward directory search is performed; the settings file is loaded from the given folder.

## Settings Schema

All fields are optional. Only the values you specify take effect.

```json
{
  "agent": {
    "image": "<string>",
    "profile": "<string>",
    "excludes": ["<string>", ...],
    "configurations": ["<string>", ...],
    "additionalMounts": ["<string>", ...],
    "defaultArguments": ["<string>", ...],
    "additionalArguments": ["<string>", ...],
    "cpus": "<int>",
    "memoryMiB": "<int>",
    "bootstrap": "<string>",
    "respectImageEntrypoint": "<bool>"
  }
}
```

### Field Reference

| Field | CLI Equivalent | Description |
|---|---|---|
| `agent.image` | `--image`, `-i` | Default container image reference. |
| `agent.profile` | `--profile`, `-p` | Default profile name. |
| `agent.excludes` | `--exclude` | Workspace sub-folders to mask with empty overlays. |
| `agent.configurations` | `--configurations`, `-c` | Agent configuration names to activate. |
| `agent.additionalMounts` | `--additional-mount` | Additional host directories to mount. |
| `agent.defaultArguments` | positional args after `--` | Default arguments passed to the entrypoint. |
| `agent.additionalArguments` | *(none)* | Arguments always appended to entrypoint args. |
| `agent.cpus` | `--cpus` | Number of CPUs to allocate. |
| `agent.memoryMiB` | `--memory-mib` | Container memory limit in MiB. |
| `agent.bootstrap` | `--bootstrap` | Path to a custom bootstrap/entrypoint script. |
| `agent.respectImageEntrypoint` | `--respect-image-entrypoint` | Use the image's built-in entrypoint. |

### Override and Merge Rules

When both CLI flags and project settings specify a value, the behavior depends on the field:

**Override** (CLI wins, project settings used as fallback):

- `image`, `profile`, `configurations`, `cpus`, `memoryMiB`, `bootstrap`, `respectImageEntrypoint`

**Merge** (both sets are combined):

- `excludes` — CLI and project excludes are all applied.
- `additionalMounts` — CLI and project mounts are all mounted.

**Arguments have special handling:**

- `defaultArguments` — Used when no CLI positional arguments are given. If the user passes arguments after `--`, those replace `defaultArguments` entirely.
- `additionalArguments` — Always appended to whatever arguments are in effect (whether from CLI or `defaultArguments`).

### Priority Chain

For fields with override behavior, the full priority chain is:

1. CLI flag (highest priority)
2. Project settings (`settings.json`)
3. Profile settings (`~/.agentc/profiles/<name>/settings.json`) — only for `configurations`
4. Built-in default (lowest priority)

## Examples

### Minimal: Set a Default Image

```json
{
  "agent": {
    "image": "ghcr.io/my-org/dev:latest"
  }
}
```

### Team Project with Resource Limits

```json
{
  "agent": {
    "image": "ghcr.io/my-org/dev:latest",
    "configurations": ["claude", "copilot"],
    "cpus": 4,
    "memoryMiB": 8192,
    "excludes": ["node_modules", ".git", "dist"],
    "additionalArguments": ["--model", "opus"]
  }
}
```

### Use Image Entrypoint (No Bootstrap)

```json
{
  "agent": {
    "image": "my-custom-agent:latest",
    "respectImageEntrypoint": true
  }
}
```
