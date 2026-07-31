#if ContainerRuntimeAppleContainer
  @testable import AgentIsolationAppleContainerRuntime
  import Testing

  // MARK: - Environment Merge Unit Tests

  @Suite("AppleContainerRuntime Environment Merge")
  struct AppleContainerEnvironmentTests {

    /// Parse a merged entry list back into names → values for order-independent checks.
    private func parsed(_ entries: [String]) -> [String: String] {
      var result: [String: String] = [:]
      for entry in entries {
        guard let separator = entry.firstIndex(of: "=") else { continue }
        let name = String(entry[..<separator])
        // First occurrence wins, mirroring `getenv` on a duplicated `environ`.
        if result[name] == nil {
          result[name] = String(entry[entry.index(after: separator)...])
        }
      }
      return result
    }

    // MARK: - Pass-through

    @Test("Image defaults are unchanged when there are no overrides")
    func noOverridesKeepsImageDefaults() {
      let defaults = ["PATH=/usr/bin", "LANG=C.UTF-8"]
      let merged = AppleContainerEnvironment.merged(imageDefaults: defaults, overrides: [:])
      #expect(merged == defaults)
    }

    @Test("Overrides alone become the whole environment")
    func overridesWithoutImageDefaults() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: [],
        overrides: ["TZ": "America/Los_Angeles", "LC_ALL": "en_US.UTF-8"]
      )
      #expect(merged == ["LC_ALL=en_US.UTF-8", "TZ=America/Los_Angeles"])
    }

    @Test("Empty inputs produce an empty environment")
    func emptyInputs() {
      #expect(AppleContainerEnvironment.merged(imageDefaults: [], overrides: [:]).isEmpty)
    }

    // MARK: - Override semantics

    @Test("Override replaces the image value in place instead of appending")
    func overrideReplacesInPlace() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["PATH=/usr/bin", "TZ=UTC", "LANG=C.UTF-8"],
        overrides: ["TZ": "America/Los_Angeles"]
      )
      // Same slot, same count — an appended duplicate would leave "TZ=UTC" first
      // and `getenv` inside the container would still report UTC.
      #expect(merged == ["PATH=/usr/bin", "TZ=America/Los_Angeles", "LANG=C.UTF-8"])
      #expect(!merged.contains("TZ=UTC"))
    }

    @Test("Overridden name appears exactly once")
    func overriddenNameAppearsOnce() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["TZ=UTC"],
        overrides: ["TZ": "Europe/Berlin"]
      )
      #expect(merged.filter { $0.hasPrefix("TZ=") }.count == 1)
      #expect(parsed(merged)["TZ"] == "Europe/Berlin")
    }

    @Test("Overriding one name leaves the other image defaults alone")
    func overridePreservesUnrelatedDefaults() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["PATH=/usr/bin", "HOME=/home/agent", "TZ=UTC"],
        overrides: ["TZ": "Asia/Shanghai"]
      )
      let env = parsed(merged)
      #expect(env["PATH"] == "/usr/bin")
      #expect(env["HOME"] == "/home/agent")
      #expect(env["TZ"] == "Asia/Shanghai")
      #expect(merged.count == 3)
    }

    @Test("Duplicate image entries for an overridden name collapse to the override")
    func duplicateImageEntriesCollapse() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["TZ=UTC", "PATH=/usr/bin", "TZ=Etc/GMT"],
        overrides: ["TZ": "Europe/Berlin"]
      )
      #expect(merged == ["TZ=Europe/Berlin", "PATH=/usr/bin"])
    }

    @Test("Duplicate image entries are kept when not overridden")
    func duplicateImageEntriesKeptWithoutOverride() {
      let defaults = ["TZ=UTC", "TZ=Etc/GMT"]
      let merged = AppleContainerEnvironment.merged(imageDefaults: defaults, overrides: [:])
      #expect(merged == defaults)
    }

    // MARK: - New names

    @Test("New names are appended after the image defaults")
    func newNamesAppended() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["PATH=/usr/bin"],
        overrides: ["TZ": "UTC"]
      )
      #expect(merged == ["PATH=/usr/bin", "TZ=UTC"])
    }

    @Test("Appended names are sorted, so the result is deterministic")
    func appendedNamesAreSorted() {
      let overrides = [
        "TZ": "UTC", "LC_ALL": "en_US.UTF-8", "AGENTC_CONFIGURATIONS": "claude",
        "EDITOR": "vim", "LANG": "en_US.UTF-8",
      ]
      let expected = [
        "PATH=/usr/bin",
        "AGENTC_CONFIGURATIONS=claude",
        "EDITOR=vim",
        "LANG=en_US.UTF-8",
        "LC_ALL=en_US.UTF-8",
        "TZ=UTC",
      ]
      // Repeat: dictionary iteration order varies per instance, so a single pass could
      // pass by luck if the output depended on it.
      for _ in 0..<10 {
        let merged = AppleContainerEnvironment.merged(
          imageDefaults: ["PATH=/usr/bin"], overrides: overrides)
        #expect(merged == expected)
      }
    }

    @Test("Every override reaches the container exactly once")
    func allOverridesPresent() {
      let overrides = ["TZ": "UTC", "LANG": "C.UTF-8", "FOO": "bar", "PATH": "/opt/bin"]
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["PATH=/usr/bin", "HOME=/home/agent"],
        overrides: overrides
      )
      #expect(merged.count == 5)  // 4 overrides + HOME
      for (name, value) in overrides {
        #expect(merged.filter { $0.hasPrefix("\(name)=") } == ["\(name)=\(value)"])
      }
    }

    // MARK: - Value shapes

    @Test("Empty override value is preserved as a set-but-empty variable")
    func emptyValue() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["EMPTY=not-empty"],
        overrides: ["EMPTY": "", "ALSO_EMPTY": ""]
      )
      #expect(merged == ["EMPTY=", "ALSO_EMPTY="])
      #expect(parsed(merged)["EMPTY"] == "")
    }

    @Test("Values containing '=' are preserved intact")
    func valueWithEquals() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: [],
        overrides: ["JAVA_TOOL_OPTIONS": "-Dfoo=bar -Dbaz=qux"]
      )
      #expect(merged == ["JAVA_TOOL_OPTIONS=-Dfoo=bar -Dbaz=qux"])
    }

    @Test("An image entry whose value contains '=' is matched on its name only")
    func imageValueWithEqualsIsOverridable() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["OPTS=-Dfoo=bar"],
        overrides: ["OPTS": "-Dfoo=baz"]
      )
      #expect(merged == ["OPTS=-Dfoo=baz"])
    }

    @Test("Values with spaces, newlines, and non-ASCII text survive unmodified")
    func exoticValues() {
      let overrides = [
        "SPACED": "a b  c",
        "MULTILINE": "line1\nline2",
        "UNICODE": "日本語 🌏",
      ]
      let env = parsed(AppleContainerEnvironment.merged(imageDefaults: [], overrides: overrides))
      #expect(env["SPACED"] == "a b  c")
      #expect(env["MULTILINE"] == "line1\nline2")
      #expect(env["UNICODE"] == "日本語 🌏")
    }

    // MARK: - Malformed image entries

    @Test("Image entries without '=' are passed through untouched")
    func imageEntryWithoutSeparator() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["MALFORMED", "TZ=UTC"],
        overrides: ["TZ": "Europe/Berlin"]
      )
      #expect(merged == ["MALFORMED", "TZ=Europe/Berlin"])
    }

    @Test("An image entry with an empty name is not confused with an override")
    func imageEntryWithEmptyName() {
      let merged = AppleContainerEnvironment.merged(
        imageDefaults: ["=stray", "TZ=UTC"],
        overrides: ["TZ": "Europe/Berlin"]
      )
      #expect(merged == ["=stray", "TZ=Europe/Berlin"])
    }
  }
#endif
