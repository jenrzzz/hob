import SwiftUI

/// What the sentinel is holding for a person, then what it decided lately.
struct InboxView: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        List {
            if let error = session.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section("Needs you") {
                if session.needsPerson.isEmpty {
                    ContentUnavailableView(
                        session.loading && session.lastRefresh == nil ? "Loading" : "Nothing waiting",
                        systemImage: "checkmark.seal",
                        description: Text("Petitions and requests that need a person land here, and on the lock screen.")
                    )
                } else {
                    ForEach(session.needsPerson) { item in
                        NavigationLink(value: item.route) { InboxRow(item: item) }
                    }
                }
            }
            if !session.recent.isEmpty {
                Section("Recent") {
                    ForEach(session.recent) { item in
                        NavigationLink(value: item.route) { InboxRow(item: item) }
                    }
                }
            }
        }
        .navigationTitle("Hob")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .refreshable { await session.refresh() }
        .task { await session.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.refresh() } }
        }
    }
}

struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agent).font(.subheadline.weight(.semibold))
                Text(kind).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                StatusBadge(status: status)
            }
            Text(headline).font(.body).lineLimit(3)
            Text(item.createdAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var agent: String {
        switch item {
        case .petition(let row): return row.agent
        case .request(let row): return row.agent
        }
    }

    private var kind: String {
        switch item {
        case .petition: return "petitions"
        case .request(let row): return "asks for \(row.capability)"
        }
    }

    private var status: String {
        switch item {
        case .petition(let row): return row.status
        case .request(let row): return row.status
        }
    }

    private var headline: String {
        switch item {
        case .petition(let row): return row.want
        case .request(let row): return row.reason ?? row.arguments?.pretty ?? row.capability
        }
    }
}
