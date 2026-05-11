import Foundation
import JSONValue

extension JSONValue {
  /// Serialize this JSONValue to a JSON string.
  public func jsonString(sortedKeys: Bool = false) -> String {
    let any = toAny()
    guard JSONSerialization.isValidJSONObject(any) || (any is NSNull) else {
      return "null"
    }
    let options: JSONSerialization.WritingOptions = sortedKeys ? [.sortedKeys] : []
    guard let data = try? JSONSerialization.data(withJSONObject: any, options: options),
          let string = String(data: data, encoding: .utf8)
    else { return "null" }
    return string
  }

  /// Parse a JSON string into a JSONValue. Returns nil on failure.
  public static func parse(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return try? JSONValue.fromAny(any)
  }
}
