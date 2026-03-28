import Foundation

public final class JSONValueEncoder {
  public var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate
  public var dataEncodingStrategy: JSONEncoder.DataEncodingStrategy = .base64
  public var nonConformingFloatEncodingStrategy: JSONEncoder.NonConformingFloatEncodingStrategy = .throw
  public var keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
  public var userInfo: [CodingUserInfoKey: Any] = [:]

  public init() {}

  public func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = _JSONValueEncoder(options: .init(from: self))
    encoder.box = try encoder.boxed(value, at: [])
    return try encoder.takeValue()
  }
}

public final class JSONValueDecoder {
  public var dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
  public var dataDecodingStrategy: JSONDecoder.DataDecodingStrategy = .base64
  public var nonConformingFloatDecodingStrategy: JSONDecoder.NonConformingFloatDecodingStrategy = .throw
  public var keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
  public var userInfo: [CodingUserInfoKey: Any] = [:]

  public init() {}

  public func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    try _JSONValueDecoder(options: .init(from: self)).unbox(value, as: type, at: [])
  }
}

private protocol _JSONValueEncodingBox: AnyObject {
  func makeJSONValue() throws -> JSONValue
}

private final class _JSONValueSingleBox: _JSONValueEncodingBox {
  let value: JSONValue

  init(_ value: JSONValue) {
    self.value = value
  }

  func makeJSONValue() throws -> JSONValue {
    value
  }
}

private final class _JSONValueKeyedBox: _JSONValueEncodingBox {
  var values: [String: any _JSONValueEncodingBox] = [:]

  func makeJSONValue() throws -> JSONValue {
    var object: [String: JSONValue] = [:]
    object.reserveCapacity(values.count)
    for (key, value) in values {
      object[key] = try value.makeJSONValue()
    }
    return .object(object)
  }
}

private final class _JSONValueUnkeyedBox: _JSONValueEncodingBox {
  var values: [any _JSONValueEncodingBox] = []

  func makeJSONValue() throws -> JSONValue {
    try .array(values.map { try $0.makeJSONValue() })
  }
}

private final class _JSONValueEncoder: Encoder, SingleValueEncodingContainer {
  struct Options {
    let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    let dataEncodingStrategy: JSONEncoder.DataEncodingStrategy
    let nonConformingFloatEncodingStrategy: JSONEncoder.NonConformingFloatEncodingStrategy
    let keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy
    let userInfo: [CodingUserInfoKey: Any]

    init(from encoder: JSONValueEncoder) {
      dateEncodingStrategy = encoder.dateEncodingStrategy
      dataEncodingStrategy = encoder.dataEncodingStrategy
      nonConformingFloatEncodingStrategy = encoder.nonConformingFloatEncodingStrategy
      keyEncodingStrategy = encoder.keyEncodingStrategy
      userInfo = encoder.userInfo
    }
  }

  var codingPath: [CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { options.userInfo }

  fileprivate var box: (any _JSONValueEncodingBox)?
  fileprivate let options: Options

  init(options: Options, codingPath: [CodingKey] = []) {
    self.options = options
    self.codingPath = codingPath
  }

  func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let box = keyedBox()
    let container = _JSONValueKeyedEncodingContainer<Key>(referencing: self, codingPath: codingPath, box: box)
    return KeyedEncodingContainer(container)
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    _JSONValueUnkeyedEncodingContainer(referencing: self, codingPath: codingPath, box: unkeyedBox())
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    self
  }

  func encodeNil() throws {
    try store(.null)
  }

  func encode(_ value: Bool) throws {
    try store(.bool(value))
  }

  func encode(_ value: String) throws {
    try store(.string(value))
  }

  func encode(_ value: Double) throws {
    try store(numberValue(value))
  }

  func encode(_ value: Float) throws {
    try store(numberValue(Double(value), original: value))
  }

