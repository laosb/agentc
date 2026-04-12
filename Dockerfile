# syntax=docker/dockerfile:1
FROM buildpack-deps:scm

# buildpack-deps:scm already includes: curl, wget, git, ca-certificates,
# gnupg, openssh-client. Install the few remaining tools we need.
RUN apt-get update && apt-get install -y --no-install-recommends \
  sudo \
  jq \
  unzip
