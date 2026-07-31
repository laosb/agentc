/// Environment variable handling for ``AppleContainerRuntime``.
///
/// Deliberately free of `Containerization` types so the merge rules build — and stay
/// unit-testable — on every platform, not just where the runtime itself is available.
enum AppleContainerEnvironment {
  /// Merge agentc-supplied variables into an image's `KEY=VALUE` environment list.
  ///
  /// Entries are matched by name: an override replaces the image's value in place rather
  /// than being appended, so an image default can never shadow a user value (a duplicate
  /// name earlier in `environ` wins for `getenv`). This matches Docker's behavior, where
  /// container `Env` overrides the image's `ENV` for the same name.
  ///
  /// Names not present in the image list are appended in sorted order, so the result is
  /// deterministic even though `overrides` is an unordered dictionary. Image entries
  /// without a `=` are passed through untouched.
  static func merged(imageDefaults: [String], overrides: [String: String]) -> [String] {
    var pending = overrides
    var overridden = Set<String>()
    var result: [String] = []
    result.reserveCapacity(imageDefaults.count + overrides.count)

    for entry in imageDefaults {
      guard let separator = entry.firstIndex(of: "=") else {
        // Not a `KEY=VALUE` entry — nothing to match on, keep it as-is.
        result.append(entry)
        continue
      }
      let name = String(entry[..<separator])

      if let value = pending.removeValue(forKey: name) {
        overridden.insert(name)
        result.append("\(name)=\(value)")
      } else if !overridden.contains(name) {
        result.append(entry)
      }
      // else: a later duplicate of a name we already overrode — drop it.
    }

    for name in pending.keys.sorted() {
      result.append("\(name)=\(pending[name]!)")
    }

    return result
  }
}
