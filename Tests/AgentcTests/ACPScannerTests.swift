import Foundation
import Testing

@testable import agentc

/// Feeds `text` in `chunk`-byte pieces and returns every completed line.
private func scan(_ text: Data, chunk: Int) -> [ACPScanner.Line] {
  var scanner = ACPScanner()
  var lines: [ACPScanner.Line] = []
  var start = 0
  while start < text.count {
    let piece = text.subdata(in: start..<min(start + chunk, text.count))
    start += piece.count
    piece.withUnsafeBytes { bytes in
      var rest = bytes
      while !rest.isEmpty {
        let (consumed, line) = scanner.scan(rest)
        if let line { lines.append(line) }
        rest = UnsafeRawBufferPointer(rebasing: rest[consumed...])
      }
    }
  }
  return lines
}

private func scan(_ text: String) -> ACPScanner.Line {
  let lines = scan(Data((text + "\n").utf8), chunk: .max)
  precondition(lines.count == 1)
  return lines[0]
}

private func envelope(_ text: String) -> ACPEnvelope? {
  guard case .message(let envelope) = scan(text) else { return nil }
  return envelope
}

private func isMalformed(_ line: ACPScanner.Line) -> Bool {
  if case .malformed = line { return true }
  return false
}

private func slice(_ text: String, _ range: Range<Int>?) -> String? {
  range.map { String(decoding: Data(text.utf8)[$0], as: UTF8.self) }
}

@Suite("ACP scanner")
struct ACPScannerTests {
  @Test func routingFieldsInAnyOrderAndAtEverySplit() {
    let payload = String(repeating: "QUJD", count: 300)
    let text =
      #"{"params":{"prompt":[{"data":""# + payload
      + #"","sessionId":"decoy"}],"sessionId":"sé🌍"} ,"# + "\t"
      + #""method":"session\/prompt","jsonrpc":"2.0", "id" : 9007199254740993}"# + "\r"
    let whole = envelope(text)
    #expect(whole?.method == "session/prompt")
    #expect(whole?.paramsSessionID == "sé🌍")
    #expect(slice(text, whole?.paramsSessionRange) == #""sé🌍""#)
    #expect(whole?.id == Data("9007199254740993".utf8))
    #expect(slice(text, whole?.idRange) == "9007199254740993")
    #expect(whole?.idString == nil)
    #expect(whole?.length == text.utf8.count)
    let data = Data((text + "\n").utf8)
    #expect(scan(data, chunk: 1) == [.message(whole!)])
    for split in 1..<data.count {
      var scanner = ACPScanner()
      var lines: [ACPScanner.Line] = []
      for piece in [data[..<split], data[split...]] {
        Data(piece).withUnsafeBytes { bytes in
          let (consumed, line) = scanner.scan(bytes)
          #expect(consumed == bytes.count)
          if let line { lines.append(line) }
        }
      }
      #expect(lines == [.message(whole!)], "split at \(split)")
    }
  }