  func encode(_ value: Int) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: Int8) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: Int16) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: Int32) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: Int64) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: UInt) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: UInt8) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: UInt16) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: UInt32) throws {
    try store(.number(Double(value)))
  }

  func encode(_ value: UInt64) throws {
    try store(.number(Double(value)))
  }

  func encode<T>(_ value: T) throws where T: Encodable {
    box = try boxed(value, at: codingPath)
  }

  fileprivate func takeValue() throws -> JSONValue {
    try box?.makeJSONValue() ?? .object([:])
  }

  fileprivate func boxed<T: Encodable>(_ value: T, at codingPath: [CodingKey]) throws -> any _JSONValueEncodingBox {
    if let value = value as? JSONValue {
      return _JSONValueSingleBox(value)
    }
    if let value = value as? Date {
      return try box(date: value, at: codingPath)
    }
    if let value = value as? Data {
      return try box(data: value, at: codingPath)
    }
    if let value = value as? URL {
      return _JSONValueSingleBox(.string(value.absoluteString))
    }
    if let value = value as? Decimal {
      return _JSONValueSingleBox(.number(NSDecimalNumber(decimal: value).doubleValue))
    }
    if let value = value as? Bool {
      return _JSONValueSingleBox(.bool(value))
    }
    if let value = value as? String {
      return _JSONValueSingleBox(.string(value))
    }
    if let value = value as? Double {
      return _JSONValueSingleBox(try numberValue(value, at: codingPath))
    }
    if let value = value as? Float {
      return _JSONValueSingleBox(try numberValue(Double(value), original: value, at: codingPath))
    }
    if let value = value as? Int {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? Int8 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? Int16 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? Int32 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? Int64 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? UInt {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? UInt8 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? UInt16 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? UInt32 {
      return _JSONValueSingleBox(.number(Double(value)))
    }
    if let value = value as? UInt64 {
      return _JSONValueSingleBox(.number(Double(value)))
    }

    let encoder = _JSONValueEncoder(options: options, codingPath: codingPath)
    try value.encode(to: encoder)
    return encoder.box ?? _JSONValueSingleBox(.object([:]))
  }

  fileprivate func makeChildEncoder(for key: CodingKey) -> _JSONValueEncoder {
    _JSONValueEncoder(options: options, codingPath: codingPath + [key])
  }

  fileprivate func makeDeferredEncoder(at codingPath: [CodingKey]) -> _JSONValueEncoder {
    _JSONValueEncoder(options: options, codingPath: codingPath)
  }

  private func keyedBox() -> _JSONValueKeyedBox {
    if let box = box as? _JSONValueKeyedBox {
      return box
    }
    precondition(box == nil, "Cannot create keyed container after encoding a different container type.")
    let box = _JSONValueKeyedBox()
    self.box = box
    return box
  }

  private func unkeyedBox() -> _JSONValueUnkeyedBox {
    if let box = box as? _JSONValueUnkeyedBox {
      return box
    }
    precondition(box == nil, "Cannot create unkeyed container after encoding a different container type.")
    let box = _JSONValueUnkeyedBox()
    self.box = box
    return box
  }

  private func store(_ value: JSONValue) throws {
    precondition(box == nil, "Attempted to encode multiple values into a single value container.")
    box = _JSONValueSingleBox(value)
  }

  private func box(date: Date, at codingPath: [CodingKey]) throws -> any _JSONValueEncodingBox {
    switch options.dateEncodingStrategy {
    case .deferredToDate:
      let encoder = makeDeferredEncoder(at: codingPath)
      try date.encode(to: encoder)
      return encoder.box ?? _JSONValueSingleBox(.object([:]))
    case .secondsSince1970:
      return _JSONValueSingleBox(.number(date.timeIntervalSince1970))
    case .millisecondsSince1970:
      return _JSONValueSingleBox(.number(date.timeIntervalSince1970 * 1000))
    case .iso8601:
      return _JSONValueSingleBox(.string(_JSONValueCoding.iso8601String(from: date)))
#if canImport(Darwin)
    case let .formatted(formatter):
      return _JSONValueSingleBox(.string(formatter.string(from: date)))
#endif
    case let .custom(strategy):
      let encoder = makeDeferredEncoder(at: codingPath)
      try strategy(date, encoder)
      return encoder.box ?? _JSONValueSingleBox(.object([:]))
    @unknown default:
      return _JSONValueSingleBox(.number(date.timeIntervalSince1970))
    }
  }

  private func box(data: Data, at codingPath: [CodingKey]) throws -> any _JSONValueEncodingBox {
    switch options.dataEncodingStrategy {
    case .deferredToData:
      let encoder = makeDeferredEncoder(at: codingPath)
      try data.encode(to: encoder)
      return encoder.box ?? _JSONValueSingleBox(.object([:]))
    case .base64:
      return _JSONValueSingleBox(.string(data.base64EncodedString()))
    case let .custom(strategy):
      let encoder = makeDeferredEncoder(at: codingPath)
      try strategy(data, encoder)
      return encoder.box ?? _JSONValueSingleBox(.object([:]))
    @unknown default:
      return _JSONValueSingleBox(.string(data.base64EncodedString()))
    }
  }

  fileprivate func numberValue(_ value: Double, original: Any? = nil, at path: [CodingKey]? = nil) throws -> JSONValue {
    guard !value.isNaN, !value.isInfinite else {
      switch options.nonConformingFloatEncodingStrategy {
      case .throw:
        let context = EncodingError.Context(
          codingPath: path ?? codingPath,
          debugDescription: "Unable to encode non-conforming floating-point value \(value) directly in JSON."
        )
        throw EncodingError.invalidValue(original ?? value, context)
      case let .convertToString(positiveInfinity, negativeInfinity, nan):
        if value == .infinity {
          return .string(positiveInfinity)
        }
        if value == -.infinity {
          return .string(negativeInfinity)
        }
        return .string(nan)
      @unknown default:
        let context = EncodingError.Context(
          codingPath: path ?? codingPath,
          debugDescription: "Unable to encode non-conforming floating-point value \(value) directly in JSON."
        )
        throw EncodingError.invalidValue(original ?? value, context)
      }
    }
    return .number(value)
  }
}

private struct _JSONValueKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let codingPath: [CodingKey]

  private let encoder: _JSONValueEncoder
  private let box: _JSONValueKeyedBox

  init(referencing encoder: _JSONValueEncoder, codingPath: [CodingKey], box: _JSONValueKeyedBox) {
    self.encoder = encoder
    self.codingPath = codingPath
    self.box = box
  }

  mutating func encodeNil(forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.null)
  }

  mutating func encode(_ value: Bool, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.bool(value))
  }

  mutating func encode(_ value: String, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.string(value))
  }

  mutating func encode(_ value: Double, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(try encoder.numberValue(value, at: codingPath + [key]))
  }

  mutating func encode(_ value: Float, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(
      try encoder.numberValue(Double(value), original: value, at: codingPath + [key])
    )
  }

  mutating func encode(_ value: Int, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: Int8, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: Int16, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: Int32, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: Int64, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: UInt, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: UInt8, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: UInt16, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: UInt32, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode(_ value: UInt64, forKey key: Key) throws {
    box.values[encoded(key)] = _JSONValueSingleBox(.number(Double(value)))
  }

  mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
    box.values[encoded(key)] = try encoder.boxed(value, at: codingPath + [key])
  }

  mutating func nestedContainer<NestedKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let childBox = _JSONValueKeyedBox()
    box.values[encoded(key)] = childBox
    let container = _JSONValueKeyedEncodingContainer<NestedKey>(
      referencing: encoder.makeChildEncoder(for: key),
      codingPath: codingPath + [key],
      box: childBox
    )
    return KeyedEncodingContainer(container)
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let childBox = _JSONValueUnkeyedBox()
    box.values[encoded(key)] = childBox
    return _JSONValueUnkeyedEncodingContainer(
      referencing: encoder.makeChildEncoder(for: key),
      codingPath: codingPath + [key],
      box: childBox
    )
  }

  mutating func superEncoder() -> any Encoder {
    superEncoder(forKey: Key(stringValue: _JSONKey.super.stringValue)!)
  }

  mutating func superEncoder(forKey key: Key) -> any Encoder {
    let child = encoder.makeChildEncoder(for: key)
    let encodedKey = encoded(key)
    child.box = _JSONValueKeyedBox()
    box.values[encodedKey] = child.box
    return child
  }

  private func encoded(_ key: Key) -> String {
    _JSONValueCoding.encodedKey(
      key,
      at: codingPath,
      strategy: encoder.options.keyEncodingStrategy
    )
  }
}

