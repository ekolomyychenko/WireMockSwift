import Foundation

/// A type-erased JSON value that round-trips losslessly through `Codable`.
///
/// Used wherever WireMock accepts arbitrary JSON — `jsonBody`, the operand of
/// `equalToJson`, stub `metadata`, transformer parameters, etc. Conforms to the
/// `ExpressibleBy*Literal` family so you can write JSON inline:
///
/// ```swift
/// let body: JSONValue = ["id": 1, "tags": ["a", "b"], "active": true]
/// ```
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    /// A number that does not fit `Int` and must preserve full precision — a
    /// value larger than `Int64.max` (e.g. a 20-digit id) or a high-precision
    /// decimal. Decoded JSON numbers land here (rather than a lossy `Double`)
    /// so `jsonBody` and the `equalToJson` operand match Java/Jackson
    /// `BigInteger`/`BigDecimal` byte-for-byte. `Decimal` holds up to 38
    /// significant digits; anything beyond that (rare in mock bodies) still
    /// falls back to `Double`.
    case decimal(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // JSON has one number type: `1` and `1.0` are the same value. Compare and
    // hash numbers by magnitude so a round-trip through the wire (where `90.0`
    // serialises as `90`, and a decoded integer arrives as `.decimal`) doesn't
    // spuriously differ across the `.int`/`.double`/`.decimal` representations.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.decimal(a), .decimal(b)): return a == b
        case let (.int(a), .double(b)): return Double(a) == b
        case let (.double(a), .int(b)): return a == Double(b)
        case let (.int(a), .decimal(b)): return Decimal(a) == b
        case let (.decimal(a), .int(b)): return a == Decimal(b)
        case let (.double(a), .decimal(b)): return a == NSDecimalNumber(decimal: b).doubleValue
        case let (.decimal(a), .double(b)): return NSDecimalNumber(decimal: a).doubleValue == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        // Hash every number by its `Double` magnitude so equal values across
        // `.int`/`.double`/`.decimal` collide into the same bucket (required by
        // the cross-representation `==` above). Distinct high-precision values
        // may share a hash — a permitted collision, not an equality violation.
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(Double(value))
        case .double(let value): hasher.combine(value)
        case .decimal(let value): hasher.combine(NSDecimalNumber(decimal: value).doubleValue)
        case .string(let value): hasher.combine(value)
        case .array(let value): hasher.combine(value)
        case .object(let value): hasher.combine(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let dbl = try? container.decode(Double.self) {
            // Confirmed numeric (a non-number would have failed the Double
            // decode). Prefer a precision-preserving `Decimal` — it reads the raw
            // number token rather than routing through `Double`, so >Int64 ints
            // and long decimals survive. `Decimal` is attempted only *after*
            // Double succeeds: decoding `Decimal` from a non-number value traps
            // (rather than throwing cleanly) on the older Darwin Foundation, so
            // it must never be tried on a string/bool/array/object. Fall back to
            // `.double` for numbers outside `Decimal`'s range (e.g. `1e128`).
            if let dec = try? container.decode(Decimal.self) {
                self = .decimal(dec)
            } else {
                self = .double(dbl)
            }
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Literal conformances

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    /// Parses a raw JSON string into a `JSONValue`, or returns `nil` if invalid.
    public init?(parsing json: String) {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        self = value
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The value as a `Decimal`, for any numeric case (`.int`/`.double`/`.decimal`).
    /// Use this to read a number without caring which representation it decoded into.
    public var decimalValue: Decimal? {
        switch self {
        case .int(let value): return Decimal(value)
        case .double(let value): return Decimal(value)
        case .decimal(let value): return value
        default: return nil
        }
    }

    /// The value as a `Double`, for any numeric case. Note this is lossy for
    /// `.decimal` values beyond `Double`'s precision — prefer `decimalValue` there.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .decimal(let value): return NSDecimalNumber(decimal: value).doubleValue
        default: return nil
        }
    }

    /// The value as an `Int`, only when it is an exact integer within `Int` range.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(exactly: value)
        case .decimal(let value):
            var v = value
            var rounded = Decimal()
            NSDecimalRound(&rounded, &v, 0, .plain)
            // Only when it's a whole number that also fits `Int` exactly —
            // otherwise `NSDecimalNumber.intValue` would clamp/overflow silently.
            guard rounded == value, value <= Decimal(Int.max), value >= Decimal(Int.min) else { return nil }
            return NSDecimalNumber(decimal: value).intValue
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