  @Test func identifiersKeepTheirExactToken() {
    for token in [
      "1", "-0", "-0.5e+10", "1E400", "123456789012345678901234567890", "null",
      #""a\"bc""#, #""""#,
    ] {
      let text = #"{"jsonrpc":"2.0","id":\#(token),"method":"m"}"#
      let found = envelope(text)
      #expect(found?.id == Data(token.utf8), "\(token)")
      #expect(slice(text, found?.idRange) == token)
      #expect(found?.idAmbiguous == false)
    }
    #expect(envelope(#"{"jsonrpc":"2.0","id":"a\"bc"}"#)?.idString == "a\"bc")
    #expect(envelope(#"{"jsonrpc":"2.0","method":"m"}"#)?.id == nil)
    let long = "\"" + String(repeating: "x", count: ACPScanner.maximumIDBytes) + "\""
    for token in ["true", "false", "{}", "[1]", #"{"id":1}"#, long] {
      guard case .invalid(_, let found) = scan(#"{"id":\#(token),"jsonrpc":"2.0","method":"m"}"#)
      else {
        Issue.record("\(token) must be rejected")
        continue
      }
      #expect(found.id == nil && found.idAmbiguous && found.hasMethod)
    }
  }

  @Test func duplicateAndEscapedRoutingMembers() {
    // Names are compared after unescaping, and a repeat never selects a route.
    guard
      case .invalid(_, let id) = scan(#"{"jsonrpc":"2.0","id":1,"id":2,"method":"m"}"#)
    else {
      Issue.record("duplicate id must be rejected")
      return
    }
    #expect(id.id == nil && id.idRange == nil && id.idAmbiguous)
    guard
      case .invalid(_, let method) = scan(
        #"{"jsonrpc":"2.0","id":7,"method":"a","method":"b"}"#)
    else {
      Issue.record("duplicate method must be rejected")
      return
    }
    #expect(method.id == Data("7".utf8) && !method.idAmbiguous)
    for text in [
      #"{"jsonrpc":"2.0","id":7,"method":"m","params":{"sessionId":"a","sessionId":"b"}}"#,
      #"{"jsonrpc":"2.0","id":7,"result":{"sessionId":"a","x":1,"sessionId":"a"}}"#,
      #"{"jsonrpc":"2.0","id":7,"method":"m","params":{},"params":{"sessionId":"a"}}"#,
      #"{"jsonrpc":"2.0","jsonrpc":"2.0","id":7,"method":"m"}"#,
      #"{"jsonrpc":"2.0","id":7,"result":1,"result":2}"#,
      #"{"jsonrpc":"2.0","id":7,"error":{},"error":{}}"#,
    ] {
      guard case .invalid(_, let found) = scan(text) else {
        Issue.record("\(text) must be rejected")
        continue
      }
      #expect(found.id == Data("7".utf8))
      if text.contains("session") && !text.contains(#""params":{},"#) {
        #expect(found.paramsSessionID == nil && found.resultSessionID == nil)
      }
    }
    // Only the direct members of params/result route; other duplicates and
    // look-alikes are opaque and pass through.
    let opaque = envelope(
      #"{"jsonrpc":"2.0","method":"m","x":{"id":1,"id":2,"sessionId":"n"},"params":{"a":{"sessionId":"deep","sessionId":"deep"},"sessionId":"top"},"k":1,"k":2}"#
    )
    #expect(opaque?.paramsSessionID == "top" && opaque?.id == nil)
    #expect(envelope(#"{"jsonrpc":"2.0","method":"m","params":[{"sessionId":"x"}]}"#)?.paramsSessionID == nil)
    #expect(envelope(#"{"jsonrpc":"2.0","method":"m","params":{"sessionId":5}}"#)?.paramsSessionID == nil)
    #expect(envelope(#"{"jsonrpc":"2.0","id":"1","result":{"sessionId":"r"}}"#)?.resultSessionID == "r")
    let methodless = envelope(#"{"jsonrpc":"2.0","id":"1","method":5}"#)
    #expect(methodless?.hasMethod == true && methodless?.method == nil)
  }

  @Test func envelopeRequirements() {
    for text in ["[]", "1", "-1.5e3", #""x""#, "null", "true", "{}", #"{"jsonrpc":"1.0","id":1}"#,
      #"{"jsonrpc":2.0,"id":1}"#, #"{"id":1,"method":"m"}"#,
    ] {
      guard case .invalid = scan(text) else {
        Issue.record("\(text) must be an invalid envelope")
        continue
      }
    }
    let long = String(repeating: "m", count: ACPScanner.maximumMethodBytes + 1)
    guard case .invalid(_, let found) = scan(#"{"jsonrpc":"2.0","id":3,"method":"\#(long)"}"#)
    else {
      Issue.record("long method must be rejected")
      return
    }
    #expect(found.id == Data("3".utf8))
    let session = String(repeating: "s", count: ACPScanner.maximumSessionIDBytes + 1)
    guard
      case .invalid = scan(
        #"{"jsonrpc":"2.0","id":3,"method":"m","params":{"sessionId":"\#(session)"}}"#)
    else {
      Issue.record("long sessionId must be rejected")
      return
    }
    #expect(scan(Data("\n \t\r\n\r\n".utf8), chunk: 1) == [.blank, .blank, .blank])
  }

  @Test func acceptsValidJSON() {
    for value in [
      #"[1e5,-0,0.0,1E-2,0e0,123.456e+7,true,false,null]"#, #""\"\\\/\b\f\n\r\t\u0000￿""#,
      #""🌍 🌍 é 𝄞""#, #"{"":{"":[[],{}]}}"#, #"[ ]"#, #"{ }"#,
      "\"\u{7F}\u{80}\u{7FF}\u{800}\u{FFFF}\u{10000}\u{10FFFF}\"",
    ] {
      #expect(envelope(#"{"jsonrpc":"2.0","x": \#(value) }"#) != nil, "\(value)")
    }
    let deep = { (depth: Int) in
      #"{"jsonrpc":"2.0","x":"#
        + String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1) + "}"
    }
    #expect(envelope(deep(ACPScanner.maximumDepth)) != nil)
    #expect(isMalformed(scan(deep(ACPScanner.maximumDepth + 1))))
  }

  @Test func rejectsMalformedJSON() {
    let values = [
      "01", "1.", ".5", "+1", "-", "1e", "1e+", "0x10", "1.e3", "--1", "NaN", "Infinity", "tru",
      "nul", "True", "truee", "[1,]", "[,1]", "[1 2]", #"{"a":1,}"#, #"{"a" 1}"#, #"{a:1}"#,
      #"{"a":}"#, #"{1:2}"#, "]", "[1}", #""\x""#, #""\u12""#, #""\u12G4""#, #""abc"#,
      "\"tab\there\"", "\"nul\u{0}\"", "'x'", "",
      // Surrogate escapes must be paired, in opaque payloads as well.
      #""\ud800""#, #""\udc00""#, #""\ud800A""#, #""\ud800x""#, #""\ud800\n""#,
      #""\ud800\ud800""#, #""\udc00\ud800""#,
    ]
    for value in values {
      #expect(isMalformed(scan(#"{"jsonrpc":"2.0","x":\#(value)}"#)), "\(value)")
      // The same defects in a member name.
      if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
        #expect(isMalformed(scan(#"{"jsonrpc":"2.0",\#(value):1}"#)), "key \(value)")
      }
    }
    for text in [
      "{", "}", #"{"jsonrpc":"2.0"}}"#, #"{"jsonrpc":"2.0"} x"#, #"{"jsonrpc":"2.0"}{}"#, "not-json",
      #"{"jsonrpc":"2.0","id":1"#, "\u{FEFF}{}",
    ] {
      #expect(isMalformed(scan(text)), "\(text)")
    }
  }

  @Test func rejectsMalformedUTF8() {
    let invalid: [[UInt8]] = [
      [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xC2], [0xC2, 0x41], [0xE0, 0x80, 0x80],
      [0xE0, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xE2, 0x82], [0xF0, 0x80, 0x80, 0x80],
      [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xF8], [0xFF],
      [0xF0, 0x9F, 0x8C],
    ]
    for bytes in invalid {
      for prefix in [#"{"jsonrpc":"2.0","x":""#, #"{"jsonrpc":"2.0",""#] {
        // Long ASCII runs on both sides exercise the word-at-a-time path.
        var data = Data((prefix + String(repeating: "a", count: 23)).utf8)
        data.append(contentsOf: bytes)
        data.append(Data((String(repeating: "b", count: 23) + "\"" + (prefix.hasSuffix(":\"") ? "}" : ":1}") + "\n").utf8))
        for chunk in [1, 7, Int.max] {
          let lines = scan(data, chunk: chunk)
          #expect(lines.count == 1 && isMalformed(lines[0]), "\(bytes) chunk \(chunk)")
        }
      }
    }
    // Outside strings, any non-ASCII byte is a grammar error.
    var data = Data(#"{"jsonrpc":"2.0"}"#.utf8)
    data.append(contentsOf: [0xC2, 0xA0, 0x0A])
    #expect(isMalformed(scan(data, chunk: .max)[0]))
  }

  @Test func stringRunsMatchByteAtATimeScanning() {
    // Every special byte at every alignment within the eight-byte fast path.
    for special in ["\"", "\\\\", "\\n", "é", "🌍", "\\u0041"] {
      for lead in 0..<20 {
        let value = String(repeating: "a", count: lead) + special + String(repeating: "z", count: 20)
        let text = special == "\""
          ? #"{"jsonrpc":"2.0","id":"\#(String(repeating: "a", count: lead))","m":"zz"}"#
          : #"{"jsonrpc":"2.0","id":"\#(value)","method":"\#(value)"}"#
        let data = Data((text + "\n").utf8)
        let whole = scan(data, chunk: .max)
        #expect(whole == scan(data, chunk: 1), "\(special) at \(lead)")
        guard case .message(let found) = whole[0] else {
          Issue.record("\(text) must be accepted")
          continue
        }
        #expect(slice(text, found.idRange).map { Data($0.utf8) } == found.id)
        let decoded = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))
        #expect(found.idString == decoded?["id"])
        if special != "\"" { #expect(found.method == decoded?["method"]) }
      }
    }
  }

  @Test func recoversAtTheNextLine() {
    let data = Data(
      "garbage {\"id\":1}\n{\"jsonrpc\":\"2.0\",\"id\":2}\n\"unterminated\n{\"jsonrpc\":\"2.0\",\"id\":3}\n"
        .utf8)
    for chunk in [1, 5, Int.max] {
      let lines = scan(data, chunk: chunk)
      #expect(lines.count == 4)
      #expect(isMalformed(lines[0]) && isMalformed(lines[2]))
      for (line, id) in [(lines[1], "2"), (lines[3], "3")] {
        guard case .message(let found) = line else {
          Issue.record("expected a message")
          continue
        }
        #expect(found.id == Data(id.utf8))
      }
    }
  }
}
