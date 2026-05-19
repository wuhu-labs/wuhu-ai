import Foundation
import JSONValue

extension JSONValue {
  /// Serialize this JSONValue to a JSON string.
  public func jsonString(sortedKeys: Bool = false) -> String {
    let encoder = JSONEncoder()
    if sortedKeys {
      encoder.outputFormatting = .sortedKeys
    }
    guard let data = try? encoder.encode(self),
          let string = String(data: data, encoding: .utf8)
    else { return "null" }
    return string
  }

  /// Parse a JSON string into a JSONValue. Returns nil on failure.
  public static func parse(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}
