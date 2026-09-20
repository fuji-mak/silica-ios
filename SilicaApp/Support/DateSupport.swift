import Foundation

enum DateSupport {
    // Cached formatters are immutable after construction. NSCache and
    // DateFormatter support concurrent access; keep locale/time-zone changes in the key.
    private final class FormatterCache: @unchecked Sendable {
        let values = NSCache<NSString, DateFormatter>()

        init() {
            values.countLimit = 16
        }
    }

    private static let formatterCache = FormatterCache()

    private static func formatter(
        for kind: String,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        let key = "\(kind)|\(AppLanguage.currentLocale.identifier)|\(TimeZone.current.identifier)|\(Calendar.current.identifier)" as NSString
        if let cached = formatterCache.values.object(forKey: key) {
            return cached
        }
        let formatter = DateFormatter()
        configure(formatter)
        formatterCache.values.setObject(formatter, forKey: key)
        return formatter
    }

    static func dayInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date
        return DateInterval(start: start, end: end)
    }

    static func overlaps(
        arrivalAt: Date,
        departureAt: Date?,
        dayInterval: DateInterval,
        now: Date
    ) -> Bool {
        StayOverlapPolicy.overlaps(
            arrivalAt: arrivalAt,
            departureAt: departureAt,
            intervalStart: dayInterval.start,
            intervalEnd: dayInterval.end,
            now: now
        )
    }

    static func formatDay(_ date: Date) -> String {
        let formatter = formatter(for: "day") { formatter in
            formatter.locale = AppLanguage.currentLocale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    static func formatISODate(_ date: Date) -> String {
        let formatter = formatter(for: "iso") { formatter in
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }

    static func formatDateTime(_ date: Date) -> String {
        let formatter = formatter(for: "dateTime") { formatter in
            formatter.locale = AppLanguage.currentLocale
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = AppLanguage.current == .english
                ? "MMM d, yyyy h:mm a"
                : "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    private static func makeTimeFormatter() -> DateFormatter {
        formatter(for: "time") { formatter in
            formatter.locale = AppLanguage.currentLocale
            formatter.timeStyle = .short
        }
    }

    static func formatTime(
        _ date: Date,
        displayDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        formatTimeWithRelativeDay(
            date,
            displayDate: displayDate,
            calendar: calendar,
            timeFormatter: makeTimeFormatter()
        )
    }

    static func formatTimeRange(start: Date, end: Date?, displayDate: Date = Date(), calendar: Calendar = .current) -> String {
        let timeFormatter = makeTimeFormatter()
        let formattedEnd = end.map {
            formatTimeWithRelativeDay(
                $0,
                displayDate: displayDate,
                calendar: calendar,
                timeFormatter: timeFormatter
            )
        } ?? AppLanguage.localized("滞在中")
        let formattedStart = formatTimeWithRelativeDay(
            start,
            displayDate: displayDate,
            calendar: calendar,
            timeFormatter: timeFormatter
        )
        return "\(formattedStart)-\(formattedEnd)"
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int((duration / 60).rounded()))
        guard totalMinutes > 0 else {
            return AppLanguage.localized("1分未満")
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return AppLanguage.current == .english
                ? "\(minutes) min"
                : "\(minutes)分"
        }
        if minutes == 0 {
            return AppLanguage.current == .english
                ? "\(hours) hr"
                : "\(hours)時間"
        }
        return AppLanguage.current == .english
            ? "\(hours) hr \(minutes) min"
            : "\(hours)時間\(minutes)分"
    }

    private static func formatTimeWithRelativeDay(
        _ date: Date,
        displayDate: Date,
        calendar: Calendar,
        timeFormatter: DateFormatter
    ) -> String {
        let time = timeFormatter.string(from: date)
        guard !calendar.isDate(date, inSameDayAs: displayDate) else {
            return time
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: displayDate)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return AppLanguage.current == .english
                ? "\(time) (previous day)"
                : "\(time)（前日）"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: displayDate)),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return AppLanguage.current == .english
                ? "\(time) (next day)"
                : "\(time)（翌日）"
        }

        return AppLanguage.current == .english
            ? "\(time) (\(formatDay(date)))"
            : "\(time)（\(formatDay(date))）"
    }
}