private struct _JSONValueUnkeyedEncodingContainer: UnkeyedEncodingContainer {
  let codingPath: [CodingKey]
  var count: Int { box.values.count }

  private let encoder: _JSONValueEncoder
  private let box: _JSONValueUnkeyedBox

  init(referencing encoder: _JSONValueEncoder, codingPath: [CodingKey], box: _JSONValueUnkeyedBox) {
    self.encoder = encoder
    self.codingPath = codingPath
    self.box = box
  }

  mutating func encodeNil() throws {
    box.values.append(_JSONValueSingleBox(.null))
  }

  mutating func encode(_ value: Bool) throws {
    box.values.append(_JSONValueSingleBox(.bool(value)))
  }

  mutating func encode(_ value: String) throws {
    box.values.append(_JSONValueSingleBox(.string(value)))
  }

  mutating func encode(_ value: Double) throws {
    box.values.append(_JSONValueSingleBox(try encoder.numberValue(value, at: codingPath + [indexKey])))
  }

  mutating func encode(_ value: Float) throws {
    box.values.append(
      _JSONValueSingleBox(
        try encoder.numberValue(Double(value), original: value, at: codingPath + [indexKey])
      )
    )
  }

  mutating func encode(_ value: Int) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: Int8) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: Int16) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: Int32) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: Int64) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: UInt) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: UInt8) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: UInt16) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: UInt32) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode(_ value: UInt64) throws {
    box.values.append(_JSONValueSingleBox(.number(Double(value))))
  }

  mutating func encode<T>(_ value: T) throws where T: Encodable {
    box.values.append(try encoder.boxed(value, at: codingPath + [indexKey]))
  }

  mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
    let childBox = _JSONValueKeyedBox()
    box.values.append(childBox)
    let container = _JSONValueKeyedEncodingContainer<NestedKey>(
      referencing: encoder.makeChildEncoder(for: indexKey),
      codingPath: codingPath + [indexKey],
      box: childBox
    )
    return KeyedEncodingContainer(container)
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let childBox = _JSONValueUnkeyedBox()
    box.values.append(childBox)
    return _JSONValueUnkeyedEncodingContainer(
      referencing: encoder.makeChildEncoder(for: indexKey),
      codingPath: codingPath + [indexKey],
      box: childBox
    )
  }

  mutating func superEncoder() -> any Encoder {
    let child = encoder.makeChildEncoder(for: indexKey)
    child.box = _JSONValueKeyedBox()
    box.values.append(child.box!)
    return child
  }

  private var indexKey: _JSONKey {
    _JSONKey(intValue: count)!
  }
}

