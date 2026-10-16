import Foundation

/// A Codable JSON tree preserves extension fields without an untyped `Any` bridge.
/// Decimal avoids converting numeric JSON-RPC IDs through a lossy Double.
enum ACPValue: Codable, Equatable, Sendable {
  case object([String: ACPValue])
  case array([ACPValue])
  case string(String)
  case number(Decimal)
  case bool(Bool)
  case null

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var object: [String: ACPValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Decimal.self) {
      self = .number(value)
    } else if let value = try? container.decode([ACPValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: ACPValue].self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension ACPValue: ExpressibleByStringLiteral {
  init(stringLiteral value: String) { self = .string(value) }
}

extension ACPValue: ExpressibleByIntegerLiteral {
  init(integerLiteral value: Int64) { self = .number(Decimal(value)) }
}

extension ACPValue: ExpressibleByBooleanLiteral {
  init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension ACPValue: ExpressibleByDictionaryLiteral {
  init(dictionaryLiteral elements: (String, ACPValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

extension ACPValue: ExpressibleByArrayLiteral {
  init(arrayLiteral elements: ACPValue...) { self = .array(elements) }
}
