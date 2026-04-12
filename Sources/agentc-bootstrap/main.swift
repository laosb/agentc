// Bootstrap binary for agentc containers.
//
// This is the default entrypoint for containers managed by agentc.
// It handles two phases:
//   Phase 1 (root): Create the agent user, configure sudo, set up
//                   directories, then drop privileges.
//   Phase 2 (agent): Process agent configurations, set up PATH, run
//                    prepare.sh scripts, then exec the entrypoint.

import FoundationEssentials
import Musl

let args = Array(CommandLine.arguments.dropFirst())

do {
  if getuid() == 0 {
    try RootSetup.perform()
    try Privileges.drop(to: "agent")
  }

  try ConfigurationRunner.run(arguments: args)
} catch {
  fputs("agentc-bootstrap: \(error)\n", stderr)
  exit(1)
}

// ConfigurationRunner.run always ends with exec (replacing the process).
// If we reach here, something went wrong.
fputs("agentc-bootstrap: unexpected return from configuration runner\n", stderr)
exit(1)
