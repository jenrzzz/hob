import SwiftUI
import UIKit

/// The app's state: the connection to hob, the inbox, navigation, and this
/// phone's push registration. One instance, on the main actor.
@MainActor
@Observable
final class Session {
    static let shared = Session()

    private(set) var client: HobClient? = Config.client()
    var isConfigured: Bool { client != nil }

    var petitions: [Petition] = []
    var requests: [SentinelRequest] = []
    var loading = false
    var loadError: String?
    var lastRefresh: Date?

    /// The navigation stack; a tapped notification replaces it with its item.
    var path: [Route] = []

    /// Set once `RootView`'s `NavigationStack` has appeared. A route opened
    /// before then — the whole point of a cold launch from a notification —
    /// is held here instead of touching `path`, which can crash pushing into
    /// a stack that SwiftUI has not yet attached to the view hierarchy.
    private var navigationReady = false
    private var pendingRoute: Route?

    // Push
    var deviceToken: String?
    var registeredDevice: DeviceRecord?
    var pushError: String?

    private init() {}

    // MARK: Connection

    /// Verify the key (GET /v1/devices needs a person's key) and keep it.
    func connect(serverURL: String, key: String) async throws {
        let url = try Self.server(serverURL)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = HobClient(baseURL: url, key: trimmedKey)
        _ = try await candidate.devices()
        await adopt(candidate)
    }

    /// Sign in through hob in a browser sheet (SignIn): `authenticate` shows
    /// the sheet and returns the hob://signed-in URL it ended on.
    func signIn(serverURL: String, authenticate: (URL) async throws -> URL) async throws {
        let url = try Self.server(serverURL)
        let request = SignIn(server: url, device: UIDevice.current.name)
        let code = try request.code(from: try await authenticate(request.url))
        let session = try await HobClient(baseURL: url, key: "").appSession(code: code, verifier: request.verifier)
        await adopt(HobClient(baseURL: url, key: session.key))
    }

    private func adopt(_ candidate: HobClient) async {
        Config.serverURL = candidate.baseURL.absoluteString
        Config.apiKey = candidate.key
        client = candidate
        registeredDevice = nil
        await registerDevice()
        await refresh()
    }

    private static func server(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.host != nil else {
            throw HobClient.Failure(status: 0, message: "That is not a URL.")
        }
        return url
    }

    func disconnect() {
        Config.apiKey = nil
        client = nil
        petitions = []
        requests = []
        registeredDevice = nil
        path = []
        pendingRoute = nil
    }

    // MARK: Inbox

    func refresh() async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            async let petitions = client.petitions()
            async let requests = client.requests()
            self.petitions = try await petitions
            self.requests = try await requests
            loadError = nil
            lastRefresh = Date()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Decided petitions and requests from the last `days`, for the History
    /// screen — kept apart from `petitions`/`requests`, which are the live
    /// inbox and would otherwise be clobbered by a History-driven refetch.
    func history(days: Int = 30) async throws -> (petitions: [Petition], requests: [SentinelRequest]) {
        guard let client else { throw HobClient.Failure(status: 0, message: "Not connected.") }
        async let petitions = client.petitions(days: days)
        async let requests = client.requests(days: days)
        return (try await petitions, try await requests)
    }

    /// Petitions and requests a person has to look at, newest first.
    var needsPerson: [InboxItem] {
        (petitions.filter(\.needsPerson).map(InboxItem.petition) + requests.filter(\.needsPerson).map(InboxItem.request))
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recent: [InboxItem] {
        (petitions.filter { !$0.needsPerson }.map(InboxItem.petition) + requests.filter { !$0.needsPerson }.map(InboxItem.request))
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(40)
            .map { $0 }
    }

    /// A tap on a notification or a `hob://` link: not signed in is a no-op
    /// (there is no inbox to open into), and before the stack exists yet the
    /// route waits for `navigationStackAppeared()`.
    func open(_ route: Route) {
        guard isConfigured else { return }
        guard navigationReady else {
            pendingRoute = route
            return
        }
        path = [route]
        Task { await refresh() }
    }

    /// `RootView`'s `NavigationStack` has appeared: open whatever route a
    /// notification tap brought along before it existed (a cold launch).
    func navigationStackAppeared() {
        navigationReady = true
        if let route = pendingRoute {
            pendingRoute = nil
            open(route)
        }
    }

    func petition(_ id: String) async throws -> Petition {
        guard let client else { throw HobClient.Failure(status: 0, message: "Not connected.") }
        let row = try await client.petition(id)
        store(row)
        return row
    }

    func request(_ id: String) async throws -> SentinelRequest {
        guard let client else { throw HobClient.Failure(status: 0, message: "Not connected.") }
        let row = try await client.request(id)
        store(row)
        return row
    }

    func decide(petition id: String, _ decision: PetitionDecision) async throws -> Petition {
        guard let client else { throw HobClient.Failure(status: 0, message: "Not connected.") }
        let row = try await client.decide(petition: id, decision)
        store(row)
        return row
    }

    func decide(request id: String, _ decision: RequestDecision) async throws -> SentinelRequest {
        guard let client else { throw HobClient.Failure(status: 0, message: "Not connected.") }
        let row = try await client.decide(request: id, decision)
        store(row)
        return row
    }

    private func store(_ row: Petition) {
        if let index = petitions.firstIndex(where: { $0.id == row.id }) { petitions[index] = row } else { petitions.insert(row, at: 0) }
    }

    private func store(_ row: SentinelRequest) {
        if let index = requests.firstIndex(where: { $0.id == row.id }) { requests[index] = row } else { requests.insert(row, at: 0) }
    }

    // MARK: Push

    /// Apple issued a token (every launch, once authorized): tell hob.
    func deviceTokenArrived(_ token: String) async {
        deviceToken = token
        pushError = nil
        await registerDevice()
    }

    func enableNotifications() async {
        pushError = nil
        if await !PushCenter.shared.enable() {
            pushError = "Notifications are off for Hob. Turn them on in Settings."
        }
    }

    func registerDevice() async {
        guard let client, let deviceToken else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        do {
            registeredDevice = try await client.register(DeviceRegistration(
                token: deviceToken, environment: PushEnvironment.current, name: UIDevice.current.name, appVersion: version
            ))
        } catch {
            pushError = "Could not register this phone with hob: \(error.localizedDescription)"
        }
    }

    /// A test notification through hob and Apple. Returns what to tell the person.
    func sendTestPush() async -> String {
        guard let client, let deviceToken else { return "No device token yet. Enable notifications first." }
        do {
            let result = try await client.ping(token: deviceToken)
            return result.sent ? "Sent. It should arrive in a moment." : (result.error ?? "hob could not send it.")
        } catch {
            return error.localizedDescription
        }
    }
}

/// A row in the inbox: either kind, with what the list needs from both.
enum InboxItem: Identifiable, Hashable {
    case petition(Petition)
    case request(SentinelRequest)

    var id: String {
        switch self {
        case .petition(let row): return "petition/\(row.id)"
        case .request(let row): return "request/\(row.id)"
        }
    }

    var route: Route {
        switch self {
        case .petition(let row): return .petition(row.id)
        case .request(let row): return .request(row.id)
        }
    }

    var createdAt: Date {
        switch self {
        case .petition(let row): return row.createdAt
        case .request(let row): return row.createdAt
        }
    }
}
