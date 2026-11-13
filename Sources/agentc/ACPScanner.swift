import Foundation

/// The routing fields of one ACP JSON-RPC line. Everything else is opaque:
/// `ranges` are byte offsets into the original line, so forwarding replaces
/// only those values and never decodes or re-encodes the payload.
struct ACPEnvelope: Sendable, Equatable {
  /// The raw JSON token of a string, number, or null `id`; never converted.
  var id: Data?
  var idRange: Range<Int>?
  /// The decoded value when `id` is a JSON string.
  var idString: String?
  /// True when `id` appeared but cannot be attributed (duplicate or not a
  /// short scalar). Errors for such a line use `id: null`.
  var idAmbiguous = false
  var hasMethod = false
  /// The decoded value when `method` is a JSON string.
  var method: String?
  var paramsSessionID: String?
  var paramsSessionRange: Range<Int>?
  var resultSessionID: String?
  var resultSessionRange: Range<Int>?
  /// Length of the line in bytes, without its newline.
  var length = 0
}

/// Incremental validator for newline-delimited JSON-RPC. State is O(nesting),
/// independent of message size, and survives arbitrary chunk boundaries.
///
/// It enforces RFC 8259 grammar and well-formed UTF-8. Escaped surrogates must
/// be paired everywhere, not only in routing fields, so a line this scanner
/// accepts is valid Unicode for every downstream parser. Member names are
/// compared after unescaping, and a repeated routing member is rejected: once
/// bytes are forwarded verbatim, first-wins and last-wins parsers must not be
/// able to disagree about which backend or session a message selects.
struct ACPScanner {
  enum Line: Equatable {
    case blank
    /// Not JSON. No field of such a line can be trusted, including `id`.
    case malformed(String)
    /// Well-formed JSON that is not an acceptable ACP envelope.
    case invalid(String, ACPEnvelope)
    case message(ACPEnvelope)
  }

  static let maximumDepth = 512
  static let maximumIDBytes = 256
  static let maximumMethodBytes = 256
  static let maximumSessionIDBytes = 8192
  private static let maximumKeyBytes = 32

  private enum State {
    case value, valueOrEnd, keyOrEnd, key, colon, afterValue, done
    case string, escape, unicode
    case minus, zero, integer, point, fraction, exponentMark, exponentSign, exponent
    case literal
    case failed
  }
  private enum Top: UInt8 {
    case jsonrpc = 1
    case id = 2
    case method = 4
    case params = 8
    case result = 16
    case error = 32
  }
  private enum Kind { case string, number, null, bool, container }

  private var state = State.value
  /// One entry per open container: true for an object, false for an array.
  private var stack: [Bool] = []
  private var offset = 0
  private var sawContent = false
  private var topIsObject = false
  private var failure = ""
  private var invalid: String?
  private var envelope = ACPEnvelope()

  // Strings.
  private var stringIsKey = false
  private var utf8Remaining = 0
  private var utf8Low: UInt8 = 0x80
  private var utf8High: UInt8 = 0xBF
  private var hex: UInt32 = 0
  private var hexDigits = 0
  private var highSurrogate: UInt32 = 0
  private var capturing = false
  private var captureLimit = 0
  private var captureOverflow = false
  private var capture: [UInt8] = []
  private var literalRest: [UInt8] = []
  private var literalIndex = 0

  // Routing members.
  private var seenTop: UInt8 = 0
  private var pendingTop: Top?
  private var activeTop: Top?
  private var topStart = 0
  private var topKind = Kind.container
  /// `params` or `result` while its object value is open at depth two.
  private var subContainer: Top?
  private var seenSubSession = false
  private var pendingSubSession = false
  private var activeSubSession = false
  private var subStart = 0
  private var subKind = Kind.container
  private var jsonrpcValid = false
  private var rawIDActive = false
  private var rawID: [UInt8] = []
  private var current: UInt8 = 0

  /// True once the current line is known to be malformed; its bytes need not be kept.
  var failed: Bool { state == .failed }
  /// True when a line is in progress, i.e. EOF now would truncate a message.
  var midLine: Bool { sawContent }

