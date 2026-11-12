import Crypto
import Foundation

struct LinuxKernelVersion: Comparable, Sendable {
  let components: [Int]

  init?(filename: String) {
    guard let marker = filename.range(of: "vmlinux-") else { return nil }
    let suffix = filename[marker.upperBound...]
    let versionPrefix = suffix.prefix { character in
      character.isNumber || character == "." || character == "-"
    }
    let components = versionPrefix.split { !$0.isNumber }.compactMap { Int($0) }
    guard components.count >= 3 else { return nil }
    self.components = components
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    let componentCount = max(lhs.components.count, rhs.components.count)
    for index in 0..<componentCount {
      let lhsComponent = index < lhs.components.count ? lhs.components[index] : 0
      let rhsComponent = index < rhs.components.count ? rhs.components[index] : 0
      if lhsComponent != rhsComponent {
        return lhsComponent < rhsComponent
      }
    }
    return false
  }
}

/// Kernel metadata mirrored from Apple Container's `KernelConfig` defaults.
enum AppleContainerDefaultKernel {
  static let kataVersion = "4.3.1"
  static let binaryPath =
    "opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug"
  static let archiveURL =
    "https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst"
  static let archiveDigest =
    "sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6"
  static let filename = String(binaryPath.split(separator: "/").last!)
  static let version = LinuxKernelVersion(filename: filename)!

  static func isCurrentOrNewer(filename: String) -> Bool {
    guard let installedVersion = LinuxKernelVersion(filename: filename) else { return false }
    return installedVersion >= version
  }

  static func sha256Digest(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
