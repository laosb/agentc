import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct MigrateFromClaudecCommand: ParsableCommand, LoggedCommand {
  @OptionGroup var logging: LoggingOptions
  static let configuration = CommandConfiguration(
    commandName: "migrate-from-claudec",
    abstract: "Migrate data from the legacy ~/.claudec directory to ~/.agentc"
  )

  func run() throws {
    let fm = FileManager.default
    let src = MigrationCheck.claudecDir
    let dst = MigrationCheck.agentcDir

    guard fm.fileExists(atPath: src.path) else {
      logger.info("No ~/.claudec directory found. Nothing to migrate.")
      return
    }

    if fm.fileExists(atPath: dst.path) {
      logger.info("~/.agentc already exists. Migration is not needed.")
      return
    }

    try fm.createDirectory(at: dst, withIntermediateDirectories: true)

    var migrated: [String] = []

    // Copy profiles
    let profilesSrc = src.appendingPathComponent("profiles")
    let profilesDst = dst.appendingPathComponent("profiles")
    if fm.fileExists(atPath: profilesSrc.path) {
      try fm.copyItem(at: profilesSrc, to: profilesDst)
      migrated.append("profiles")
    }

    // Copy configurations
    let configsSrc = src.appendingPathComponent("configurations")
    let configsDst = dst.appendingPathComponent("configurations")
    if fm.fileExists(atPath: configsSrc.path) {
      try fm.copyItem(at: configsSrc, to: configsDst)
      // Update marker file name if present
      let oldMarker = configsDst.appendingPathComponent(".claudec-last-pull")
      let newMarker = configsDst.appendingPathComponent(".agentc-last-pull")
      if fm.fileExists(atPath: oldMarker.path) {
        try fm.moveItem(at: oldMarker, to: newMarker)
      }
      migrated.append("configurations")
    }

    if migrated.isEmpty {
      logger.info("~/.claudec exists but contains no profiles or configurations to migrate.")
    } else {
      logger.info("Successfully migrated \(migrated.joined(separator: ", ")) to ~/.agentc/")
    }
    print()
    print("The original ~/.claudec directory was not modified.")
    print("To clean up, run:")
    print()
    print("  rm -rf ~/.claudec")
    print()
  }
}
