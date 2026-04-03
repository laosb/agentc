/// Protocol for container runtimes that can run an isolated agent session.
///
/// Implement this protocol to add support for a new container runtime (e.g., Docker).
public protocol ContainerRuntimeProtocol: Sendable {
    /// Run a container with the given isolation configuration.
    /// - Returns: The container process exit code.
    func run(config: IsolationConfig) async throws -> Int32
}
