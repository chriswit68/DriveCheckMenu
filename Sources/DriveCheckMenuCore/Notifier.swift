import Foundation
import UserNotifications

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var hasRequestedAuthorization = false

    public func requestAuthorization() {
        guard isAvailable, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