private final class _JSONValueDecoder: Decoder, SingleValueDecodingContainer {
  struct Options {
    let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
    let dataDecodingStrategy: JSONDecoder.DataDecodingStrategy
    let nonConformingFloatDecodingStrategy: JSONDecoder.NonConformingFloatDecodingStrategy
    let keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy
    let userInfo: [CodingUserInfoKey: Any]

    init(from decoder: JSONValueDecoder) {
      dateDecodingStrategy = decoder.dateDecodingStrategy
      dataDecodingStrategy = decoder.dataDecodingStrategy
      nonConformingFloatDecodingStrategy = decoder.nonConformingFloatDecodingStrategy
      keyDecodingStrategy = decoder.keyDecodingStrategy
      userInfo = decoder.userInfo
    }
  }

  let codingPath: [CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { options.userInfo }

  private let value: JSONValue
  fileprivate let options: Options

  init(value: JSONValue = .null, options: Options, codingPath: [CodingKey] = []) {
    self.value = value
    self.options = options
    self.codingPath = codingPath
  }

  func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    guard case let .object(object) = value else {
      throw DecodingError.typeMismatch(
        [String: JSONValue].self,
        .init(codingPath: codingPath, debugDescription: "Expected object but found \(value.kindDescription).")
      )
    }
    let container = _JSONValueKeyedDecodingContainer<Key>(
      referencing: self,
      codingPath: codingPath,
      object: object
    )
    return KeyedDecodingContainer(container)
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    guard case let .array(array) = value else {
      throw DecodingError.typeMismatch(
        [JSONValue].self,
        .init(codingPath: codingPath, debugDescription: "Expected array but found \(value.kindDescription).")
      )
    }
    return _JSONValueUnkeyedDecodingContainer(referencing: self, codingPath: codingPath, values: array)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    self
  }

  func decodeNil() -> Bool {
    if case .null = value {
      return true
    }
    return false
  }

  func decode(_ type: Bool.Type) throws -> Bool {
    guard case let .bool(bool) = value else {
      throw typeMismatch(type, for: value)
    }
    return bool
  }

  func decode(_ type: String.Type) throws -> String {
    guard case let .string(string) = value else {
      throw typeMismatch(type, for: value)
    }
    return string
  }

  func decode(_ type: Double.Type) throws -> Double {
    try unboxFloatingPoint(value, as: type)
  }

  func decode(_ type: Float.Type) throws -> Float {
    try unboxFloatingPoint(value, as: type)
  }

