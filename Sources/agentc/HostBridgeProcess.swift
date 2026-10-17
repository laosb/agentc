import HostBridge

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

/// The child and its pipes belong exclusively to one broker worker.
final class HostBridgeProcess {
  let pid: pid_t
  private var input: Int32
  private var output: Int32
  private var errorOutput: Int32
  private var reaped = false

  init(command: String, arguments: [String], environment: [String: String], cwd: String) throws {
    var opened: [Int32] = []
    defer { for fd in opened { close(fd) } }
    let stdin = try BridgePOSIX.pipe()
    opened += [stdin.read, stdin.write]
    let stdout = try BridgePOSIX.pipe()
    opened += [stdout.read, stdout.write]
    let stderr = try BridgePOSIX.pipe()
    opened += [stderr.read, stderr.write]
    #if canImport(Darwin)
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
    #else
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
    #endif
    func check(_ code: Int32) throws {
      guard code == 0 else { throw BridgeError("Host spawn: \(String(cString: strerror(code)))") }
    }
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    for (from, to) in [
      (stdin.read, STDIN_FILENO), (stdout.write, STDOUT_FILENO), (stderr.write, STDERR_FILENO),
    ] {
      try check(posix_spawn_file_actions_adddup2(&actions, from, to))
    }
    for fd in opened { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
    try check(posix_spawn_file_actions_addchdir_np(&actions, cwd))
    var mask = sigset_t()
    sigemptyset(&mask)
    try check(posix_spawnattr_setsigmask(&attributes, &mask))
    sigfillset(&mask)
    try check(posix_spawnattr_setsigdefault(&attributes, &mask))
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    #if canImport(Darwin)
      flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    try check(posix_spawnattr_setflags(&attributes, flags))
    let strings = ([command] + arguments).map { strdup($0)! }
    let variables = environment.map { strdup("\($0.key)=\($0.value)")! }
    defer { for pointer in strings + variables { free(pointer) } }
    var argv: [UnsafeMutablePointer<CChar>?] = strings + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = variables + [nil]
    var child: pid_t = 0
    try check(posix_spawn(&child, command, &actions, &attributes, &argv, &envp))
    pid = child
    input = stdin.write
    output = stdout.read
    errorOutput = stderr.read
    opened = [stdin.read, stdout.write, stderr.write]
    do {
      for fd in [input, output, errorOutput] { try BridgePOSIX.nonblocking(fd) }
      #if canImport(Darwin)
        guard fcntl(input, F_SETNOSIGPIPE, 1) == 0 else {
          throw BridgePOSIX.error("F_SETNOSIGPIPE")
        }
      #endif
    } catch {
      kill(-pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      close(input)
      close(output)
      close(errorOutput)
      throw error
    }
  }

  deinit {
    for fd in [input, output, errorOutput] where fd >= 0 { close(fd) }
    if !reaped {
      // Keep the leader unreaped until the final group signal, preventing PID
      // reuse while cleaning up children that inherited its process group.
      kill(-pid, SIGTERM)
      usleep(200_000)
      kill(-pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
  }

  func relay(_ connection: BridgeConnection) throws {
    var pendingInput = Data()
    var credit = true
    var inputEOF = false
    var status: Int32?
    try connection.enqueue(.init(.stdinReady))
    while true {
      // waitid(WNOWAIT) observes exit without releasing the leader's PID until
      // its process group has been cleaned up and buffered output drained.
      if status == nil {
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 && errno != EINTR {
          throw BridgePOSIX.error("waitid")
        }
        #if canImport(Darwin)
          let ended = info.si_pid == pid
        #else
          // Linux's siginfo union fields aren't exposed consistently by Swift.
          // For this PID-only WEXITED query, a nonzero SIGCHLD report means exit.
          let ended = info.si_signo == SIGCHLD
        #endif
        if ended {
          kill(-pid, SIGKILL)
          var value: Int32 = 0
          var waited: pid_t
          repeat { waited = waitpid(pid, &value, 0) } while waited < 0 && errno == EINTR
          guard waited == pid else { throw BridgePOSIX.error("waitpid") }
          reaped = true
          status = value
          if input >= 0 {
            close(input)
            input = -1
          }
          pendingInput.removeAll()
        }
      }
      if let status, output < 0, errorOutput < 0 {
        let signalNumber = status & 0x7f
        let result = BridgeTermination(
          code: signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber,
          signal: signalNumber == 0
            ? nil : BridgePOSIX.signals.first(where: { $0.1 == signalNumber })?.0)
        try connection.enqueue(.init(.exit, JSONEncoder().encode(result)))
        // Still cancellable by broker shutdown, even if the peer stops reading.
        while !connection.output.isEmpty {
          var fds = [pollfd(fd: connection.fd, events: Int16(POLLOUT), revents: 0)]
          try BridgePOSIX.poll(&fds)
          if fds[0].revents != 0 { try connection.flush() }
        }
        return
      }
      let canReadOutput = connection.output.count < 64 * 1024
      var fds = [
        pollfd(
          fd: connection.fd,
          events: Int16(POLLIN) | (connection.output.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
        pollfd(fd: pendingInput.isEmpty ? -1 : input, events: Int16(POLLOUT), revents: 0),
        pollfd(fd: canReadOutput ? output : -1, events: Int16(POLLIN), revents: 0),
        pollfd(fd: canReadOutput ? errorOutput : -1, events: Int16(POLLIN), revents: 0),
      ]
      try BridgePOSIX.poll(&fds)
      if fds[0].revents & Int16(POLLOUT) != 0 { try connection.flush() }
      if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        for frame in try connection.receive() {
          switch frame.kind {
          case .stdin, .stdinEOF:
            guard credit, !inputEOF, pendingInput.isEmpty,
              frame.kind != .stdinEOF || frame.data.isEmpty
            else {
              throw BridgeError("Host bridge stdin credit exceeded")
            }
            credit = false
            if frame.kind == .stdinEOF {
              inputEOF = true
              if input >= 0 {
                close(input)
                input = -1
              }
            } else if input >= 0 {
              pendingInput = frame.data
            }
          case .signal:
            guard
              let number = BridgePOSIX.signals.first(where: {
                $0.0 == String(decoding: frame.data, as: UTF8.self)
              })?.1
            else { throw BridgeError("Unsupported host bridge signal") }
            if status == nil { kill(-pid, number) }
          default: throw BridgeError("Unexpected host bridge request")
          }
        }
      }
      if fds[1].revents != 0 && input >= 0 {
        do { try BridgePOSIX.write(input, buffer: &pendingInput) } catch {
          if errno != EPIPE { throw error }
          close(input)
          input = -1
          pendingInput.removeAll()
        }
      }
      if !credit && !inputEOF && pendingInput.isEmpty && input >= 0 {
        credit = true
        try connection.enqueue(.init(.stdinReady))
      }
      for index in [2, 3] where fds[index].revents != 0 {
        let fd = index == 2 ? output : errorOutput
        if let data = try BridgePOSIX.read(fd) {
          if data.isEmpty {
            close(fd)
            if index == 2 { output = -1 } else { errorOutput = -1 }
          } else {
            try connection.enqueue(.init(index == 2 ? .stdout : .stderr, data))
          }
        }
      }
    }
  }
}
