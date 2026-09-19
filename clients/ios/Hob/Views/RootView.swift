import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        if session.isConfigured {
            NavigationStack(path: $session.path) {
                InboxView()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .petition(let id): PetitionView(id: id)
                        case .request(let id): RequestView(id: id)
                        }
                    }
            }
            .onOpenURL { url in
                // hob://petition/<id>, hob://request/<id>
                if url.scheme == "hob", let kind = url.host, let id = url.pathComponents.dropFirst().first,
                   let route = Route(kind: kind, id: id) {
                    session.open(route)
                }
            }
        } else {
            NavigationStack {
                SettingsView()
            }
        }
    }
}
