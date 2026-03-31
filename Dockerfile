# syntax=docker/dockerfile:1
FROM --platform=linux/arm64 debian:latest

# Install base system dependencies (including Swift runtime deps)
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        curl \
        wget \
        git \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        libcurl4-openssl-dev \
        libxml2 \
        libedit2 \
        libsqlite3-0 \
        libc6-dev \
        libncurses6 \
        binutils \
        libgcc-13-dev \
        libstdc++-13-dev \
        pkg-config \
        tzdata \
        unzip \
        bash \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user 'claude' with sudo privileges
RUN useradd -m -s /bin/bash -u 1000 claude \
    && echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# Install Node.js 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm 10 globally
RUN npm install -g pnpm@10

# Install Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
       $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Create docker group and add claude to it (GID is adjusted at runtime to match socket)
RUN groupadd -f docker && usermod -aG docker claude

# Create /workspace with correct ownership
RUN mkdir -p /workspace && chown claude:claude /workspace

# Entrypoint: lazily initialises home-dir tools (swiftly, Swift, Claude Code) on first
# run, since /home/claude is a volume mount that may start empty.
COPY --chmod=755 bootstrap.sh /entrypoint.sh

VOLUME ["/home/claude", "/workspace"]

USER claude
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
