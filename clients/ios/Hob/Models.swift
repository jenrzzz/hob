import Foundation

/// Any JSON value: arguments, specs, results. Shown, never interpreted.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var any: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) : value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null: return true
        case .string(let value): return value.isEmpty
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number, .bool: return pretty
        default: return nil
        }
    }

    /// Pretty-printed JSON, for the arguments and spec blocks.
    var pretty: String {
        if case .string(let value) = self { return value }
        guard JSONSerialization.isValidJSONObject(any) || !(self.isContainer),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8)
        else { return "\(any)" }
        return text
    }

    private var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }
}

/// An agent asking for a capability it does not have (SENTINEL.md,
/// "Petitions and the forge"). Mirrors V1::Sentinel::PetitionsController#serialize.
struct Petition: Codable, Identifiable, Hashable {
    let id: String
    let agent: String
    let want: String
    var capability: String?
    var arguments: JSONValue?
    var reason: String?
    let realm: String
    var status: String
    var action: String?
    var decidedBy: String?
    var rationale: String?
    var decider: String?
    var effect: String?
    var spec: JSONValue?
    var policy: Int?
    var mission: String?
    var pullRequest: String?
    var error: String?
    var onMission: String?
    var review: JSONValue?
    let createdAt: Date
    var decidedAt: Date?
    var settledAt: Date?

    /// A person can decide a pending petition, and re-dispatch or deny a failed build.
    var needsPerson: Bool { status == "pending" || status == "failed" }

    /// What the steward would have done, when it referred instead.
    var recommendation: String? { review?["verdict"]?.stringValue }
}

/// An agent's ask at the sentinel. Mirrors V1::Sentinel::RequestsController#serialize.
struct SentinelRequest: Codable, Identifiable, Hashable {
    let id: String
    let agent: String
    let capability: String
    var arguments: JSONValue?
    var reason: String?
    let realm: String
    var status: String
    var decision: String?
    var decidedBy: String?
    var rationale: String?
    var decider: String?
    var review: JSONValue?
    var result: JSONValue?
    var error: String?
    var mission: String?
    var onMission: String?
    let createdAt: Date
    var decidedAt: Date?
    var executedAt: Date?

    var needsPerson: Bool { status == "pending" }
}

struct DeviceRecord: Codable, Hashable {
    let id: Int
    let token: String
    let environment: String
    var name: String?
    var lastPushedAt: Date?
    var pushConfigured: Bool?
}

struct DeviceRegistration: Encodable {
    var token: String
    var environment: String
    var name: String
    var appVersion: String
    var platform = "ios"
}

struct PetitionDecision: Encodable {
    var decision: String            // grant | build | deny
    var capability: String?
    var effect: String?
    var rationale: String?
}

struct RequestDecision: Encodable {
    var decision: String            // allow | deny
    var rationale: String?
}

struct PingResult: Decodable {
    var sent: Bool
    var error: String?
}

/// Where a notification or a row leads.
enum Route: Hashable {
    case petition(String)
    case request(String)

    init?(kind: String, id: String) {
        switch kind {
        case "petition": self = .petition(id)
        case "request": self = .request(id)
        default: return nil
        }
    }
}
