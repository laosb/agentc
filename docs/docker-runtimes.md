# Safer Docker Isolation

AI agents run code you did not write. Standard Docker containers use the host kernel, so a
container escape can expose the host. `agentc` reduces that risk by automatically choosing
the strongest runtime registered with Docker:

1. **Kata Containers** — runs each container in a lightweight VM with its own kernel.
2. **gVisor (`runsc`)** — handles container system calls in a userspace application kernel.
3. **`runc`** — standard Docker isolation, which shares the host kernel.

If only `runc` is available, `agentc` uses it and prints a warning. If Docker's runtimes
cannot be identified, it uses the daemon's default and warns. Unrecognized runtime names are
included so you can select a hardened custom runtime yourself.

## Choose a runtime

Override automatic selection on the command line:

```sh
agentc run --docker-runtime kata
agentc run --docker-runtime runsc
agentc run --docker-runtime runc
```

Or set it for a project in `.agentc/settings.json`:

```json
{
  "docker": {
    "runtime": "runsc"
  }
}
```

The name is passed directly to Docker, so custom aliases and containerd shim names work too.
Choosing a runtime explicitly suppresses the warning; use `runc` only when sharing the host
kernel is acceptable for your environment.

## No silent fallback

If Docker rejects the selected runtime, `agentc` stops and reports the error. It never retries
with a weaker runtime, so a broken Kata or gVisor installation cannot silently remove the
isolation boundary you expected.

To add a hardened runtime, see the installation guides for
[Kata Containers](https://github.com/kata-containers/kata-containers/blob/main/docs/installation.md)
or [gVisor](https://gvisor.dev/docs/user_guide/quick_start/docker/).

This setting applies only to the Docker backend. The Apple Container backend already runs
each container in its own VM.
