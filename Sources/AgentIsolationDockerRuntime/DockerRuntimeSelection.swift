#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// MARK: - DockerRuntimeKind

/// The isolation class of a runtime registered with the Docker daemon.
///
/// Docker runtime names are administrator-defined aliases, so this is a best-effort
/// classification of an alias (and, when the daemon reports them, of the shim type and
/// binary path behind it). Anything we cannot place lands in ``unknown`` — we never
/// assume an unrecognized alias is weak *or* strong.
public enum DockerRuntimeKind: String, Sendable, Equatable, CaseIterable {
  /// Kata Containers — each container gets its own lightweight VM.
  case kata
  /// gVisor (`runsc`) — an application kernel that services syscalls in userspace.
  case gVisor
  /// `runc` and friends — containers share the host kernel.
  case standard
  /// An administrator-defined alias we cannot classify.
  case unknown

  /// Whether this kind adds an isolation boundary beyond the host kernel.
  var isHardened: Bool {
    self == .kata || self == .gVisor
  }
}

// MARK: - DockerRuntimeSelection

/// The runtime chosen for container creation, and how we arrived at it.
///
/// Produced once per ``DockerRuntime`` from the daemon's `GET /info` response (or straight
/// from configuration) and then applied to every container as `HostConfig.Runtime`.
public struct DockerRuntimeSelection: Sendable, Equatable {

  /// How the runtime was picked.
  public enum Source: Sendable, Equatable {
    /// The user named it explicitly. Taken at face value, never second-guessed.
    case configured
    /// Discovered among the daemon's registered runtimes.
    case discovered
    /// Nothing usable was discovered; the daemon's own default applies.
    case daemonDefault
  }

  /// The value to send as `HostConfig.Runtime`, or `nil` to let the daemon pick.
  public var name: String?
  public var kind: DockerRuntimeKind
  public var source: Source
  /// Registered runtime names we could not classify. Surfaced in the warning so an
  /// administrator who aliased a hardened runtime knows what to configure.
  public var unclassifiedNames: [String]

  init(
    name: String?,
    kind: DockerRuntimeKind,
    source: Source,
    unclassifiedNames: [String] = []
  ) {
    self.name = name
    self.kind = kind
    self.source = source
    self.unclassifiedNames = unclassifiedNames
  }

  // MARK: - Classification

  /// Aliases we treat as canonical for a kind, in preference order. Used to break ties
  /// when a host registers several runtimes of the same kind (e.g. `kata-qemu` + `kata-clh`).
  private static let canonicalNames: [DockerRuntimeKind: [String]] = [
    .kata: ["kata", "kata-runtime", "kata-qemu"],
    .gVisor: ["runsc", "gvisor"],
    .standard: ["runc"],
  ]

  /// Reduce a token to the runtime family it names.
  ///
  /// The same runtime shows up in `GET /info` in several spellings depending on how the
  /// administrator registered it — `kata`, `io.containerd.kata.v2`, or the shim binary at
  /// `/opt/kata/bin/containerd-shim-kata-v2` (the form Kata's own Docker guide uses).
  /// Peeling off the directory, the `containerd-shim-` wrapper, the `io.containerd.`
  /// namespace, and the trailing shim version collapses them all to `kata`.
  private static func normalize(_ token: String) -> String {
    var name = token.lowercased()

    if let slash = name.lastIndex(of: "/") {
      name = String(name[name.index(after: slash)...])
    }
    if name.hasPrefix("containerd-shim-") {
      name.removeFirst("containerd-shim-".count)
    }
    if name.hasPrefix("io.containerd.") {
      name.removeFirst("io.containerd.".count)
    }
    // Trailing shim version: `kata-v2`, `runsc.v1`.
    if let separator = name.lastIndex(where: { $0 == "-" || $0 == "." }) {
      let suffix = name[name.index(after: separator)...]
      if suffix.first == "v", suffix.dropFirst().allSatisfy(\.isNumber), suffix.count > 1 {
        name = String(name[..<separator])
      }
    }
    return name
  }

  /// Classify a single token — a runtime alias, a containerd shim type, or a binary path.
  static func classify(token: String) -> DockerRuntimeKind {
    let name = normalize(token)

    // Kata registers as `kata`/`kata-runtime`, plus per-hypervisor aliases such as
    // `kata-qemu`, `kata-clh`, `kata-fc`.
    if name == "kata" || name.hasPrefix("kata-") { return .kata }

    if name == "runsc" || name == "gvisor" || name.hasPrefix("runsc-")
      || name.hasPrefix("gvisor-")
    {
      return .gVisor
    }

    // Exact match only, so lookalikes such as `crun` and `sysbox-runc` stay unclassified
    // rather than being reported as the runtime we know to be weakest.
    if name == "runc" { return .standard }

    return .unknown
  }

