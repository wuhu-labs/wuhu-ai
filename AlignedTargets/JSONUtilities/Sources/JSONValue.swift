import Foundation

public enum JSONValueError: Error, Sendable, Hashable {
  case unsupportedValueType(String)
}

public enum JSONValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
      return
    }
    if let number = try? container.decode(Double.self) {
      self = .number(number)
      return
    }
    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }
    if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
      return
    }
    if let object = try? container.decode([String: JSONValue].self) {
      self = .object(object)
      return
    }
    throw DecodingError.typeMismatch(
      JSONValue.self,
      .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }

  public static func fromAny(_ any: Any) throws -> JSONValue {
    switch any {
    case is NSNull:
      return .null
    case let value as Bool:
      return .bool(value)
    case let value as Int:
      return .number(Double(value))
    case let value as Double:
      return .number(value)
    case let value as Float:
      return .number(Double(value))
    case let value as String:
      return .string(value)
    case let value as [Any]:
      return try .array(value.map(JSONValue.fromAny))
    case let value as [String: Any]:
      var object: [String: JSONValue] = [:]
      object.reserveCapacity(value.count)
      for (key, nestedValue) in value {
        object[key] = try JSONValue.fromAny(nestedValue)
      }
      return .object(object)
    default:
      throw JSONValueError.unsupportedValueType(String(describing: type(of: any)))
    }
  }

  public func toAny() -> Any {
    switch self {
    case .null:
      return NSNull()
    case let .bool(value):
      return value
    case let .number(value):
      return value
    case let .string(value):
      return value
    case let .array(value):
      return value.map { $0.toAny() }
    case let .object(value):
      return value.mapValues { $0.toAny() }
    }
  }
}

public extension JSONValue {
  var object: [String: JSONValue]? {
    guard case let .object(value) = self else { return nil }
    return value
  }

  var array: [JSONValue]? {
    guard case let .array(value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case let .string(value) = self else { return nil }
    return value
  }

  var doubleValue: Double? {
    guard case let .number(value) = self else { return nil }
    return value
  }

  var boolValue: Bool? {
    guard case let .bool(value) = self else { return nil }
    return value
  }
}
