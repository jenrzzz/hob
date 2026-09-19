import Foundation

/// Which APNs host hob must use for this install's token — reported with the
/// token when the app registers it, because a sandbox token sent to the
/// production host is `BadDeviceToken` and vice versa.
enum PushEnvironment {
    /// "sandbox" or "production".
    ///
    /// Read from the `aps-environment` entitlement in the embedded provisioning
    /// profile: a development-signed build (Xcode → phone) says `development` and
    /// pushes through the sandbox; App Store and TestFlight builds carry no profile
    /// and use production. The simulator (Apple silicon, Xcode 14+) is sandbox.
    static var current: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .isoLatin1),
            let range = text.range(
                of: #"<key>aps-environment</key>\s*<string>(\w+)</string>"#,
                options: .regularExpression
            )
        else {
            return "production"
        }
        return text[range].contains("development") ? "sandbox" : "production"
        #endif
    }
}
