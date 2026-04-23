import AgentIsolation
import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct ProfilesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profiles",
    abstract: "List, inspect, and remove agentc profiles",
    discussion: """
      Profiles are stored under `~/.agentc/profiles/<name>/`.  A profile's `home` \
      subdirectory is mounted into the container as `/home/agent`.

      Examples:
        agentc profiles                    # list all profiles
        agentc profiles list               # same as above
        agentc profiles remove work        # delete the "work" profile
        agentc profiles rm work            # same, shorter alias
      """,
    subcommands: [
      ProfilesListCommand.self,
      ProfilesRemoveCommand.self,
    ],
    defaultSubcommand: ProfilesListCommand.self
  )
}

// MARK: - Shared storage resolution

extension ProfilesCommand {
  /// Resolve the profiles storage directory, honoring `--profiles-dir` when given.
  static func resolveStorageDirectory(explicit: String?) -> URL {
    if let explicit, !explicit.isEmpty {
      return URL(fileURLWithPath: explicit)
    }
    return MigrationCheck.homeDir.appendingPathComponent(".agentc/profiles")
  }

  /// Format a byte count into a short human-readable string (e.g. "2.3 MiB").
  static func formatSize(_ bytes: Int64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    if unit == 0 {
      return "\(Int64(value)) \(units[unit])"
    }
    return String(format: "%.1f %@", value, units[unit])
  }

  static func formatDate(_ date: Date) -> String {
    date.formatted(.iso8601)
  }
}

// MARK: - list

struct ProfilesListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List profiles in the profiles storage folder"
  )

  @Option(
    name: .customLong("profiles-dir"),
    help: "Profiles storage directory (default: ~/.agentc/profiles)."
  )
  var profilesDir: String?

  @Flag(name: .long, help: "Print detailed information for each profile.")
  var verbose: Bool = false

  @Argument(help: "Optional profile name to inspect.  When set, prints just that profile's details.")
  var name: String?

  mutating func run() async throws {
    let storage = ProfilesCommand.resolveStorageDirectory(explicit: profilesDir)
    let manager = ProfileManager(storageDirectory: storage)

    if let name {
      let details = try manager.inspect(name: name)
      printDetails(details)
      return
    }

    let profiles = try manager.list()
    if profiles.isEmpty {
      print("No profiles found in \(storage.path).")
      return
    }

    if verbose {
      for (i, info) in profiles.enumerated() {
        if i > 0 { print() }
        let details = try manager.inspect(name: info.name)
        printDetails(details)
      }
    } else {
      for info in profiles {
        print(info.name)
      }
    }
  }

  private func printDetails(_ details: ProfileDetails) {
    print("name:          \(details.name)")
    print("path:          \(details.path.path)")
    print("home:          \(details.homeDirectory.path)\(details.homeDirectoryExists ? "" : " (missing)")")
    print("size:          \(ProfilesCommand.formatSize(details.sizeBytes))")
    if let modified = details.lastModified {
      print("lastModified:  \(ProfilesCommand.formatDate(modified))")
    } else {
      print("lastModified:  (unknown)")
    }
  }
}

// MARK: - remove / rm

struct ProfilesRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Delete a profile and all of its data",
    aliases: ["rm"]
  )

  @Option(
    name: .customLong("profiles-dir"),
    help: "Profiles storage directory (default: ~/.agentc/profiles)."
  )
  var profilesDir: String?

  @Flag(name: .shortAndLong, help: "Do not error out when the profile does not exist.")
  var force: Bool = false

  @Argument(help: "Name(s) of the profile(s) to delete.")
  var names: [String]

  mutating func run() async throws {
    guard !names.isEmpty else {
      writeToStderr("agentc: profiles remove: at least one profile name is required.\n")
      throw ExitCode(2)
    }

    let storage = ProfilesCommand.resolveStorageDirectory(explicit: profilesDir)
    let manager = ProfileManager(storageDirectory: storage)

    var failed = false
    for name in names {
      do {
        try manager.delete(name: name)
        print("agentc: removed profile \"\(name)\"")
      } catch ProfileManagerError.profileNotFound {
        if force {
          continue
        }
        writeToStderr("agentc: profile \"\(name)\" does not exist in \(storage.path).\n")
        failed = true
      } catch ProfileManagerError.invalidProfileName(let raw) {
        writeToStderr("agentc: invalid profile name \"\(raw)\".\n")
        failed = true
      }
    }

    if failed {
      throw ExitCode(1)
    }
  }
}
