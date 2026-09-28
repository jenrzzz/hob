import CryptoKit
import Foundation
import Security

/// Signing in through hob in a browser sheet instead of pasting a key: open
/// `<server>/app/sign_in` with a PKCE challenge, the person signs in (their
/// passkey, at the household's provider) and confirms, and hob redirects to
/// hob://signed-in with a one-time code that only this verifier redeems.
struct SignIn {
    static let callbackScheme = "hob"
    static let redirectURI = "hob://signed-in"

    let url: URL
    let verifier: String
    let state: String

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(server: URL, device: String) {
        verifier = Self.random(bytes: 48)
        state = Self.random(bytes: 16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var components = URLComponents(url: server.appending(path: "/app/sign_in"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device", value: device),
        ]
        url = components.url!
    }

    /// The code from hob's redirect, once the state is ours.
    func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else { throw Failure(message: "The sign-in came back for a different request. Try again.") }
        if value("error") == "access_denied" { throw Failure(message: "Sign-in was cancelled.") }
        guard let code = value("code"), !code.isEmpty else { throw Failure(message: "hob did not send a sign-in code.") }
        return code
    }

    private static func random(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