  func decode(_ type: Int.Type) throws -> Int {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: Int8.Type) throws -> Int8 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: Int16.Type) throws -> Int16 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: Int32.Type) throws -> Int32 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: Int64.Type) throws -> Int64 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: UInt.Type) throws -> UInt {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: UInt8.Type) throws -> UInt8 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: UInt16.Type) throws -> UInt16 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: UInt32.Type) throws -> UInt32 {
    try unboxInteger(value, as: type)
  }

  func decode(_ type: UInt64.Type) throws -> UInt64 {
    try unboxInteger(value, as: type)
  }

  func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
    try unbox(value, as: type, at: codingPath)
  }

  fileprivate func unbox<T: Decodable>(_ value: JSONValue, as type: T.Type, at codingPath: [CodingKey]) throws -> T {
    if type == JSONValue.self {
      return value as! T
    }
    if type == Date.self {
      return try unboxDate(value, at: codingPath) as! T
    }
    if type == Data.self {
      return try unboxData(value, at: codingPath) as! T
    }
    if type == URL.self {
      let string = try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(String.self)
      guard let url = URL(string: string) else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: codingPath, debugDescription: "Invalid URL string: \(string)")
        )
      }
      return url as! T
    }

    let decoder = _JSONValueDecoder(value: value, options: options, codingPath: codingPath)
    return try T(from: decoder)
  }

  private func unboxDate(_ value: JSONValue, at codingPath: [CodingKey]) throws -> Date {
    switch options.dateDecodingStrategy {
    case .deferredToDate:
      return try Date(from: _JSONValueDecoder(value: value, options: options, codingPath: codingPath))
    case .secondsSince1970:
      return Date(timeIntervalSince1970: try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(Double.self))
    case .millisecondsSince1970:
      return Date(timeIntervalSince1970: try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(Double.self) / 1000)
    case .iso8601:
      let string = try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(String.self)
      guard let date = _JSONValueCoding.iso8601Date(from: string) else {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Expected ISO8601 date string."))
      }
      return date
#if canImport(Darwin)
    case let .formatted(formatter):
      let string = try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(String.self)
      guard let date = formatter.date(from: string) else {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Date string does not match formatter."))
      }
      return date
#endif
    case let .custom(strategy):
      return try strategy(_JSONValueDecoder(value: value, options: options, codingPath: codingPath))
    @unknown default:
      return Date(timeIntervalSince1970: try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(Double.self))
    }
  }

  private func unboxData(_ value: JSONValue, at codingPath: [CodingKey]) throws -> Data {
    switch options.dataDecodingStrategy {
    case .deferredToData:
      return try Data(from: _JSONValueDecoder(value: value, options: options, codingPath: codingPath))
    case .base64:
      let string = try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(String.self)
      guard let data = Data(base64Encoded: string) else {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Encountered Data is not valid Base64."))
      }
      return data
    case let .custom(strategy):
      return try strategy(_JSONValueDecoder(value: value, options: options, codingPath: codingPath))
    @unknown default:
      let string = try _JSONValueDecoder(value: value, options: options, codingPath: codingPath).decode(String.self)
      guard let data = Data(base64Encoded: string) else {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Encountered Data is not valid Base64."))
      }
      return data
    }
  }

  private func unboxInteger<T: FixedWidthInteger>(_ value: JSONValue, as type: T.Type) throws -> T {
    guard case let .number(number) = value else {
      throw typeMismatch(type, for: value)
    }
    guard number.isFinite, let exact = T(exactly: number) else {
      throw typeMismatch(type, for: value)
    }
    return exact
  }

  private func unboxFloatingPoint<T: BinaryFloatingPoint>(_ value: JSONValue, as type: T.Type) throws -> T {
    switch value {
    case let .number(number):
      let converted = T(number)
      if number.isFinite && !converted.isFinite {
        throw typeMismatch(type, for: value)
      }
      return converted
    case let .string(string):
      switch options.nonConformingFloatDecodingStrategy {
      case .throw:
        throw typeMismatch(type, for: value)
      case let .convertFromString(positiveInfinity, negativeInfinity, nan):
        if string == positiveInfinity {
          return .infinity
        }
        if string == negativeInfinity {
          return -.infinity
        }
        if string == nan {
          return .nan
        }
        throw DecodingError.dataCorrupted(
          .init(codingPath: codingPath, debugDescription: "Expected non-conforming float string.")
        )
      @unknown default:
        throw typeMismatch(type, for: value)
      }
    default:
      throw typeMismatch(type, for: value)
    }
  }

  private func typeMismatch(_ type: Any.Type, for value: JSONValue) -> DecodingError {
    .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected \(type) but found \(value.kindDescription)."))
  }
}

