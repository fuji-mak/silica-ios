import Foundation

public struct MovementLogRecord: Equatable, Sendable {
    public var departureAt: Date
    public var arrivalAt: Date
    public var modeLabels: [String]
    public var timingKind: MovementTimingKind
    public var duration: TimeInterval?
    public var distanceMeters: Double?
    public var stepCount: Int?
    public var distanceIsStraightLineReference: Bool

    public init(
        departureAt: Date,
        arrivalAt: Date,
        modeLabels: [String] = [],
        timingKind: MovementTimingKind = .measured,
        duration: TimeInterval? = nil,
        distanceMeters: Double? = nil,
        stepCount: Int? = nil,
        distanceIsStraightLineReference: Bool = false
    ) {
        self.departureAt = departureAt
        self.arrivalAt = arrivalAt
        self.modeLabels = modeLabels
        self.timingKind = timingKind
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.stepCount = stepCount
        self.distanceIsStraightLineReference = distanceIsStraightLineReference
    }
}

public struct MarkdownLocationExporter: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var timeZone: TimeZone

    public init(
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "ja_JP"),
        timeZone: TimeZone = .current
    ) {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
    }

    public func render(
        date: Date,
        stays: [StayRecord],
        movements: [MovementLogRecord] = []
    ) -> String {
        let dayFormatter = makeDayFormatter()
        let timeFormatter = makeTimeFormatter()
        let day = dayFormatter.string(from: date)
        let stayRows = stays.map { stay in
            let place = firstNonEmpty(stay.placeName, stay.address)
                ?? fallbackPlaceName(for: stay)
            let end = stay.departureAt ?? endOfDay(for: date)
            let duration = formatDuration(max(0, end.timeIntervalSince(stay.arrivalAt)))
            let timeRange = formatTimeRange(
                start: stay.arrivalAt,
                end: end,
                day: date,
                dayFormatter: dayFormatter,
                timeFormatter: timeFormatter
            )
            return TimelineRow(
                timestamp: stay.arrivalAt,
                markdown: "| \(timeRange) | \(escape(place)) | \(duration) |"
            )
        }
        let movementRows = movements.compactMap { movement -> TimelineRow? in
            guard movement.timingKind == .unavailable ||
                    movement.arrivalAt > movement.departureAt else {
                return nil
            }
            let timeRange: String
            let duration: String
            if movement.timingKind != .unavailable {
                timeRange = formatTimeRange(
                    start: movement.departureAt,
                    end: movement.arrivalAt,
                    day: date,
                    dayFormatter: dayFormatter,
                    timeFormatter: timeFormatter
                )
                let formattedDuration = formatDuration(
                    movement.duration ??
                        movement.arrivalAt.timeIntervalSince(movement.departureAt)
                )
                duration = formattedDuration
            } else {
                let arrival = formatTimeWithRelativeDay(
                    movement.arrivalAt,
                    day: date,
                    dayFormatter: dayFormatter,
                    timeFormatter: timeFormatter
                )
                timeRange = usesEnglish ? "around \(arrival)" : "\(arrival)頃"
                duration = "—"
            }
            return TimelineRow(
                timestamp: movement.timingKind != .unavailable
                    ? movement.departureAt
                    : movement.arrivalAt,
                markdown: "| \(timeRange) | \(movementLabel(for: movement)) | \(duration) |"
            )
        }
        let rows = (stayRows + movementRows)
            .sorted { lhs, rhs in lhs.timestamp < rhs.timestamp }
            .map(\.markdown)
            .joined(separator: "\n")

        return """
        ---
        title: \(day) location log
        source_type: location_log
        date: \(day)
        app: Silica
        ---

        ## \(locationLogTitle)

        | \(timeColumnTitle) | \(entryColumnTitle) | \(durationColumnTitle) |
        | --- | --- | ---: |
        \(rows)
        """
    }

    public func fileName(for date: Date) -> String {
        "\(makeDayFormatter().string(from: date))-location.md"
    }

    private func makeDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func makeTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private func formatTimeRange(
        start: Date,
        end: Date,
        day: Date,
        dayFormatter: DateFormatter,
        timeFormatter: DateFormatter
    ) -> String {
        let formattedStart = formatTimeWithRelativeDay(
            start,
            day: day,
            dayFormatter: dayFormatter,
            timeFormatter: timeFormatter
        )
        let formattedEnd = formatTimeWithRelativeDay(
            end,
            day: day,
            dayFormatter: dayFormatter,
            timeFormatter: timeFormatter
        )
        return "\(formattedStart)-\(formattedEnd)"
    }

    private func formatTimeWithRelativeDay(
        _ date: Date,
        day: Date,
        dayFormatter: DateFormatter,
        timeFormatter: DateFormatter
    ) -> String {
        let time = timeFormatter.string(from: date)
        guard !calendar.isDate(date, inSameDayAs: day) else {
            return time
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfDay(for: day)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return usesEnglish ? "\(time) (previous day)" : "\(time)（前日）"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay(for: day)),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return usesEnglish ? "\(time) (next day)" : "\(time)（翌日）"
        }

        let relativeDay = dayFormatter.string(from: date)
        return usesEnglish ? "\(time) (\(relativeDay))" : "\(time)（\(relativeDay)）"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration > 0, duration < 60 {
            return usesEnglish ? "<1m" : "1m未満"
        }
        let minutes = max(0, Int(duration / 60))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 {
            return "\(remainingMinutes)m"
        }
        return "\(hours)h\(String(format: "%02dm", remainingMinutes))"
    }

    private func fallbackPlaceName(for stay: StayRecord) -> String {
        let lat = String(format: "%.5f", stay.coordinate.latitude)
        let lon = String(format: "%.5f", stay.coordinate.longitude)
        return usesEnglish
            ? "Unknown: \(lat), \(lon)"
            : "未確定: \(lat), \(lon)"
    }

    private var usesEnglish: Bool {
        locale.language.languageCode?.identifier == "en"
    }

    private var locationLogTitle: String {
        usesEnglish ? "Location Log" : "位置ログ"
    }

    private var timeColumnTitle: String {
        usesEnglish ? "Time" : "時刻"
    }

    private var entryColumnTitle: String {
        usesEnglish ? "Entry" : "内容"
    }

    private var durationColumnTitle: String {
        usesEnglish ? "Duration" : "所要時間"
    }

    private func movementLabel(for movement: MovementLogRecord) -> String {
        let baseLabel = usesEnglish ? "Movement" : "移動"
        var details = movement.modeLabels
        if let distanceMeters = movement.distanceMeters {
            let distance = formatDistance(distanceMeters)
            if movement.distanceIsStraightLineReference {
                details.append(usesEnglish
                    ? "approx. \(distance) straight-line"
                    : "直線約\(distance)")
            } else {
                details.append(usesEnglish ? "approx. \(distance)" : "約\(distance)")
            }
        }
        if let stepCount = movement.stepCount, stepCount > 0 {
            details.append(usesEnglish ? "\(stepCount) steps" : "\(stepCount)歩")
        }
        guard details.isEmpty == false else {
            return baseLabel
        }
        if usesEnglish {
            return "\(baseLabel) (\(details.joined(separator: ", ")))"
        }
        return "\(baseLabel)（\(details.joined(separator: "・"))）"
    }

    private func formatDistance(_ distanceMeters: Double) -> String {
        let distance = max(0, distanceMeters)
        if distance < 100 {
            return "100 m未満"
        }
        if distance < 1_000 {
            let rounded = Int((distance / 50).rounded()) * 50
            return "\(rounded) m"
        }
        return String(format: "%.1f km", distance / 1_000)
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else {
                return false
            }
            return value.isEmpty == false
        } ?? nil
    }

    private func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func endOfDay(for date: Date) -> Date {
        calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay(for: date)) ?? date
    }

    private struct TimelineRow {
        let timestamp: Date
        let markdown: String
    }
}

public enum MarkdownFileWriter {
    @discardableResult
    public static func writeIfChanged(_ markdown: String, to outputURL: URL) throws -> Bool {
        if let existingMarkdown = try? String(contentsOf: outputURL, encoding: .utf8),
           existingMarkdown == markdown {
            return false
        }

        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return true
    }
}
