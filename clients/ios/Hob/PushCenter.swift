import UIKit
import UserNotifications
import os

/// Owns the APNs side: the permission prompt, the device token, foreground
/// presentation, and where a tapped notification lands. hob's payload carries
/// `hob: { kind: petition|request, id }`; a tap opens that item.
final class PushCenter: NSObject {
    static let shared = PushCenter()

    private let log = Logger(subsystem: "place.amber.hob", category: "push")
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    /// Call once at launch. When already authorized, registration is re-run on
    /// every launch — Apple may rotate the token, and hob re-saves whatever it gets.
    func start() {
        center.delegate = self
        Task { @MainActor in
            if await authorizationStatus() == .authorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Prompt if never asked (a no-op once decided), then register for a token.
    @MainActor
    func enable() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return false }
            UIApplication.shared.registerForRemoteNotifications()
            return true
        } catch {
            log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Registration (fed by AppDelegate)

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        log.info("registered; token \(token.prefix(8), privacy: .public)… env=\(PushEnvironment.current, privacy: .public)")
        Task { @MainActor in
            await Session.shared.deviceTokenArrived(token)
        }
    }

    func didFail(error: Error) {
        log.error("registration failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            Session.shared.pushError = error.localizedDescription
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushCenter: UNUserNotificationCenterDelegate {
    // The completion-handler forms, not the `async` ones: an `async` delegate
    // method's thunk calls UIKit's completion handler from a background
    // executor, and UIKit crashes the app on a tap when it is not on main.

    /// A petition while the app is open still shows: the banner is how hob
    /// gets a word in without the inbox polling for it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// `hob.kind` and `hob.id` say what to open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let payload = response.notification.request.content.userInfo["hob"] as? [String: Any] ?? [:]
        let route = (payload["kind"] as? String).flatMap { kind in (payload["id"] as? String).flatMap { Route(kind: kind, id: $0) } }
        if let route {
            log.info("notification tapped; opening \(String(describing: route), privacy: .public)")
        } else {
            log.info("notification tapped without a hob link; opening the inbox")
        }
        Task { @MainActor in
            if let route { Session.shared.open(route) } else { Session.shared.path = [] }
            completionHandler()
        }
    }
}
