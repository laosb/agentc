import FoundationEssentials
import Musl

enum RootSetup {
  static func perform() throws {
    try createAgentUser()
    configureSudo()
    createDirectories()
  }

  private static func createAgentUser() throws {
    // Skip if agent user already exists.
    guard getpwnam("agent") == nil else { return }

    let shell = access("/bin/bash", X_OK) == 0 ? "/bin/bash" : "/bin/sh"

    if Helpers.commandExists("useradd") {
      // Debian/Ubuntu: -d sets home without creating it (no -m).
      try Helpers.run(
        command: "useradd",
        arguments: ["-d", "/home/agent", "-s", shell, "-u", "1000", "agent"])
    } else if Helpers.commandExists("adduser") {
      // Alpine/BusyBox: -H prevents creating the home directory.
      try Helpers.run(
        command: "adduser",
        arguments: [
          "-D", "-h", "/home/agent", "-s", shell, "-u", "1000", "-H", "agent",
        ])
    } else {
      throw BootstrapError.setupFailed(
        "No useradd or adduser command found")
    }
  }

  private static func configureSudo() {
    Helpers.mkdirp("/etc/sudoers.d")
    let url = URL(fileURLWithPath: "/etc/sudoers.d/agent")
    try? Data("agent ALL=(ALL) NOPASSWD:ALL\n".utf8).write(to: url)
    chmod("/etc/sudoers.d/agent", 0o440)
  }

  private static func createDirectories() {
    Helpers.mkdirp("/workspace")
    Helpers.mkdirp("/agent-isolation")

    guard let pw = getpwnam("agent") else { return }
    let uid = pw.pointee.pw_uid
    let gid = pw.pointee.pw_gid
    chown("/workspace", uid, gid)
    chown("/agent-isolation", uid, gid)
    Helpers.chownRecursive("/home/agent", uid: uid, gid: gid)
  }
}