private struct _JSONValueKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let codingPath: [CodingKey]
  var allKeys: [Key] { mapped.keys.compactMap(Key.init(stringValue:)) }

  private let decoder: _JSONValueDecoder
  private let mapped: [String: (sourceKey: String, value: JSONValue)]

  init(referencing decoder: _JSONValueDecoder, codingPath: [CodingKey], object: [String: JSONValue]) {
    self.decoder = decoder
    self.codingPath = codingPath
    mapped = object.reduce(into: [:]) { partialResult, entry in
      let transformed = _JSONValueCoding.decodedKey(
        entry.key,
        at: codingPath,
        strategy: decoder.options.keyDecodingStrategy
      )
      partialResult[transformed] = (entry.key, entry.value)
    }
  }

  func contains(_ key: Key) -> Bool {
    mapped[key.stringValue] != nil
  }

  func decodeNil(forKey key: Key) throws -> Bool {
    guard let entry = mapped[key.stringValue] else { return false }
    if case .null = entry.value {
      return true
    }
    return false
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: String.Type, forKey key: Key) throws -> String {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
    try decoder(for: key).decode(type)
  }

  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
    try decoder(for: key).decode(type)
  }

  func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
    let value = try value(for: key)
    return try decoder.unbox(value, as: type, at: codingPath + [key])
  }

  func nestedContainer<NestedKey>(
    keyedBy type: NestedKey.Type,
    forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    try decoder(for: key).container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    try decoder(for: key).unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder {
    try superDecoder(forKey: Key(stringValue: _JSONKey.super.stringValue)!)
  }

  func superDecoder(forKey key: Key) throws -> any Decoder {
    if let entry = mapped[key.stringValue] {
      return _JSONValueDecoder(value: entry.value, options: decoder.options, codingPath: codingPath + [key])
    }
    return _JSONValueDecoder(value: .null, options: decoder.options, codingPath: codingPath + [key])
  }

  private func value(for key: Key) throws -> JSONValue {
    guard let entry = mapped[key.stringValue] else {
      throw DecodingError.keyNotFound(
        key,
        .init(codingPath: codingPath, debugDescription: "No value associated with key \(key.stringValue).")
      )
    }
    return entry.value
  }

  private func decoder(for key: Key) throws -> _JSONValueDecoder {
    _JSONValueDecoder(value: try value(for: key), options: decoder.options, codingPath: codingPath + [key])
  }
}

private struct _JSONValueUnkeyedDecodingContainer: UnkeyedDecodingContainer {
  let codingPath: [CodingKey]
  let count: Int?
  var currentIndex: Int = 0
  var isAtEnd: Bool { currentIndex >= values.count }

  private let decoder: _JSONValueDecoder
  private let values: [JSONValue]

  init(referencing decoder: _JSONValueDecoder, codingPath: [CodingKey], values: [JSONValue]) {
    self.decoder = decoder
    self.codingPath = codingPath
    self.values = values
    count = values.count
  }

  mutating func decodeNil() throws -> Bool {
    guard !isAtEnd else { return false }
    if case .null = values[currentIndex] {
      currentIndex += 1
      return true
    }
    return false
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: String.Type) throws -> String {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Double.Type) throws -> Double {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Float.Type) throws -> Float {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Int.Type) throws -> Int {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Int8.Type) throws -> Int8 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Int16.Type) throws -> Int16 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Int32.Type) throws -> Int32 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: Int64.Type) throws -> Int64 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: UInt.Type) throws -> UInt {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
    try takeDecoder().decode(type)
  }

  mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
    try takeDecoder().decode(type)
  }

  mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
    let index = currentIndex
    let value = try takeValue()
    return try decoder.unbox(value, as: type, at: codingPath + [_JSONKey(intValue: index)!])
  }

  mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
    try takeDecoder().container(keyedBy: type)
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    try takeDecoder().unkeyedContainer()
  }

  mutating func superDecoder() throws -> any Decoder {
    try takeDecoder()
  }

  private mutating func takeValue() throws -> JSONValue {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        JSONValue.self,
        .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end.")
      )
    }
    defer { currentIndex += 1 }
    return values[currentIndex]
  }

  private mutating func takeDecoder() throws -> _JSONValueDecoder {
    let index = currentIndex
    let value = try takeValue()
    return _JSONValueDecoder(value: value, options: decoder.options, codingPath: codingPath + [_JSONKey(intValue: index)!])
  }
}

