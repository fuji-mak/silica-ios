import Foundation

public enum ProTrialStatus: Equatable, Sendable {
    case notStarted
    case active(expiresAt: Date)
    case expired(expiresAt: Date)

    public var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }

    public var expirationDate: Date? {
        switch self {
        case .notStarted:
            nil
        case .active(let expiresAt), .expired(let expiresAt):
            expiresAt
        }
    }
}

public enum ProTrialAccessPolicy {
    public static let duration: TimeInterval = 7 * 24 * 60 * 60
    public static let notificationHour = 10

    public static func status(
        startedAt: Date?,
        relativeTo referenceDate: Date
    ) -> ProTrialStatus {
        guard let startedAt else {
            return .notStarted
        }
        let expiresAt = startedAt.addingTimeInterval(duration)
        return referenceDate < expiresAt
            ? .active(expiresAt: expiresAt)
            : .expired(expiresAt: expiresAt)
    }

    public static func reminderNotificationDate(
        forExpirationDate expirationDate: Date,
        calendar: Calendar
    ) -> Date? {
        guard let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: expirationDate)
        ) else {
            return nil
        }
        return calendar.date(
            bySettingHour: notificationHour,
            minute: 0,
            second: 0,
            of: nextDay
        )
    }
}

public enum SavedPlaceAccessPolicy {
    public static let freePlaceLimit = 3

    public static func requiresPro(
        existingPlaceCount: Int,
        isProActive: Bool
    ) -> Bool {
        isProActive == false && existingPlaceCount >= freePlaceLimit
    }
}

public enum LocationHistoryAccessPolicy {
    public static let freeVisibleDayCount = 31

    public static func oldestFreeDate(
        relativeTo referenceDate: Date,
        calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        return calendar.date(
            byAdding: .day,
            value: -(freeVisibleDayCount - 1),
            to: today
        ) ?? today
    }

    public static func requiresPro(
        viewing date: Date,
        relativeTo referenceDate: Date,
        calendar: Calendar,
        isProActive: Bool
    ) -> Bool {
        guard isProActive == false else {
            return false
        }
        return calendar.startOfDay(for: date)
            < oldestFreeDate(relativeTo: referenceDate, calendar: calendar)
    }
}

public enum AutomaticExportDatePolicy {
    public static func eligibleDates(
        _ dates: [Date],
        startingOn firstDate: Date,
        relativeTo now: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        let start = calendar.startOfDay(for: firstDate)
        let today = calendar.startOfDay(for: now)
        return Array(Set(dates.map { calendar.startOfDay(for: $0) }))
            .filter { $0 >= start && $0 < today }
            .sorted()
    }
}

public enum AutomaticExportNotificationPolicy {
    public static func isEnabled(storedValue: Bool?) -> Bool {
        storedValue ?? true
    }

    public static func shouldNotify(
        notificationsEnabled: Bool,
        exportDate: Date,
        lastNotifiedExportDate: Date? = nil,
        relativeTo referenceDate: Date,
        calendar: Calendar
    ) -> Bool {
        guard notificationsEnabled else {
            return false
        }
        if let lastNotifiedExportDate,
           calendar.isDate(exportDate, inSameDayAs: lastNotifiedExportDate) {
            return false
        }
        let today = calendar.startOfDay(for: referenceDate)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return false
        }
        return calendar.isDate(exportDate, inSameDayAs: yesterday)
    }
}
