import SwiftUI

/// The hob companion: a notification surface for the household. When the
/// sentinel needs a person — an agent petitions for a capability, or a
/// request needs confirming — hob pushes to this app (Push on the server),
/// and the item opens here to be read, commented on, and decided.
@main
struct HobApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Session.shared)
        }
    }
}