private enum _JSONValueCoding {
  static func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
  }

  static func iso8601Date(from string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)
  }

  static func encodedKey(
    _ key: some CodingKey,
    at codingPath: [CodingKey],
    strategy: JSONEncoder.KeyEncodingStrategy
  ) -> String {
    switch strategy {
    case .useDefaultKeys:
      return key.stringValue
    case .convertToSnakeCase:
      return convertToSnakeCase(key.stringValue)
    case let .custom(transform):
      return transform(codingPath + [key]).stringValue
    @unknown default:
      return key.stringValue
    }
  }

  static func decodedKey(
    _ key: String,
    at codingPath: [CodingKey],
    strategy: JSONDecoder.KeyDecodingStrategy
  ) -> String {
    switch strategy {
    case .useDefaultKeys:
      return key
    case .convertFromSnakeCase:
      return convertFromSnakeCase(key)
    case let .custom(transform):
      return transform(codingPath + [_JSONKey(stringValue: key)!]).stringValue
    @unknown default:
      return key
    }
  }

  static func convertToSnakeCase(_ stringKey: String) -> String {
    guard !stringKey.isEmpty else { return stringKey }

    let leading = stringKey.prefix(while: { $0 == "_" })
    let trailing = stringKey.reversed().prefix(while: { $0 == "_" }).reversed()

    let start = stringKey.index(stringKey.startIndex, offsetBy: leading.count)
    let end = stringKey.index(stringKey.endIndex, offsetBy: -trailing.count)
    guard start < end else { return stringKey }

    let core = String(stringKey[start..<end])
    var words: [String] = []
    var wordStart = core.startIndex

    while wordStart < core.endIndex {
      var searchIndex = core.index(after: wordStart)

      while searchIndex < core.endIndex {
        let current = core[searchIndex]
        let previous = core[core.index(before: searchIndex)]
        let next = core.index(after: searchIndex) < core.endIndex ? core[core.index(after: searchIndex)] : nil

        let shouldBreak =
          (current.isUppercase && (previous.isLowercase || previous.isNumber))
          || (current.isUppercase && previous.isUppercase && (next?.isLowercase ?? false))

        if shouldBreak {
          break
        }

        searchIndex = core.index(after: searchIndex)
      }

      words.append(String(core[wordStart..<searchIndex]).lowercased())
      wordStart = searchIndex
    }

    return String(leading) + words.joined(separator: "_") + String(trailing)
  }

  static func convertFromSnakeCase(_ stringKey: String) -> String {
    guard !stringKey.isEmpty else { return stringKey }

    let leading = stringKey.prefix(while: { $0 == "_" })
    let trailing = stringKey.reversed().prefix(while: { $0 == "_" }).reversed()

    let start = stringKey.index(stringKey.startIndex, offsetBy: leading.count)
    let end = stringKey.index(stringKey.endIndex, offsetBy: -trailing.count)
    guard start < end else { return stringKey }

    let core = String(stringKey[start..<end])
    let components = core.split(separator: "_").map(String.init)
    guard let first = components.first else {
      return String(leading) + String(trailing)
    }

    let rest = components.dropFirst().map { component in
      component.prefix(1).uppercased() + component.dropFirst().lowercased()
    }

    return String(leading) + ([first.lowercased()] + rest).joined() + String(trailing)
  }
}

private struct _JSONKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = Int(stringValue)
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }

  static let `super` = _JSONKey(stringValue: "super")!
}

private extension JSONValue {
  var kindDescription: String {
    switch self {
    case .null:
      return "null"
    case .bool:
      return "bool"
    case .number:
      return "number"
    case .string:
      return "string"
    case .array:
      return "array"
    case .object:
      return "object"
    }
  }
}

private extension Character {
  var isUppercase: Bool {
    unicodeScalars.allSatisfy(CharacterSet.uppercaseLetters.contains)
  }

  var isLowercase: Bool {
    unicodeScalars.allSatisfy(CharacterSet.lowercaseLetters.contains)
  }

  var isNumber: Bool {
    unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
  }
}
