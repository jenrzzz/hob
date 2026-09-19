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
    /// A petition while the app is open still shows: the banner is how hob
    /// gets a word in without the inbox polling for it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// `hob.kind` and `hob.id` say what to open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let payload = response.notification.request.content.userInfo["hob"] as? [String: Any] ?? [:]
        guard let kind = payload["kind"] as? String, let id = payload["id"] as? String,
              let route = Route(kind: kind, id: id)
        else {
            log.info("notification tapped without a hob link; opening the inbox")
            await MainActor.run { Session.shared.path = [] }
            return
        }
        log.info("notification tapped; opening \(kind, privacy: .public) \(id, privacy: .public)")
        await MainActor.run { Session.shared.open(route) }
    }
}
