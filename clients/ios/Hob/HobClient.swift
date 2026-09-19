import Foundation

/// hob's HTTP API with a person's key: the sentinel's petitions and requests,
/// and this phone's registration. Errors carry hob's own `error` message.
struct HobClient: Sendable {
    let baseURL: URL
    let key: String

    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "not a date: \(text)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    // MARK: Sentinel

    func petitions(status: String? = nil) async throws -> [Petition] {
        try await get("/v1/sentinel/petitions", query: status.map { [URLQueryItem(name: "status", value: $0)] } ?? [])
    }

    func petition(_ id: String) async throws -> Petition {
        try await get("/v1/sentinel/petitions/\(id)")
    }

    func decide(petition id: String, _ decision: PetitionDecision) async throws -> Petition {
        try await post("/v1/sentinel/petitions/\(id)/decide", body: decision)
    }

    func requests(status: String? = nil) async throws -> [SentinelRequest] {
        try await get("/v1/sentinel/requests", query: status.map { [URLQueryItem(name: "status", value: $0)] } ?? [])
    }

    func request(_ id: String) async throws -> SentinelRequest {
        try await get("/v1/sentinel/requests/\(id)")
    }

    func decide(request id: String, _ decision: RequestDecision) async throws -> SentinelRequest {
        try await post("/v1/sentinel/requests/\(id)/decide", body: decision)
    }

    // MARK: Devices

    func devices() async throws -> [DeviceRecord] {
        try await get("/v1/devices")
    }

    func register(_ device: DeviceRegistration) async throws -> DeviceRecord {
        try await post("/v1/devices", body: device)
    }

    func ping(token: String) async throws -> PingResult {
        try await post("/v1/devices/\(token)/ping", body: Empty())
    }

    // MARK: HTTP

    private struct Empty: Encodable {}

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(build(path, query: query))
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = build(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return try await send(request)
    }

    private func build(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure(status: status, message: message ?? "hob answered HTTP \(status)")
        }
        // Some replies are wrapped in hob's own error shape with a 2xx (a refused completion); not ours.
        return try Self.decoder.decode(T.self, from: data)
    }
}
