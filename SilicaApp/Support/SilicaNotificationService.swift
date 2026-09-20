import Foundation
import UserNotifications

final class SilicaNotificationService: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    static let shared = SilicaNotificationService()
    private static let proTrialExpiredNotificationIdentifier =
        "com.fujimakitaketo.silica.pro-trial-expired"
    private static let proTrialReminderNotificationIdentifier =
        "com.fujimakitaketo.silica.pro-trial-ended"

    private override init() {
        super.init()
    }

    static func configure() {
        UNUserNotificationCenter.current().delegate = shared
    }

    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied, .ephemeral:
            return false
        @unknown default:
            return false
        }
    }

    static func notifyAutomaticExportSucceeded(
        destination: ExportDestination,
        date: Date
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return
        }

        let dateText = DateSupport.formatISODate(date)
        let content = UNMutableNotificationContent()
        content.title = AppLanguage.localized("自動出力が完了しました")
        content.body = String(
            format: AppLanguage.localized(
                destination == .obsidian ? "自動出力完了Markdown" : "自動出力完了Notion"
            ),
            dateText
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.fujimakitaketo.silica.automatic-export.\(destination.rawValue).\(dateText)",
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }

    static func scheduleProTrialNotifications(
        expirationDate: Date,
        relativeTo referenceDate: Date = Date()
    ) async {
        guard let reminderDate = ProTrialAccessPolicy.reminderNotificationDate(
            forExpirationDate: expirationDate,
            calendar: .current
        ) else {
            return
        }
        guard await requestAuthorizationIfNeeded() else {
            return
        }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [
                proTrialExpiredNotificationIdentifier,
                proTrialReminderNotificationIdentifier,
            ]
        )

        let content = UNMutableNotificationContent()
        content.title = AppLanguage.localized("Silica Pro体験が終了しました")
        content.body = AppLanguage.localized(
            "自動出力とすべての履歴を引き続き利用するには、Silica Proをご利用ください。"
        )
        content.sound = .default

        let notifications = [
            (proTrialExpiredNotificationIdentifier, expirationDate),
            (proTrialReminderNotificationIdentifier, reminderDate),
        ]
        for (identifier, notificationDate) in notifications
        where notificationDate > referenceDate {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: notificationDate
            )
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
            )
            try? await center.add(request)
        }
    }

    static func cancelProTrialReminderNotification() {
        let center = UNUserNotificationCenter.current()
        let identifiers = [proTrialReminderNotificationIdentifier]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func cancelProTrialNotifications() {
        let center = UNUserNotificationCenter.current()
        let identifiers = [
            proTrialExpiredNotificationIdentifier,
            proTrialReminderNotificationIdentifier,
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == Self.proTrialExpiredNotificationIdentifier {
            Self.cancelProTrialReminderNotification()
        }
        return [.banner, .sound]
    }
}
