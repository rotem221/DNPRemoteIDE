import Foundation

public enum DNPCoders {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601withFraction
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601withFraction
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }
}