  /// Consumes bytes through the first newline, if any. `consumed` includes
  /// that newline; the line's own bytes are `consumed - 1` when `line` is set.
  mutating func scan(_ bytes: UnsafeRawBufferPointer) -> (consumed: Int, line: Line?) {
    let count = bytes.count
    var index = 0
    while index < count {
      if state == .failed {
        // Nothing more to learn from this line: skip to its newline.
        let rest = UnsafeRawBufferPointer(rebasing: bytes[index...])
        guard let found = memchr(rest.baseAddress!, 0x0A, rest.count) else {
          offset += rest.count
          return (count, nil)
        }
        let skipped = rest.baseAddress!.distance(to: UnsafeRawPointer(found))
        offset += skipped
        return (index + skipped + 1, finishLine())
      }
      let byte = bytes[index]
      if byte == 0x0A { return (index + 1, finishLine()) }
      if state == .string, utf8Remaining == 0, highSurrogate == 0 {
        let run = Self.plainRun(bytes, from: index)
        if run > 0 {
          let slice = UnsafeRawBufferPointer(rebasing: bytes[index..<index + run])
          if capturing { appendCapture(slice) }
          if rawIDActive, rawID.count <= Self.maximumIDBytes {
            rawID.append(contentsOf: slice.prefix(Self.maximumIDBytes + 1 - rawID.count))
          }
          index += run
          offset += run
          continue
        }
      }
      // A number ends at the first byte that cannot continue it; that byte
      // belongs to the enclosing structure and is processed again.
      current = byte
      guard step(byte) else { continue }
      if rawIDActive, rawID.count <= Self.maximumIDBytes { rawID.append(byte) }
      index += 1
      offset += 1
    }
    return (count, nil)
  }

