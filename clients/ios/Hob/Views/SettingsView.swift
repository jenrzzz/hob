import AuthenticationServices
import SwiftUI
import UserNotifications

/// Where hob is, whose key this is, and whether this phone can be reached.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var serverURL = Config.serverURL
    @State private var apiKey = Config.apiKey ?? ""
    @State private var connecting = false
    @State private var signingIn = false
    @State private var usingKey = false
    @State private var connectError: String?
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var pingResult: String?

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $serverURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Spacer()
                        if signingIn { ProgressView() } else { Text(session.isConfigured ? "Sign in again" : "Sign in").bold() }
                        Spacer()
                    }
                }
                .disabled(signingIn || connecting)
                if let connectError {
                    Text(connectError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("hob")
            } footer: {
                Text("Sign in with your passkey in hob's sign-in sheet. This phone gets its own key, which you can revoke from hob's admin page.")
            }

            Section {
                DisclosureGroup("Use a key instead", isExpanded: $usingKey) {
                    SecureField("Your hob key (hob_…)", text: $apiKey)
                        .textContentType(.password)
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if connecting { ProgressView() } else { Text(session.isConfigured ? "Reconnect" : "Connect").bold() }
                            Spacer()
                        }
                    }
                    .disabled(connecting || signingIn || apiKey.isEmpty)
                }
            } footer: {
                if usingKey {
                    Text("A person's key: mint one on hob's admin page, or with bin/rails \"hob:key[jenner,phone]\". Agent and surface keys cannot decide petitions.")
                }
            }

            if session.isConfigured {
                Section {
                    LabeledContent("Permission", value: permissionText)
                    LabeledContent("Environment", value: PushEnvironment.current)
                    LabeledContent("Token", value: session.deviceToken.map { String($0.prefix(8)) + "…" } ?? "none yet")
                    LabeledContent("Registered with hob", value: session.registeredDevice != nil ? "yes" : "no")
                    if session.registeredDevice?.pushConfigured == false {
                        Text("hob has no APNs key: set APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID on the hob box.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let error = session.pushError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if authorization == .denied {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    } else if authorization != .authorized || session.deviceToken == nil {
                        Button("Enable notifications") {
                            Task {
                                await session.enableNotifications()
                                authorization = await PushCenter.shared.authorizationStatus()
                            }
                        }
                    } else {
                        Button("Send a test notification") {
                            pingResult = nil
                            Task { pingResult = await session.sendTestPush() }
                        }
                        if let pingResult {
                            Text(pingResult).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Notifications")
                }

                Section {
                    Button("Forget this key", role: .destructive) {
                        session.disconnect()
                        apiKey = ""
                    }
                } footer: {
                    Text("Hob \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · hob companion")
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            if session.isConfigured {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { authorization = await PushCenter.shared.authorizationStatus() }
    }

    private var permissionText: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "not asked"
        }
    }

    private func connect() async {
        connecting = true
        connectError = nil
        defer { connecting = false }
        do {
            try await session.connect(serverURL: serverURL, key: apiKey)
            await connected()
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func signIn() async {
        signingIn = true
        connectError = nil
        defer { signingIn = false }
        do {
            try await session.signIn(serverURL: serverURL) { url in
                try await webAuthenticationSession.authenticate(
                    using: url, callbackURLScheme: SignIn.callbackScheme, preferredBrowserSession: .shared
                )
            }
            apiKey = ""
            await connected()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed the sheet: nothing to say.
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func connected() async {
        authorization = await PushCenter.shared.authorizationStatus()
        if authorization == .notDetermined { await session.enableNotifications() }
        authorization = await PushCenter.shared.authorizationStatus()
        if session.path.isEmpty { dismiss() }
    }
}
