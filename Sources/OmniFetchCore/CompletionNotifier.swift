import Foundation
import UserNotifications

/// Posts a local notification when a download finishes.
///
/// Local notifications need a real app bundle, so the command line binary
/// skips them; the user can also turn them off in settings.
public enum CompletionNotifier {
    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public static func notifyDownloadFinished(title: String, location: String) {
        guard isAvailable else { return }
        guard SettingsStore.load().notifyOnCompletion ?? true else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                deliver(title: title, location: location, center: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    deliver(title: title, location: location, center: center)
                }
            default:
                break
            }
        }
    }

    private static func deliver(title: String, location: String,
                                center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = title
        content.sound = .default
        content.userInfo = ["path": location]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }
}