  /// Length of the run of ASCII string bytes needing no interpretation:
  /// not a quote, backslash, control character, or UTF-8 lead/continuation.
  private static func plainRun(_ bytes: UnsafeRawBufferPointer, from start: Int) -> Int {
    var index = start
    let count = bytes.count
    let ones: UInt64 = 0x0101_0101_0101_0101
    let highs: UInt64 = 0x8080_8080_8080_8080
    while index + 8 <= count {
      let word = bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)
      // Each term is nonzero iff some byte matches (exact per-byte positions
      // are not needed, so borrow propagation between bytes is harmless).
      let quote = word ^ (ones &* 0x22)
      let slash = word ^ (ones &* 0x5C)
      let special =
        (word & highs)
        | ((word &- ones &* 0x20) & ~word & highs)
        | ((quote &- ones) & ~quote & highs)
        | ((slash &- ones) & ~slash & highs)
      if special != 0 { break }
      index += 8
    }
    while index < count {
      let byte = bytes[index]
      if byte < 0x20 || byte >= 0x80 || byte == 0x22 || byte == 0x5C { break }
      index += 1
    }
    return index - start
  }

  private mutating func fail(_ reason: String) -> Bool {
    failure = reason
    state = .failed
    return true
  }

  private static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0D
  }

  /// Returns false when `byte` was not consumed and must be processed again.
  private mutating func step(_ byte: UInt8) -> Bool {
    switch state {
    case .value, .valueOrEnd:
      if Self.isSpace(byte) { return true }
      if state == .valueOrEnd, byte == 0x5D { return close() }
      return beginValue(byte)
    case .keyOrEnd, .key:
      if Self.isSpace(byte) { return true }
      if byte == 0x22 {
        stringIsKey = true
        beginString(
          capture: stack.count == 1 || (stack.count == 2 && subContainer != nil),
          limit: Self.maximumKeyBytes)
        return true
      }
      if state == .keyOrEnd, byte == 0x7D { return close() }
      return fail("Expected a member name")
    case .colon:
      if Self.isSpace(byte) { return true }
      guard byte == 0x3A else { return fail("Expected ':' after a member name") }
      state = .value
      return true
    case .afterValue:
      if Self.isSpace(byte) { return true }
      let object = stack.last!
      if byte == 0x2C {
        state = object ? .key : .value
        return true
      }
      if byte == (object ? 0x7D : 0x5D) { return close() }
      return fail("Expected ',' or the end of the container")
    case .done:
      if Self.isSpace(byte) { return true }
      return fail("Unexpected data after the JSON value")
    case .string: return stringByte(byte)
    case .escape: return escapeByte(byte)
    case .unicode: return unicodeByte(byte)
    case .minus:
      if byte == 0x30 { state = .zero } else if (0x31...0x39).contains(byte) { state = .integer } else {
        return fail("Invalid number")
      }
      return true
    case .zero, .integer:
      if state == .integer, (0x30...0x39).contains(byte) { return true }
      if byte == 0x2E { state = .point } else if byte == 0x65 || byte == 0x45 {
        state = .exponentMark
      } else {
        if (0x30...0x39).contains(byte) { return fail("Invalid number") }
        endValue(at: offset)
        return false
      }
      return true
    case .point:
      guard (0x30...0x39).contains(byte) else { return fail("Invalid number") }
      state = .fraction
      return true
    case .fraction:
      if (0x30...0x39).contains(byte) { return true }
      if byte == 0x65 || byte == 0x45 {
        state = .exponentMark
        return true
      }
      endValue(at: offset)
      return false
    case .exponentMark, .exponentSign:
      if state == .exponentMark, byte == 0x2B || byte == 0x2D {
        state = .exponentSign
        return true
      }
      guard (0x30...0x39).contains(byte) else { return fail("Invalid number") }
      state = .exponent
      return true
    case .exponent:
      if (0x30...0x39).contains(byte) { return true }
      endValue(at: offset)
      return false
    case .literal:
      guard byte == literalRest[literalIndex] else { return fail("Invalid literal") }
      literalIndex += 1
      if literalIndex == literalRest.count { endValue(at: offset + 1) }
      return true
    case .failed: return true
    }
  }

  private mutating func beginValue(_ byte: UInt8) -> Bool {
    sawContent = true
    let depth = stack.count
    let kind: Kind
    switch byte {
    case 0x7B, 0x5B: kind = .container
    case 0x22: kind = .string
    case 0x2D, 0x30...0x39: kind = .number
    case 0x6E: kind = .null
    case 0x74, 0x66: kind = .bool
    default: return fail("Expected a JSON value")
    }
    if depth == 1 {
      activeTop = pendingTop
      pendingTop = nil
      topStart = offset
      topKind = kind
      subContainer = nil
      if activeTop == .id {
        rawIDActive = true
        rawID.removeAll(keepingCapacity: true)
      }
    } else if depth == 2 {
      activeSubSession = pendingSubSession
      pendingSubSession = false
      subStart = offset
      subKind = kind
    }
    switch byte {
    case 0x7B, 0x5B:
      guard depth < Self.maximumDepth else { return fail("JSON nesting is too deep") }
      let object = byte == 0x7B
      if depth == 0 { topIsObject = object }
      if depth == 1, object, activeTop == .params || activeTop == .result {
        subContainer = activeTop
        seenSubSession = false
      }
      stack.append(object)
      state = object ? .keyOrEnd : .valueOrEnd
    case 0x22:
      stringIsKey = false
      switch (depth, activeTop) {
      case (1, .jsonrpc): beginString(capture: true, limit: 8)
      case (1, .id): beginString(capture: true, limit: Self.maximumIDBytes)
      case (1, .method): beginString(capture: true, limit: Self.maximumMethodBytes)
      case (2, _) where activeSubSession:
        beginString(capture: true, limit: Self.maximumSessionIDBytes)
      default: beginString(capture: false, limit: 0)
      }
    case 0x2D: state = .minus
    case 0x30: state = .zero
    case 0x31...0x39: state = .integer
    default:
      literalRest = byte == 0x6E ? [0x75, 0x6C, 0x6C] : byte == 0x74 ? [0x72, 0x75, 0x65] : [0x61, 0x6C, 0x73, 0x65]
      literalIndex = 0
      state = .literal
    }
    return true
  }

  private mutating func close() -> Bool {
    sawContent = true
    stack.removeLast()
    endValue(at: offset + 1)
    return true
  }

  private mutating func endValue(at end: Int) {
    let depth = stack.count
    if depth == 1, let top = activeTop {
      activeTop = nil
      finishTop(top, range: topStart..<end)
    } else if depth == 2, activeSubSession {
      activeSubSession = false
      finishSubSession(range: subStart..<end)
    }
    if depth == 1 { subContainer = nil }
    state = depth == 0 ? .done : .afterValue
  }

  private mutating func reject(_ reason: String) {
    if invalid == nil { invalid = reason }
  }

  private mutating func finishTop(_ top: Top, range: Range<Int>) {
    switch top {
    case .jsonrpc:
      jsonrpcValid = topKind == .string && !captureOverflow && capture == Array("2.0".utf8)
    case .id:
      rawIDActive = false
      // The byte that completed the value has not been recorded yet.
      if range.upperBound > offset, rawID.count <= Self.maximumIDBytes { rawID.append(current) }
      guard topKind == .string || topKind == .number || topKind == .null,
        rawID.count <= Self.maximumIDBytes, !captureOverflow
      else {
        envelope.idAmbiguous = true
        reject("id must be a string, number, or null of at most \(Self.maximumIDBytes) bytes")
        return
      }
      envelope.id = Data(rawID)
      envelope.idRange = range
      if topKind == .string { envelope.idString = String(decoding: capture, as: UTF8.self) }
    case .method:
      envelope.hasMethod = true
      guard topKind == .string else { return }
      guard !captureOverflow else { return reject("method name is too long") }
      envelope.method = String(decoding: capture, as: UTF8.self)
    case .params, .result, .error: break
    }
  }

  private mutating func finishSubSession(range: Range<Int>) {
    // As before, a non-string sessionId is not a routing field.
    guard subKind == .string else { return }
    guard !captureOverflow else { return reject("sessionId is too long") }
    let value = String(decoding: capture, as: UTF8.self)
    if subContainer == .params {
      envelope.paramsSessionID = value
      envelope.paramsSessionRange = range
    } else {
      envelope.resultSessionID = value
      envelope.resultSessionRange = range
    }
  }

  // MARK: Strings

  private mutating func beginString(capture: Bool, limit: Int) {
    sawContent = true
    state = .string
    capturing = capture
    captureLimit = limit
    captureOverflow = false
    self.capture.removeAll(keepingCapacity: true)
  }

  private mutating func appendCapture(_ bytes: UnsafeRawBufferPointer) {
    guard !captureOverflow else { return }
    guard capture.count + bytes.count <= captureLimit else {
      captureOverflow = true
      return
    }
    capture.append(contentsOf: bytes)
  }

  private mutating func appendCapture(_ byte: UInt8) {
    guard capturing, !captureOverflow else { return }
    guard capture.count < captureLimit else {
      captureOverflow = true
      return
    }
    capture.append(byte)
  }

  private mutating func appendCapture(scalar: UInt32) {
    guard capturing, let scalar = Unicode.Scalar(scalar) else { return }
    for unit in String(Character(scalar)).utf8 { appendCapture(unit) }
  }

  private mutating func stringByte(_ byte: UInt8) -> Bool {
    if highSurrogate != 0 {
      guard byte == 0x5C else { return fail("Unpaired UTF-16 surrogate escape") }
      state = .escape
      return true
    }
    if utf8Remaining > 0 {
      guard (utf8Low...utf8High).contains(byte) else { return fail("Invalid UTF-8") }
      utf8Remaining -= 1
      utf8Low = 0x80
      utf8High = 0xBF
      appendCapture(byte)
      return true
    }
    switch byte {
    case 0x22: return endString()
    case 0x5C: state = .escape
    case 0x00..<0x20: return fail("Unescaped control character in a string")
    case 0x20..<0x80: appendCapture(byte)
    case 0xC2...0xDF: utf8Remaining = 1
    case 0xE0:
      utf8Remaining = 2
      utf8Low = 0xA0
    case 0xED:
      utf8Remaining = 2
      utf8High = 0x9F  // U+D800...U+DFFF are not scalar values.
    case 0xE1...0xEF: utf8Remaining = 2
    case 0xF0:
      utf8Remaining = 3
      utf8Low = 0x90
    case 0xF1...0xF3: utf8Remaining = 3
    case 0xF4:
      utf8Remaining = 3
      utf8High = 0x8F
    default: return fail("Invalid UTF-8")
    }
    if byte >= 0x80 { appendCapture(byte) }
    return true
  }

  private mutating func escapeByte(_ byte: UInt8) -> Bool {
    if byte == 0x75 {
      hex = 0
      hexDigits = 0
      state = .unicode
      return true
    }
    guard highSurrogate == 0 else { return fail("Unpaired UTF-16 surrogate escape") }
    let decoded: UInt8
    switch byte {
    case 0x22, 0x5C, 0x2F: decoded = byte
    case 0x62: decoded = 0x08
    case 0x66: decoded = 0x0C
    case 0x6E: decoded = 0x0A
    case 0x72: decoded = 0x0D
    case 0x74: decoded = 0x09
    default: return fail("Invalid string escape")
    }
    appendCapture(decoded)
    state = .string
    return true
  }

  private mutating func unicodeByte(_ byte: UInt8) -> Bool {
    let digit: UInt32
    switch byte {
    case 0x30...0x39: digit = UInt32(byte) - 0x30
    case 0x41...0x46: digit = UInt32(byte) - 0x41 + 10
    case 0x61...0x66: digit = UInt32(byte) - 0x61 + 10
    default: return fail("Invalid \\u escape")
    }
    hex = hex << 4 | digit
    hexDigits += 1
    guard hexDigits == 4 else { return true }
    state = .string
    if highSurrogate != 0 {
      guard (0xDC00...0xDFFF).contains(hex) else {
        return fail("Unpaired UTF-16 surrogate escape")
      }
      appendCapture(scalar: 0x10000 + ((highSurrogate - 0xD800) << 10) + (hex - 0xDC00))
      highSurrogate = 0
    } else if (0xD800...0xDBFF).contains(hex) {
      highSurrogate = hex
    } else if (0xDC00...0xDFFF).contains(hex) {
      return fail("Unpaired UTF-16 surrogate escape")
    } else {
      appendCapture(scalar: hex)
    }
    return true
  }

  private mutating func endString() -> Bool {
    guard stringIsKey else {
      endValue(at: offset + 1)
      return true
    }
    state = .colon
    guard capturing else { return true }
    let name = captureOverflow ? "" : String(decoding: capture, as: UTF8.self)
    if stack.count == 1 {
      let top: Top?
      switch name {
      case "jsonrpc": top = .jsonrpc
      case "id": top = .id
      case "method": top = .method
      case "params": top = .params
      case "result": top = .result
      case "error": top = .error
      default: top = nil
      }
      if let top {
        if seenTop & top.rawValue != 0 {
          if top == .id {
            envelope.idAmbiguous = true
            envelope.id = nil
            envelope.idRange = nil
            envelope.idString = nil
          }
          reject("Duplicate \"\(name)\" member")
          // The repeated value is validated but never becomes a routing field.
          pendingTop = nil
          return true
        }
        seenTop |= top.rawValue
      }
      pendingTop = top
    } else if name == "sessionId" {
      if seenSubSession {
        reject("Duplicate \"sessionId\" member")
        if subContainer == .params {
          envelope.paramsSessionID = nil
          envelope.paramsSessionRange = nil
        } else {
          envelope.resultSessionID = nil
          envelope.resultSessionRange = nil
        }
        return true
      }
      seenSubSession = true
      pendingSubSession = true
    }
    return true
  }

  // MARK: Lines

  private mutating func finishLine() -> Line {
    defer { self = ACPScanner() }
    if state == .failed { return .malformed(failure) }
    guard sawContent else { return .blank }
    if stack.isEmpty {
      switch state {
      case .zero, .integer, .fraction, .exponent: endValue(at: offset)
      default: break
      }
    }
    guard state == .done else { return .malformed("Truncated JSON value") }
    envelope.length = offset
    guard topIsObject else {
      return .invalid("Expected an ACP JSON-RPC 2.0 object", ACPEnvelope(length: offset))
    }
    if let invalid { return .invalid(invalid, envelope) }
    guard jsonrpcValid else { return .invalid("Expected an ACP JSON-RPC 2.0 object", envelope) }
    return .message(envelope)
  }
}