  /// Classify a registered runtime, falling back to the shim type and then the binary path
  /// when the alias itself is opaque. `runsc install --runtime sandbox`, for instance,
  /// yields the alias `sandbox` with `path` pointing at the `runsc` binary.
  static func classify(name: String, entry: DockerInfo.RuntimeEntry?) -> DockerRuntimeKind {
    var kind = classify(token: name)
    if kind != .unknown { return kind }

    if let runtimeType = entry?.runtimeType, !runtimeType.isEmpty {
      kind = classify(token: runtimeType)
      if kind != .unknown { return kind }
    }

    if let path = entry?.path, !path.isEmpty {
      let binary = path.split(separator: "/").last.map(String.init) ?? path
      kind = classify(token: binary)
      if kind != .unknown { return kind }
    }

    return .unknown
  }

  // MARK: - Selection

  /// Choose a runtime: an explicit configuration wins, otherwise Kata > gVisor > `runc`.
  ///
  /// - Parameters:
  ///   - configured: An opaque, administrator-defined runtime alias from configuration.
  ///     Used verbatim without validation — Docker can invoke fully-qualified containerd
  ///     shims from the daemon's `PATH` that never appear in the registered-runtime list.
  ///   - info: The daemon's `GET /info` response, or `nil` when it could not be read.
  static func select(configured: String?, info: DockerInfo?) -> DockerRuntimeSelection {
    if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty {
      let name = configured.trimmingCharacters(in: .whitespaces)
      return .init(name: name, kind: classify(token: name), source: .configured)
    }

    // The default runtime is normally listed in `Runtimes` too, but fold it in so a daemon
    // that reports one without the other still gets classified.
    var entries: [String: DockerInfo.RuntimeEntry] = info?.Runtimes ?? [:]
    if let fallback = info?.DefaultRuntime, !fallback.isEmpty, entries[fallback] == nil {
      entries[fallback] = DockerInfo.RuntimeEntry()
    }

    guard !entries.isEmpty else {
      return .init(name: nil, kind: .unknown, source: .daemonDefault)
    }

    var byKind: [DockerRuntimeKind: [String]] = [:]
    for (name, entry) in entries {
      byKind[classify(name: name, entry: entry), default: []].append(name)
    }
    let unclassified = (byKind[.unknown] ?? []).sorted()

    for kind in [DockerRuntimeKind.kata, .gVisor, .standard] {
      guard let name = preferred(among: byKind[kind] ?? [], kind: kind) else { continue }
      return .init(
        name: name,
        kind: kind,
        source: .discovered,
        unclassifiedNames: kind == .standard ? unclassified : []
      )
    }

    // Every registered runtime is an alias we don't recognize.
    return .init(
      name: nil, kind: .unknown, source: .daemonDefault, unclassifiedNames: unclassified)
  }

  /// Pick one name out of several of the same kind: a canonical alias if present, otherwise
  /// the lexicographically first, so the choice is stable across runs.
  private static func preferred(among names: [String], kind: DockerRuntimeKind) -> String? {
    guard !names.isEmpty else { return nil }
    for canonical in canonicalNames[kind] ?? [] {
      if let match = names.first(where: { $0.lowercased() == canonical }) {
        return match
      }
    }
    return names.sorted().first
  }

  // MARK: - Warning

  /// A security warning to show the user, or `nil` when the selection needs no comment.
  ///
  /// Nothing is emitted for an explicit configuration — including an explicit `runc`, which
  /// is the documented way to silence this — or when a hardened runtime was found.
  public var warning: String? {
    guard source != .configured, !kind.isHardened else { return nil }

    var lines: [String] = []
    switch kind {
    case .standard:
      lines.append(
        """
        This Docker host only exposes the standard `runc` runtime. Because this \
        application executes custom code, we recommend installing Kata Containers or \
        gVisor for stronger workload isolation. The application will continue using \
        `runc` unless configured otherwise.
        """)
    default:
      lines.append(
        """
        Could not determine which container runtimes this Docker host provides, so the \
        daemon's default runtime will be used. If that default is the standard `runc` \
        runtime, custom code runs directly against the host kernel. We recommend \
        installing Kata Containers or gVisor for stronger workload isolation.
        """)
    }

    if !unclassifiedNames.isEmpty {
      lines.append(
        """

        This host also registers runtimes that are not recognized: \
        \(unclassifiedNames.joined(separator: ", ")). If one of them provides stronger \
        isolation, select it explicitly and it will be used as-is.
        """)
    }

    lines.append(
      """

      Setup guides:
        Kata Containers   https://github.com/kata-containers/kata-containers/blob/main/docs/installation.md
        gVisor / runsc    https://gvisor.dev/docs/user_guide/quick_start/docker/
        Docker runtimes   https://docs.docker.com/engine/daemon/alternative-runtimes/
        dockerd reference https://docs.docker.com/reference/cli/dockerd/

      To choose a runtime — and to silence this warning, including when you have decided \
      `runc` is fine — pass `--docker-runtime <name>` or set `"docker": {"runtime": \
      "<name>"}` in .agentc/settings.json. For example: `--docker-runtime runc`.
      """)

    return lines.joined(separator: "\n")
  }
}
