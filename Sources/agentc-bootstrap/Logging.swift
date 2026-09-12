#if canImport(FoundationEssentials) && (canImport(Musl) || canImport(Glibc))
  import Logging
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif

  // The bootstrap also runs in a separate process inside the container. An
  // explicit factory keeps it on stderr even in native unit-test executables.
  let bootstrapLogger = Logger(label: "agentc-bootstrap") { label in
    var handler = StreamLogHandler.standardError(label: label)
    let verbose = getenv("AGENTC_VERBOSE").map { String(cString: $0) == "1" } ?? false
    handler.logLevel = verbose ? .debug : .info
    return handler
  }
#endif
