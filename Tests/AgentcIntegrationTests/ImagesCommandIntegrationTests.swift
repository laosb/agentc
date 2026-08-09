#if os(macOS) && ContainerRuntimeAppleContainer
  import AgentIsolation
  import AgentIsolationAppleContainerRuntime
  import Containerization
  import Foundation
  import Testing

  private let runAppleContainerImageTests =
    ProcessInfo.processInfo.environment["AGENTC_TEST_APPLE_CONTAINER_IMAGES"] == "1"

  @Suite(
    "Images Command Apple Container Integration Tests",
    .enabled(if: runAppleContainerImageTests)
  )
  struct ImagesCommandIntegrationTests {
    private let imageReference = "docker.io/library/alpine:3.20"

    @Test("list, inspect, and remove an Apple Container image")
    func imageLifecycle() async throws {
      let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agentc-images-integration-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: storage) }

      // Seed only the isolated image store. Image management does not require
      // VM networking, a kernel, or a ContainerManager.
      let imageStore = try ImageStore(path: storage.appendingPathComponent("imagestore"))
      let pulled = try await imageStore.pull(reference: imageReference, platform: .current)
      #expect(pulled.reference == imageReference)

      let common = ["--runtime", "apple-container", "--storage-path", storage.path]

      let list = await runAgentc(args: ["images", "list"] + common)
      #expect(list.exitCode == 0)
      #expect(list.stdout.contains("docker.io/library/alpine"))
      #expect(list.stdout.contains("3.20"))
      #expect(list.stdout.contains("STORAGE"))

      let inspect = await runAgentc(args: ["images", "inspect", imageReference] + common)
      #expect(inspect.exitCode == 0)
      #expect(inspect.stdout.contains("name:     docker.io/library/alpine"))
      #expect(inspect.stdout.contains("tag:      3.20"))
      #expect(inspect.stdout.contains("storage:"))
      #expect(inspect.stdout.contains("digest:   sha256:"))
      #expect(inspect.stdout.contains("mediaType:"))
      #expect(inspect.stdout.contains("platforms:"))

      let remove = await runAgentc(args: ["images", "remove", imageReference] + common)
      #expect(remove.exitCode == 0)
      #expect(remove.stdout.contains("removed image"))

      let missing = await runAgentc(args: ["images", "inspect", imageReference] + common)
      #expect(missing.exitCode != 0)
      #expect(missing.stderr.contains("was not found"))

      let empty = await runAgentc(args: ["images", "list"] + common)
      #expect(empty.exitCode == 0)
      #expect(empty.stdout.contains("No images found"))
    }
  }
#endif
