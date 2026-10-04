import SwiftUI

/// Decided petitions and requests from the last month, filterable by agent,
/// capability, and status — the record of what the sentinel settled.
struct HistoryView: View {
    @Environment(Session.self) private var session

    @State private var petitions: [Petition] = []
    @State private var requests: [SentinelRequest] = []
    @State private var loading = false
    @State private var loadError: String?

    @State private var agentFilter = ""
    @State private var capabilityFilter = ""
    @State private var statusFilter = ""

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            if !items.isEmpty {
                Section("Filter") {
                    Picker("Agent", selection: $agentFilter) {
                        Text("All agents").tag("")
                        ForEach(agents, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Capability", selection: $capabilityFilter) {
                        Text("All capabilities").tag("")
                        ForEach(capabilities, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Status", selection: $statusFilter) {
                        Text("All statuses").tag("")
                        ForEach(statuses, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section("Last 30 days") {
                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        loading ? "Loading" : "Nothing here",
                        systemImage: "clock",
                        description: Text("Decided petitions and requests land here once the sentinel has settled them.")
                    )
                } else {
                    ForEach(filteredItems) { item in
                        NavigationLink(value: item.route) { InboxRow(item: item) }
                    }
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var items: [InboxItem] {
        (petitions.map(InboxItem.petition) + requests.map(InboxItem.request))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var filteredItems: [InboxItem] {
        items.filter {
            (agentFilter.isEmpty || agent(of: $0) == agentFilter)
                && (capabilityFilter.isEmpty || capability(of: $0) == capabilityFilter)
                && (statusFilter.isEmpty || status(of: $0) == statusFilter)
        }
    }

    private var agents: [String] { Set(items.map { agent(of: $0) }).sorted() }
    private var capabilities: [String] { Set(items.map { capability(of: $0) }).sorted() }
    private var statuses: [String] { Set(items.map { status(of: $0) }).sorted() }

    private func agent(of item: InboxItem) -> String {
        switch item {
        case .petition(let row): return row.agent
        case .request(let row): return row.agent
        }
    }

    private func capability(of item: InboxItem) -> String {
        switch item {
        case .petition(let row): return row.capability ?? "—"
        case .request(let row): return row.capability
        }
    }

    private func status(of item: InboxItem) -> String {
        switch item {
        case .petition(let row): return row.status
        case .request(let row): return row.status
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let settled = try await session.history()
            petitions = settled.petitions.filter { !$0.needsPerson }
            requests = settled.requests.filter { !$0.needsPerson }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
