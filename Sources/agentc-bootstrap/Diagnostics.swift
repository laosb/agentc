#if canImport(FoundationEssentials) && canImport(Musl)
  import FoundationEssentials
  import Musl

  /// Guest-side startup instrumentation.
  ///
  /// Records are written to **stderr only**, in the same flat `key=value` shape the
  /// host emits, so a verbose run shows host and guest phases interleaved without the
  /// workload's stdout ever being touched.
  ///
  /// Durations come from `CLOCK_MONOTONIC`. They are only comparable with other guest
  /// spans: host and guest clocks share no epoch, so subtracting one from the other is
  /// meaningless, and overlapping spans must never be summed as if they were sequential.
  /// When the bootstrap process started, so the final span can be closed from
  /// wherever the `exec` happens to be.
  ///
  /// `nonisolated(unsafe)` is sound here: the bootstrap is single-threaded, and this
  /// is written once at the top of `main` before anything else runs.
  enum BootstrapTiming {
    nonisolated(unsafe) static var startedAt: Double = 0
  }

  enum Diagnostics {
    /// Whether the host asked for verbose output. Read once — the environment is
    /// rewritten later during configuration setup.
    static let isEnabled: Bool = Helpers.envVar("AGENTC_VERBOSE") == "1"

    /// Monotonic seconds since an unspecified epoch.
    static func now() -> Double {
      var ts = timespec()
      guard clock_gettime(CLOCK_MONOTONIC, &ts) == 0 else { return 0 }
      return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    /// Emit one timing record.
    static func record(
      phase: String,
      startedAt: Double,
      outcome: String = "success",
      attributes: [(String, String)] = []
    ) {
      guard isEnabled else { return }
      let elapsedMs = max(0, (now() - startedAt) * 1000)
      var line = "agentc: timing phase=\(escape(phase))"
      line += " duration_ms=\(oneDecimal(elapsedMs))"
      line += " outcome=\(escape(outcome))"
      for (name, value) in attributes {
        line += " \(sanitizeName(name))=\(escape(value))"
      }
      bootstrapLogger.debug("\(line)")
    }

    /// Measure a throwing phase, recording `failure` before rethrowing.
    @discardableResult
    static func span<T>(
      _ phase: String,
      attributes: @autoclosure () -> [(String, String)] = [],
      _ body: () throws -> T
    ) rethrows -> T {
      guard isEnabled else { return try body() }
      let start = now()
      do {
        let value = try body()
        record(phase: phase, startedAt: start, attributes: attributes())
        return value
      } catch {
        record(phase: phase, startedAt: start, outcome: "failure", attributes: attributes())
        throw error
      }
    }

    // MARK: - Formatting

    /// Render a non-negative millisecond count with one decimal place.
    ///
    /// `String(format:)` is unavailable in the musl/FoundationEssentials build the
    /// bootstrap is compiled for, so the rounding is done by hand.
    static func oneDecimal(_ value: Double) -> String {
      let scaled = (value * 10).rounded()
      guard scaled.isFinite, scaled >= 0, scaled < 9_000_000_000_000_000 else { return "0.0" }
      let total = Int(scaled)
      return "\(total / 10).\(total % 10)"
    }

    /// Two lowercase hex digits for a byte.
    static func hexByte(_ byte: UInt8) -> String {
      let digits = Array("0123456789abcdef")
      return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
    }

    // MARK: - Escaping

    /// Restrict attribute names to a safe identifier alphabet.
    private static func sanitizeName(_ name: String) -> String {
      let mapped = name.map { character -> Character in
        let isSafe =
          character.isASCII
          && (character.isLetter || character.isNumber || character == "_" || character == ".")
        return isSafe ? character : "_"
      }
      return mapped.isEmpty ? "_" : String(mapped)
    }

    /// Quote and escape a value so it always occupies exactly one field.
    ///
    /// Configuration names come from user-controlled directories, so an unescaped
    /// value could otherwise inject extra fields or break the line format.
    private static func escape(_ value: String) -> String {
      var needsQuoting = value.isEmpty
      var escaped = ""
      escaped.reserveCapacity(value.count)
      for scalar in value.unicodeScalars {
        switch scalar {
        case "\\":
          escaped += "\\\\"
          needsQuoting = true
        case "\"":
          escaped += "\\\""
          needsQuoting = true
        case "\n":
          escaped += "\\n"
          needsQuoting = true
        case "\r":
          escaped += "\\r"
          needsQuoting = true
        case "\t":
          escaped += "\\t"
          needsQuoting = true
        default:
          if scalar.value < 0x20 || scalar.value == 0x7f {
            escaped += "\\x" + hexByte(UInt8(truncatingIfNeeded: scalar.value))
            needsQuoting = true
          } else {
            if scalar == " " || scalar == "=" { needsQuoting = true }
            escaped.unicodeScalars.append(scalar)
          }
        }
      }
      return needsQuoting ? "\"\(escaped)\"" : escaped
    }
  }
#endif
