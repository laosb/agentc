#if ContainerRuntimeAppleContainer
  import Foundation
  import Testing

  @testable import AgentIsolationAppleContainerRuntime

  @Suite("Apple Containers default kernel")
  struct AppleContainerDefaultKernelTests {
    @Test("metadata matches Apple's Kata 3.32.0 default")
    func defaultMetadata() {
      #expect(AppleContainerDefaultKernel.kataVersion == "3.32.0")
      #expect(AppleContainerDefaultKernel.filename == "vmlinux-6.18.35-197-debug")
      #expect(
        AppleContainerDefaultKernel.archiveDigest
          == "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5")
    }

    @Test(
      "older kernels are upgraded",
      arguments: [
        "vmlinux-6.18.5-177",
        "vmlinux-6.18.15-186",
        "vmlinux-6.18.35",
        "vmlinux-6.18.35-196-debug",
      ])
    func olderKernels(filename: String) {
      #expect(!AppleContainerDefaultKernel.isCurrentOrNewer(filename: filename))
    }

    @Test("Apple's current kernel is reused")
    func currentKernel() {
      #expect(
        AppleContainerDefaultKernel.isCurrentOrNewer(
          filename: "vmlinux-6.18.35-197-debug"))
    }

    @Test("newer installed kernels are not downgraded")
    func newerKernel() {
      #expect(
        AppleContainerDefaultKernel.isCurrentOrNewer(
          filename: "vmlinux-6.19.1-200-debug"))
    }

    @Test("unversioned kernels are refreshed")
    func unversionedKernel() {
      #expect(!AppleContainerDefaultKernel.isCurrentOrNewer(filename: "default.kernel-arm64"))
    }

    @Test("download digest is computed as SHA-256")
    func archiveDigest() throws {
      let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentc-kernel-digest-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: file) }
      try Data("abc".utf8).write(to: file)

      #expect(
        try AppleContainerDefaultKernel.sha256Digest(of: file)
          == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
  }
#endif
