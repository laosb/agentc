import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct ConfigsCommand: AsyncParsableCommand, LoggedCommand {
  @OptionGroup var logging: LoggingOptions

  static let configuration = CommandConfiguration(
    commandName: "configs",
    abstract: "Inspect and update local agent configurations",
    discussion: """
      Agent configurations are stored under `~/.agentc/configurations/` and \
      automatically refreshed periodically when starting a session.

      Examples:
        agentc configs                     # inspect repo URL, commit, and staleness
        agentc configs status              # same as above
        agentc configs update              # clone or pull the latest configurations
      """,
    subcommands: [
      ConfigsStatusCommand.self,
      ConfigsUpdateCommand.self,
    ],
    defaultSubcommand: ConfigsStatusCommand.self
  )
}

struct ConfigsStatusCommand: AsyncParsableCommand, LoggedCommand {
  @OptionGroup var logging: LoggingOptions

  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show the current configurations repository URL, commit, and update status"
  )

  @Option(
    name: .long,
    help: "Path to the local configurations directory (default: ~/.agentc/configurations)."
  )
  var configurationsDir: String?

  @Option(
    name: .long,
    help: "Seconds before configurations are considered stale when offline (default: 86400)."
  )
  var configurationsUpdateInterval: Int?

  mutating func run() async throws {
    let dir = ConfigurationsManager.resolveDirectory(explicit: configurationsDir)
    if logging.verbose {
      logger.debug("Checking configurations status in \(dir.path)")
    }
    let status = await ConfigurationsManager.status(
      at: dir,
      updateInterval: configurationsUpdateInterval
    )

    guard status.isCloned else {
      print("path:          \(status.directory.path) (not cloned)")
      print("repo:          \(ConfigurationsManager.defaultRepo) (default)")
      print("status:        not cloned")
      print()
      print("Run `agentc configs update` to clone the configurations repository.")
      return
    }

    print("path:          \(status.directory.path)")
    print("repo:          \(status.repoURL ?? "(none)")")
    if let commit = status.localCommit {
      let hash = logging.verbose ? commit.revision : commit.shortRevision
      if let subject = commit.subject, !subject.isEmpty {
        print("commit:        \(hash) (\(subject))")
      } else {
        print("commit:        \(hash)")
      }
      if let committedAt = commit.committedAt {
        print("committed:     \(committedAt)")
      }
    } else {
      print("commit:        (unknown)")
    }

    if let lastUpdated = status.lastUpdated {
      print("lastUpdated:   \(lastUpdated.formatted(.iso8601))")
    } else {
      print("lastUpdated:   (unknown)")
    }

    switch status.freshness {
    case .notCloned:
      print("status:        not cloned")
      print()
      print("Run `agentc configs update` to clone the configurations repository.")
    case .upToDate:
      print("status:        up to date")
    case .staleRemote(let remoteRevision):
      let remoteHash = logging.verbose ? remoteRevision : String(remoteRevision.prefix(7))
      print("remoteCommit:  \(remoteHash)")
      print("status:        stale (remote is at \(remoteHash))")
      print()
      print("Run `agentc configs update` to update.")
    case .staleLocal(let remoteError):
      if logging.verbose, let remoteError {
        logger.debug("Remote check failed: \(remoteError)")
      }
      if status.lastUpdated == nil {
        print("status:        stale (unable to reach remote; last update time unknown)")
      } else {
        print("status:        stale (unable to reach remote; update interval elapsed)")
      }
      print()
      print("Run `agentc configs update` to update.")
    case .remoteUnavailable(let remoteError):
      if logging.verbose, let remoteError {
        logger.debug("Remote check failed: \(remoteError)")
      }
      print("status:        unknown (unable to reach remote)")
    }
  }
}

struct ConfigsUpdateCommand: AsyncParsableCommand, LoggedCommand {
  @OptionGroup var logging: LoggingOptions

  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Update the local agent configurations repository"
  )

  @Option(
    name: .long,
    help: "Path to the local configurations directory (default: ~/.agentc/configurations)."
  )
  var configurationsDir: String?

  @Option(
    name: .long,
    help: "Git repo URL for agent configurations."
  )
  var configurationsRepo: String?

  mutating func run() async throws {
    let dir = ConfigurationsManager.resolveDirectory(explicit: configurationsDir)
    if logging.verbose {
      logger.debug("Updating configurations in \(dir.path)")
    }
    let result = try await ConfigurationsManager.updateRepo(
      at: dir,
      repoURL: configurationsRepo
    )
    switch result {
    case .cloned(let revision):
      if let short = shortRevision(revision) {
        logger.info("Cloned configurations (\(short)) to \(dir.path).")
      } else {
        logger.info("Cloned configurations to \(dir.path).")
      }
    case .updated(let from, let to):
      if let fromShort = shortRevision(from), let toShort = shortRevision(to) {
        logger.info("Updated configurations (\(fromShort) -> \(toShort)).")
      } else {
        logger.info("Updated configurations.")
      }
    case .upToDate(let revision):
      if let short = shortRevision(revision) {
        logger.info("Configurations are already up to date (\(short)).")
      } else {
        logger.info("Configurations are already up to date.")
      }
    }
  }

  private func shortRevision(_ revision: String?) -> String? {
    guard let revision, !revision.isEmpty else { return nil }
    return String(revision.prefix(7))
  }
}
