import Foundation
import Testing
import WuhuAI

struct JSONValueCodingTests {
  @Test func encodesCodableValuesWithJSONEncoderStyleStrategies() throws {
    let encoder = JSONValueEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    encoder.dataEncodingStrategy = .base64
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "inf",
      negativeInfinity: "-inf",
      nan: "nan"
    )

    let value = try encoder.encode(StrategyPayload(
      userId: 42,
      createdAt: Date(timeIntervalSince1970: 1),
      avatarData: Data([1, 2, 3]),
      score: .infinity,
      childValues: [.init(displayName: "Ada Lovelace")]
    ))

    #expect(value == .object([
      "user_id": .number(42),
      "created_at": .string("1970-01-01T00:00:01Z"),
      "avatar_data": .string("AQID"),
      "score": .string("inf"),
      "child_values": .array([
        .object([
          "display_name": .string("Ada Lovelace"),
        ]),
      ]),
    ]))
  }

  @Test func decodesCodableValuesWithJSONDecoderStyleStrategies() throws {
    let decoder = JSONValueDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    decoder.dataDecodingStrategy = .base64
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf",
      negativeInfinity: "-inf",
      nan: "nan"
    )

    let payload = try decoder.decode(
      StrategyPayload.self,
      from: .object([
        "user_id": .number(42),
        "created_at": .string("1970-01-01T00:00:01Z"),
        "avatar_data": .string("AQID"),
        "score": .string("inf"),
        "child_values": .array([
          .object([
            "display_name": .string("Ada Lovelace"),
          ]),
        ]),
      ])
    )

    #expect(payload.userId == 42)
    #expect(payload.createdAt == Date(timeIntervalSince1970: 1))
    #expect(payload.avatarData == Data([1, 2, 3]))
    #expect(payload.score == .infinity)
    #expect(payload.childValues == [.init(displayName: "Ada Lovelace")])
  }

  @Test func supportsCustomStrategiesAndUserInfo() throws {
    let encoder = JSONValueEncoder()
    encoder.userInfo[.decoration] = "!"
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode("ts:\(Int(date.timeIntervalSince1970))")
    }
    encoder.dataEncodingStrategy = .custom { data, encoder in
      var container = encoder.unkeyedContainer()
      for byte in data {
        try container.encode(Int(byte))
      }
    }

    let encoded = try encoder.encode(CustomPayload(
      createdAt: Date(timeIntervalSince1970: 10),
      blob: Data([4, 5, 6]),
      note: .init(message: "ready")
    ))

    #expect(encoded == .object([
      "createdAt": JSONValue.string("ts:10"),
      "blob": JSONValue.array([.number(4), .number(5), .number(6)]),
      "note": JSONValue.string("ready!"),
    ] as [String: JSONValue]))

    let decoder = JSONValueDecoder()
    decoder.userInfo[.decoration] = "prefix:"
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      guard let seconds = Int(string.dropFirst(3)) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected ts:<seconds> date string.")
      }
      return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
    decoder.dataDecodingStrategy = .custom { decoder in
      var container = try decoder.unkeyedContainer()
      var bytes: [UInt8] = []
      while !container.isAtEnd {
        bytes.append(UInt8(try container.decode(Int.self)))
      }
      return Data(bytes)
    }

    let decoded = try decoder.decode(CustomPayload.self, from: encoded)
    #expect(decoded == CustomPayload(
      createdAt: Date(timeIntervalSince1970: 10),
      blob: Data([4, 5, 6]),
      note: .init(message: "prefix:ready!")
    ))
  }
}

private struct StrategyPayload: Codable, Equatable {
  var userId: Int
  var createdAt: Date
  var avatarData: Data
  var score: Double
  var childValues: [Child]

  struct Child: Codable, Equatable {
    var displayName: String
  }
}

private struct CustomPayload: Codable, Equatable {
  var createdAt: Date
  var blob: Data
  var note: DecoratedMessage
}

private struct DecoratedMessage: Codable, Equatable {
  var message: String

  init(message: String) {
    self.message = message
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    let suffix = (encoder.userInfo[.decoration] as? String) ?? ""
    try container.encode(message + suffix)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let prefix = (decoder.userInfo[.decoration] as? String) ?? ""
    message = prefix + (try container.decode(String.self))
  }
}

private extension CodingUserInfoKey {
  static let decoration = CodingUserInfoKey(rawValue: "decoration")!
}
