// Bootstrap binary for agentc containers.
//
// This is the default entrypoint for containers managed by agentc.
// It handles two phases:
//   Phase 1 (root): Create the agent user, configure sudo, set up
//                   directories, then drop privileges.
//   Phase 2 (agent): Process agent configurations, set up PATH, run
//                    prepare.sh scripts, then exec the entrypoint.

#if canImport(FoundationEssentials) && canImport(Musl)
  import FoundationEssentials
  import Musl

  let args = Array(CommandLine.arguments.dropFirst())

  // Recorded immediately before the exec that replaces this process, so the span
  // covers everything the bootstrap itself does — never the workload that follows.
  let bootstrapStartedAt = Diagnostics.now()
  BootstrapTiming.startedAt = bootstrapStartedAt

  do {
    if getuid() == 0 {
      try RootSetup.perform()
      // Settle profile ownership before anything else runs. When the host speaks
      // the ownership protocol this blocks until it acknowledges, so no
      // preparation script and no workload can start against a profile whose
      // ownership has not been established.
      try ProfileOwnership.settle()
      try Privileges.drop(to: "agent")
    }

    try ConfigurationRunner.run(arguments: args)
  } catch {
    Diagnostics.record(
      phase: "bootstrap.total", startedAt: bootstrapStartedAt, outcome: "failure")
    bootstrapLogger.error("\(error)")
    exit(1)
  }

  // ConfigurationRunner.run always ends with exec (replacing the process).
  // If we reach here, something went wrong.
  bootstrapLogger.error("Unexpected return from configuration runner")
  exit(1)
#endif
