# syntax=docker/dockerfile:1
FROM debian:latest

# Install base developer tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        curl \
        wget \
        git \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        tzdata \
        unzip \
        bash \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user 'agent' with sudo privileges
RUN useradd -m -s /bin/bash -u 1000 agent \
    && echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

# Create /workspace and /agent-isolation with correct ownership
RUN mkdir -p /workspace /agent-isolation && chown agent:agent /workspace /agent-isolation

# Entrypoint: processes agent configurations and runs the final entrypoint.
COPY --chmod=755 bootstrap.sh /entrypoint.sh

VOLUME ["/home/agent", "/workspace"]

USER agent
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
