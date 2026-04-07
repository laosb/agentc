#!/bin/bash
set -e

# Ensure volume-mounted user home is owned by agent
sudo chown -R agent:agent /home/agent 2>/dev/null || true

CONFIGURATIONS_DIR="/agent-isolation/agents"
CONFIGURATIONS="${CLAUDEC_CONFIGURATIONS:-claude}"

# Split comma-separated configurations into array
IFS=',' read -ra CONFIG_NAMES <<< "$CONFIGURATIONS"

# Process each configuration in order
LAST_ENTRYPOINT=""
for config_name in "${CONFIG_NAMES[@]}"; do
    config_name=$(echo "$config_name" | xargs)  # trim whitespace
    config_dir="${CONFIGURATIONS_DIR}/${config_name}"
    settings_file="${config_dir}/settings.json"

    if [ ! -f "$settings_file" ]; then
        echo "claudec: configuration '${config_name}' not found at ${settings_file}" >&2
        exit 1
    fi

    # Most user-local binaries are expected to be in ~/.local/bin, so add that to PATH by default
    export PATH="${HOME}/.local/bin:${PATH}"

    # Add additionalBinPaths to PATH
    while IFS= read -r bin_path; do
        # Expand $HOME in paths
        bin_path=$(echo "$bin_path" | sed "s|\\\$HOME|$HOME|g")
        export PATH="${bin_path}:${PATH}"
    done < <(jq -r '.additionalBinPaths[]? // empty' "$settings_file")

    # Run prepare.sh if it exists
    prepare_script="${config_dir}/prepare.sh"
    if [ -f "$prepare_script" ]; then
        echo "==> Running prepare.sh for configuration '${config_name}'..." >&2
        if ! bash "$prepare_script"; then
            echo "claudec: prepare.sh failed for configuration '${config_name}'" >&2
            exit 1
        fi
    fi

    # Read entrypoint from the last configuration
    LAST_ENTRYPOINT=$(jq -c '.entrypoint // empty' "$settings_file")
done

# Check for entrypoint override (e.g. from "claudec sh" dispatch)
if [ "${CLAUDEC_ENTRYPOINT_OVERRIDE:-}" = "1" ]; then
    exec "$@"
fi

# Execute entrypoint of last configuration with all CLI arguments appended
if [ -n "$LAST_ENTRYPOINT" ] && [ "$LAST_ENTRYPOINT" != "null" ]; then
    readarray -t ENTRYPOINT_ARGS < <(echo "$LAST_ENTRYPOINT" | jq -r '.[]')
    exec "${ENTRYPOINT_ARGS[@]}" "$@"
else
    echo "claudec: no entrypoint defined in last configuration" >&2
    exit 1
fi
