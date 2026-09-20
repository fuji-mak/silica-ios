import Observation
import SwiftData
import SwiftUI
import UIKit

private struct TimelineMovementPresentation {
    let distanceMeters: Double?
    let distanceSource: MovementDistanceSource
    let timingKind: MovementTimingKind
    let interval: DateInterval?
    let duration: TimeInterval?
    let stepCount: Int?
    let persistedModes: [MovementMode]
}

private enum TimelineNodeKind {
    case stay
    case movement
}

private enum TimelineItem {
    case confirmed(StayEntity)
    case provisional(StayCandidateEntity)

    var id: UUID {
        switch self {
        case .confirmed(let stay): stay.id
        case .provisional(let candidate): candidate.id
        }
    }

    var arrivalAt: Date {
        switch self {
        case .confirmed(let stay): stay.arrivalAt
        case .provisional(let candidate): candidate.arrivalAt
        }
    }
}

private let timelineRowBottomSpacing: CGFloat = 22

private struct LogDaySnapshot {
    let stays: [StayEntity]
    let previousStay: StayEntity?
    let movementPoints: [MovementPointEntity]
    let pendingCandidates: [StayCandidateEntity]
}

@MainActor
@Observable
private final class LogDayDataStore {
    private var snapshots: [Date: LogDaySnapshot] = [:]

    func snapshot(for date: Date) -> LogDaySnapshot? {
        snapshots[Calendar.current.startOfDay(for: date)]
    }

    func invalidate() {
        snapshots.removeAll()
    }

    func retainDays(around date: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -3, to: day),
              let end = calendar.date(byAdding: .day, value: 3, to: day) else { return }
        let obsoleteDays = snapshots.keys.filter { $0 < start || $0 > end }
        for day in obsoleteDays {
            snapshots.removeValue(forKey: day)
        }
    }

    @discardableResult
    func load(_ date: Date, in modelContext: ModelContext) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        guard snapshots[day] == nil else {
            return true
        }

        // Future dates only provide visual breathing room in the date selector.
        // They have no log data, so do not fetch ongoing stays or movement points.
        guard day <= calendar.startOfDay(for: Date()) else {
            return true
        }

        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let pointStart = calendar.date(byAdding: .hour, value: -6, to: day) ?? day
        let pointEnd = calendar.date(byAdding: .hour, value: 6, to: dayEnd) ?? dayEnd

        do {
            let pendingState = StayCandidateState.pending.rawValue
            let staysDescriptor = FetchDescriptor<StayEntity>(
                predicate: #Predicate { stay in
                    stay.arrivalAt < dayEnd && (stay.departureAt ?? day) >= day
                },
                sortBy: [SortDescriptor(\StayEntity.arrivalAt)]
            )
            let pointsDescriptor = FetchDescriptor<MovementPointEntity>(
                predicate: #Predicate { point in
                    point.timestamp >= pointStart && point.timestamp <= pointEnd
                },
                sortBy: [SortDescriptor(\MovementPointEntity.timestamp)]
            )
            let candidatesDescriptor = FetchDescriptor<StayCandidateEntity>(
                predicate: #Predicate { candidate in
                    candidate.arrivalAt < dayEnd &&
                        candidate.stateRawValue == pendingState
                },
                sortBy: [SortDescriptor(\StayCandidateEntity.arrivalAt)]
            )
            var previousStayDescriptor = FetchDescriptor<StayEntity>(
                predicate: #Predicate { stay in
                    stay.arrivalAt < day
                },
                sortBy: [SortDescriptor(\StayEntity.arrivalAt, order: .reverse)]
            )
            previousStayDescriptor.fetchLimit = 8
            let fetchedStays = try modelContext.fetch(staysDescriptor)
            let previousStay = try modelContext.fetch(previousStayDescriptor).first { priorStay in
                fetchedStays.contains(where: { $0.id == priorStay.id }) == false
            }
            snapshots[day] = LogDaySnapshot(
                stays: fetchedStays,
                previousStay: previousStay,
                movementPoints: try modelContext.fetch(pointsDescriptor),
                pendingCandidates: try modelContext.fetch(candidatesDescriptor)
            )
            return true
        } catch {
            return false
        }
    }
}

@MainActor
@Observable
private final class LogDateHeaderScrollState {
    private var offsets: [Date: CGFloat] = [:]

    func offset(for date: Date) -> CGFloat {
        offsets[Calendar.current.startOfDay(for: date)] ?? 0
    }

    func update(_ offset: CGFloat, for date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard abs((offsets[day] ?? 0) - offset) > 2 else {
            return
        }
        offsets[day] = offset
    }
}

private struct TimelineRail: View {
    let nodeKind: TimelineNodeKind
    let startsTimeline: Bool
    let endsTimeline: Bool
    var tint: Color = .accentColor
    var symbolName: String? = nil

    var body: some View {
        GeometryReader { proxy in
            let centerX = proxy.size.width / 2
            let centerY = proxy.size.height / 2

            Path { path in
                path.move(to: CGPoint(x: centerX, y: startsTimeline ? centerY : 0))
                path.addLine(to: CGPoint(x: centerX, y: endsTimeline ? centerY : proxy.size.height))
            }
            .stroke(.primary.opacity(0.18), lineWidth: 1)

            timelineNode
                .position(x: centerX, y: centerY)
        }
        .frame(width: 36)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var timelineNode: some View {
        switch nodeKind {
        case .stay:
            if let symbolName {
                ZStack {
                    Circle()
                        .fill(tint)

                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .frame(width: 36, height: 36)
                }
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle()
                            .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                    }
            }
        case .movement:
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: 13, height: 13)
                .overlay {
                    Circle()
                        .stroke(.secondary, lineWidth: 1.25)
                }
        }
    }
}

private struct TimelineRowSpacer: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.18))
            .frame(width: 1, height: timelineRowBottomSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 17.5)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct LogDateSelector: View {
    let selectedDate: Date
    let availableDateRange: ClosedRange<Date>
    let onSelect: (Date) -> Void
    let onOpenPicker: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectorDays: [Date]
    @State private var visibleDate: Date?
    @State private var lastPlacedDate: Date?
    @ScaledMetric(relativeTo: .subheadline) private var chipWidth: CGFloat = 76

    private static let initialDayRadius = 30
    private static let extensionDayCount = 30
    private static let extensionTriggerDistance = 5

    init(
        selectedDate: Date,
        availableDateRange: ClosedRange<Date>,
        onSelect: @escaping (Date) -> Void,
        onOpenPicker: @escaping () -> Void
    ) {
        let day = Calendar.current.startOfDay(for: selectedDate)
        self.selectedDate = selectedDate
        self.availableDateRange = availableDateRange
        self.onSelect = onSelect
        self.onOpenPicker = onOpenPicker
        _selectorDays = State(
            initialValue: Self.initialDays(
                around: day,
                limitedTo: availableDateRange
            )
        )
        _visibleDate = State(initialValue: day)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(selectorDays, id: \.self) { date in
                        let isSelected = Calendar.current.isDate(
                            date,
                            inSameDayAs: selectedDate
                        )
                        dateChip(for: date, isSelected: isSelected) {
                            if isSelected {
                                onOpenPicker()
                            } else {
                                onSelect(date)
                            }
                        }
                        .frame(width: chipWidth)
                        .id(date)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $visibleDate, anchor: .center)
            .accessibilityIdentifier("log-date-selector")
            .task(id: [selectedDate, availableDateRange.lowerBound, availableDateRange.upperBound]) {
                let day = Calendar.current.startOfDay(for: selectedDate)
                if !selectorDays.contains(day) {
                    constrainSelectorToAvailableDates()
                }
                // visibleDate describes a visible target, not its exact alignment.
                // Always place the selection explicitly, even if that ID is already
                // visible. A new selection cancels any pending older request.
                await Task.yield()
                guard !Task.isCancelled else { return }
                let animation: Animation? = lastPlacedDate != nil && lastPlacedDate != day && !reduceMotion
                    ? .snappy(duration: 0.22) : nil
                withAnimation(animation) {
                    // Keep the restoration target in sync with the explicit
                    // placement, including jumps from a far-away history date.
                    // Otherwise an offscreen lazy stack can restore the old ID.
                    visibleDate = day
                    // ScrollView clamps to its real content edges when centering
                    // is impossible; don't add empty dates or synthetic padding.
                    proxy.scrollTo(day, anchor: .center)
                }
                lastPlacedDate = day
            }
            .onChange(of: availableDateRange) {
                constrainSelectorToAvailableDates()
            }
            .onChange(of: visibleDate) { _, newValue in
                guard let newValue else {
                    return
                }
                extendSelectorIfNeeded(around: newValue)
            }
            .frame(height: 44)
        }
    }

    private func dateChip(
        for date: Date,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(dateChipText(date))
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .padding(.horizontal, 5)
            .dateChipSurface(isSelected: isSelected, colorScheme: colorScheme)
            .contentShape(Capsule())
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityIdentifier(dateChipIdentifier(date))
        .accessibilityLabel(
            "\(dateChipText(date))\(isSelected ? AppLanguage.localized("、選択中") : "")"
        )
    }

    private func extendSelectorIfNeeded(around date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard let index = selectorDays.firstIndex(of: day),
              let firstDate = selectorDays.first,
              let lastDate = selectorDays.last else {
            return
        }

        var datesToPrepend: [Date] = []
        var datesToAppend: [Date] = []
        if index <= Self.extensionTriggerDistance {
            datesToPrepend = (-Self.extensionDayCount ... -1).compactMap { offset in
                Calendar.current.date(byAdding: .day, value: offset, to: firstDate)
            }.filter(availableDateRange.contains)
        }
        if index >= selectorDays.count - Self.extensionTriggerDistance - 1 {
            datesToAppend = (1 ... Self.extensionDayCount).compactMap { offset in
                Calendar.current.date(byAdding: .day, value: offset, to: lastDate)
            }.filter(availableDateRange.contains)
        }
        guard datesToPrepend.isEmpty == false || datesToAppend.isEmpty == false else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectorDays = datesToPrepend + selectorDays + datesToAppend
        }
    }

    private func constrainSelectorToAvailableDates() {
        let day = Calendar.current.startOfDay(for: selectedDate)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectorDays = Self.initialDays(
                around: day,
                limitedTo: availableDateRange
            )
        }
    }

    private static func initialDays(
        around center: Date,
        limitedTo availableDateRange: ClosedRange<Date>
    ) -> [Date] {
        let availableDayCount = (
            Calendar.current.dateComponents(
                [.day],
                from: availableDateRange.lowerBound,
                to: availableDateRange.upperBound
            ).day ?? 0
        ) + 1
        if availableDayCount <= initialDayRadius * 2 + 1 {
            return (0 ..< max(1, availableDayCount)).compactMap { offset in
                Calendar.current.date(
                    byAdding: .day,
                    value: offset,
                    to: availableDateRange.lowerBound
                )
            }
        }

        return (-initialDayRadius ... initialDayRadius).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: center)
        }.filter(availableDateRange.contains)
    }

    private func dateChipText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return AppLanguage.localized("今日")
        }
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    private func dateChipIdentifier(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "log-date-chip-%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private extension View {
    @ViewBuilder
    func dateChipSurface(isSelected: Bool, colorScheme: ColorScheme) -> some View {
        if colorScheme == .light {
            background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.white,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.75) : Color.black.opacity(0.12),
                        lineWidth: isSelected ? 1.1 : 0.8
                    )
            }
        } else if #available(iOS 26.0, *) {
            glassEffect(
                isSelected
                    ? .regular.tint(Color.accentColor.opacity(0.16)).interactive()
                    : .regular.interactive(),
                in: Capsule()
            )
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.16),
                            lineWidth: isSelected ? 1.1 : 0.8
                        )
                }
                .shadow(color: .black.opacity(isSelected ? 0.10 : 0.05), radius: 5, y: 2)
        }
    }
}

private struct CollapsingLogHeader: View {
    let selectedDate: Date
    let availableDateRange: ClosedRange<Date>?
    let verticalExtent: CGFloat
    let scrollState: LogDateHeaderScrollState
    let onSelect: (Date) -> Void
    let onOpenPicker: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Text(AppLanguage.localized("ログ"))
                .font(.headline)
                .accessibilityIdentifier("log-screen-title")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .frame(height: 44)

            Group {
                if let availableDateRange {
                    LogDateSelector(
                        selectedDate: selectedDate,
                        availableDateRange: availableDateRange,
                        onSelect: onSelect,
                        onOpenPicker: onOpenPicker
                    )
                } else {
                    // Reserve the header space until the actual history bounds
                    // are known, so the first scroll layout uses the final dates.
                    Color.clear.frame(height: 44)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
        .background(logCanvasBackground)
        .offset(y: -min(scrollState.offset(for: selectedDate), verticalExtent))
    }

    private var logCanvasBackground: Color {
        colorScheme == .light ? .white : Color(uiColor: .systemBackground)
    }
}

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \PlaceAliasEntity.priority, order: .reverse) private var aliases: [PlaceAliasEntity]
    @Binding var selectedDate: Date
    let canAccessDate: (Date) -> Bool
    let onShowStayOnMap: (StayEntity) -> Void
    let onShowCandidateOnMap: (StayCandidateEntity) -> Void
    @State private var activeSheet: ActiveSheet?
    @State private var pagerDates: [Date] = []
    @State private var pagerPosition: Date?
    @State private var earliestLogDate: Date?
    @State private var logDayDataStore = LogDayDataStore()
    @State private var datePickerDate = Calendar.current.startOfDay(for: Date())
    @State private var dateHeaderScrollState = LogDateHeaderScrollState()
    @State private var didRunDebugPageTransition = false
    @State private var pendingDateNavigationHaptic: DateNavigationHaptic?
    @State private var motionActivityStore = MotionActivityStore()

    private let logHeaderLayoutHeight: CGFloat = 128
    private let logHeaderCollapseDistance: CGFloat = 180

    private enum ActiveSheet: Identifiable {
        case datePicker

        var id: String {
            "datePicker"
        }
    }

    private enum DateNavigationHaptic: Equatable {
        case dateNavigation
        case today
    }

    init(
        selectedDate: Binding<Date>,
        canAccessDate: @escaping (Date) -> Bool,
        onShowStayOnMap: @escaping (StayEntity) -> Void,
        onShowCandidateOnMap: @escaping (StayCandidateEntity) -> Void
    ) {
        _selectedDate = selectedDate
        self.canAccessDate = canAccessDate
        self.onShowStayOnMap = onShowStayOnMap
        self.onShowCandidateOnMap = onShowCandidateOnMap
        _aliases = Query(sort: \PlaceAliasEntity.priority, order: .reverse)
    }

    private func isDateInFuture(_ date: Date) -> Bool {
        Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: Date())
    }

    private var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var availableLogDateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        let fallbackStart = date(offsetBy: -30, from: selectedDate) ?? today
        let earliestDate = earliestLogDate ?? min(fallbackStart, today)
        // Include today, tomorrow, and the day after tomorrow, but no further.
        let lastVisibleDate = date(offsetBy: 2, from: today) ?? today
        return min(earliestDate, today) ... lastVisibleDate
    }

    private var logCanvasBackground: Color {
        colorScheme == .light ? .white : Color(uiColor: .systemBackground)
    }

    var body: some View {
        ZStack(alignment: .top) {
            dayPager

            logHeader
                .zIndex(1)
        }
        .background(logCanvasBackground)
        .accessibilityAction(named: AppLanguage.localized("前の日")) {
            moveSelectedDate(by: -1)
        }
        .accessibilityAction(named: AppLanguage.localized("次の日")) {
            moveSelectedDate(by: 1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectedDateToday == false {
                todayButton
                    .accessibilityIdentifier("log-return-to-today")
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.24), value: isSelectedDateToday)
        .onReceive(NotificationCenter.default.publisher(for: .silicaLocationDataDidChange)) { _ in
            refreshLogDataAfterLocationChange()
        }
        .task {
            refreshAvailableLogDateRange()
            #if DEBUG
            guard DebugLaunchConfiguration.autoPagesLog,
                  didRunDebugPageTransition == false else {
                return
            }
            didRunDebugPageTransition = true
            try? await Task.sleep(for: .seconds(1))
            if let tomorrow = date(offsetBy: 1, from: selectedDate) {
                navigateToDate(tomorrow)
            }
            #endif
        }
        .task(id: selectedDate) {
            prefetchMotionActivity(around: selectedDate)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .datePicker:
                DatePickerSheet(title: "表示日", date: $datePickerDate) {
                    let requestedDate = datePickerDate
                    activeSheet = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(260))
                        navigateToDate(requestedDate)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var todayButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: selectToday) {
                todayButtonLabel
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityHint(AppLanguage.localized("今日の位置ログに戻る"))
        } else {
            Button(action: selectToday) {
                todayButtonLabel
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.32), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .accessibilityHint(AppLanguage.localized("今日の位置ログに戻る"))
        }
    }

    private var todayButtonLabel: some View {
        Label(AppLanguage.localized("今日"), systemImage: "calendar")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 17)
            .frame(height: 44)
            .contentShape(Capsule())
    }

    private func selectToday() {
        let today = Calendar.current.startOfDay(for: Date())
        navigateToDate(today, haptic: .today)
    }

    private var logHeader: some View {
        CollapsingLogHeader(
            selectedDate: selectedDate,
            availableDateRange: earliestLogDate == nil ? nil : availableLogDateRange,
            verticalExtent: logHeaderCollapseDistance,
            scrollState: dateHeaderScrollState,
            onSelect: { date in
                navigateToDate(date)
            },
            onOpenPicker: {
                datePickerDate = Calendar.current.startOfDay(for: selectedDate)
                activeSheet = .datePicker
            }
        )
    }

    @ViewBuilder
    private var dayPager: some View {
        if #available(iOS 18.0, *) {
            dayPagerContent
                .onScrollPhaseChange { _, newPhase in
                    guard newPhase == .idle else {
                        return
                    }
                    commitPagerPosition()
                }
        } else {
            dayPagerContent
                .onChange(of: pagerPosition) { _, newValue in
                    schedulePagerCommit(for: newValue)
                }
        }
    }

    private var dayPagerContent: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pagerDates, id: \.self) { date in
                    dayScrollView(for: date)
                        .containerRelativeFrame(.horizontal)
                        .id(date)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagerPosition, anchor: .center)
        .onAppear {
            configurePager(around: selectedDate)
        }
        .onChange(of: selectedDate) { _, newValue in
            let day = Calendar.current.startOfDay(for: newValue)
            guard pagerPosition.map({ Calendar.current.isDate($0, inSameDayAs: day) }) != true else {
                return
            }
            guard prepareLogData(for: day) else {
                return
            }
            if pagerDates.contains(day) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pagerPosition = day
                }
                prefetchAdjacentDays(around: day)
            } else {
                configurePager(around: day)
            }
        }
    }

    @ViewBuilder
    private func dayScrollView(for date: Date) -> some View {
        let day = Calendar.current.startOfDay(for: date)
        let scrollView = ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                Color.clear
                    .frame(height: logHeaderLayoutHeight)
                    .accessibilityHidden(true)

                LogDayPage(
                    motionActivityStore: motionActivityStore,
                    date: date,
                    dataStore: logDayDataStore,
                    aliases: aliases,
                    onSelectStay: { stay in
                        onShowStayOnMap(stay)
                    },
                    onSelectCandidate: { candidate in
                        onShowCandidateOnMap(candidate)
                    }
                )
                .id(day)
            }
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(debugInitialScrollAnchor)

        if #available(iOS 18.0, *) {
            scrollView
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    min(
                        logHeaderCollapseDistance,
                        max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                    )
                } action: { _, newOffset in
                    guard Calendar.current.isDate(day, inSameDayAs: selectedDate) else {
                        return
                    }
                    dateHeaderScrollState.update(newOffset, for: day)
                }
        } else {
            scrollView
        }
    }

    private func moveSelectedDate(by dayOffset: Int) {
        guard let date = Calendar.current.date(
            byAdding: .day,
            value: dayOffset,
            to: Calendar.current.startOfDay(for: selectedDate)
        ) else {
            return
        }
        navigateToDate(date)
    }

    private func navigateToDate(
        _ date: Date,
        haptic: DateNavigationHaptic = .dateNavigation
    ) {
        let day = Calendar.current.startOfDay(for: date)
        let difference = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: selectedDate),
            to: day
        ).day ?? 0

        guard difference != 0 else {
            if haptic == .today {
                triggerTodayHaptic()
            }
            return
        }


        guard availableLogDateRange.contains(day) else {
            return
        }

        guard canAccessDate(day) else {
            return
        }

        guard prepareLogData(for: day) else {
            return
        }

        if abs(difference) == 1 {
            pendingDateNavigationHaptic = haptic
            if haptic == .today {
                triggerTodayHaptic()
            }
            withAnimation(.snappy(duration: 0.25)) {
                pagerPosition = day
            }
        } else if pagerDates.contains(day) {
            triggerNavigationHaptic(haptic)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pagerPosition = day
                selectedDate = day
            }
            prefetchAdjacentDays(around: day)
        } else {
            triggerNavigationHaptic(haptic)
            configurePager(around: day)
        }
    }

    private func schedulePagerCommit(for position: Date?) {
        guard position != nil else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard pagerPosition == position else {
                return
            }
            commitPagerPosition()
        }
    }

    private func commitPagerPosition() {
        guard let targetDate = pagerPosition else {
            return
        }
        let day = Calendar.current.startOfDay(for: targetDate)
        let haptic = pendingDateNavigationHaptic
        pendingDateNavigationHaptic = nil
        guard canAccessDate(day) else {
            let currentDay = Calendar.current.startOfDay(for: selectedDate)
            withAnimation(.snappy(duration: 0.25)) {
                pagerPosition = currentDay
            }
            return
        }
        extendPagerIfNeeded(around: day)
        // Adjacent pages are prefetched during normal paging, but a fast swipe can
        // skip beyond them. Load the page that paging actually settled on.
        prepareLogData(for: day)
        guard Calendar.current.isDate(day, inSameDayAs: selectedDate) == false else {
            return
        }
        if haptic != .today {
            triggerDateNavigationHaptic()
        }
        selectedDate = day
        prefetchAdjacentDays(around: day)
    }

    private func configurePager(around date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard prepareLogData(for: day) else {
            return
        }
        let dates = (-31...31).compactMap { offset in
            self.date(offsetBy: offset, from: day)
        }.filter(availableLogDateRange.contains)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pagerDates = dates
            selectedDate = day
            pagerPosition = day
        }
        prefetchAdjacentDays(around: day)
    }

    private func extendPagerIfNeeded(around date: Date) {
        guard
            let index = pagerDates.firstIndex(of: date),
            let firstDate = pagerDates.first,
            let lastDate = pagerDates.last
        else {
            return
        }

        var datesToPrepend: [Date] = []
        var datesToAppend: [Date] = []

        if index <= 5 {
            datesToPrepend = (-31 ... -1).compactMap { offset in
                self.date(offsetBy: offset, from: firstDate)
            }.filter(availableLogDateRange.contains)
        }
        if index >= pagerDates.count - 6 {
            datesToAppend = (1 ... 31).compactMap { offset in
                self.date(offsetBy: offset, from: lastDate)
            }.filter(availableLogDateRange.contains)
        }

        guard datesToPrepend.isEmpty == false || datesToAppend.isEmpty == false else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pagerDates = datesToPrepend + pagerDates + datesToAppend
        }
    }

    @discardableResult
    private func prepareLogData(for date: Date) -> Bool {
        logDayDataStore.load(date, in: modelContext)
    }

    private func refreshLogDataAfterLocationChange() {
        logDayDataStore.invalidate()
        refreshAvailableLogDateRange()
        guard prepareLogData(for: selectedDate) else {
            return
        }
        prefetchAdjacentDays(around: selectedDate)
    }

    private func refreshAvailableLogDateRange() {
        var descriptor = FetchDescriptor<StayEntity>(
            sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstUsedAt = UserDefaults.standard.object(
            forKey: SilicaOnboardingStorage.firstUsedAtKey
        ) as? Date ?? today
        let initialRangeStart = calendar.date(
            byAdding: .day, value: -2, to: calendar.startOfDay(for: firstUsedAt)
        ) ?? today
        let earliestSavedDate = (try? modelContext.fetch(descriptor).first)
            .map { calendar.startOfDay(for: $0.arrivalAt) }
            ?? today
        // Keep the initial five-day strip even before any stays are recorded.
        // Existing users retain access to all of their older history.
        let refreshedEarliestDate = min(earliestSavedDate, initialRangeStart)
        let boundsChanged = earliestLogDate != refreshedEarliestDate
        earliestLogDate = refreshedEarliestDate
        guard pagerDates.isEmpty || boundsChanged else {
            return
        }
        let selectedDay = Calendar.current.startOfDay(for: selectedDate)
        let boundedDay = min(
            max(selectedDay, availableLogDateRange.lowerBound),
            availableLogDateRange.upperBound
        )
        configurePager(around: boundedDay)
    }

    private func prefetchAdjacentDays(around centerDate: Date) {
        logDayDataStore.retainDays(around: centerDate)
        for offset in [-1, 1] {
            guard let adjacentDate = date(offsetBy: offset, from: centerDate),
                  availableLogDateRange.contains(adjacentDate) else {
                continue
            }
            prepareLogData(for: adjacentDate)
        }
    }

    private func prefetchMotionActivity(around centerDate: Date) {
        for offset in -1...1 {
            guard let date = date(offsetBy: offset, from: centerDate),
                  isDateInFuture(date) == false else {
                continue
            }
            motionActivityStore.load(around: date)
        }
    }

    private func date(offsetBy offset: Int, from date: Date) -> Date? {
        Calendar.current.date(byAdding: .day, value: offset, to: date)
    }

    private var debugInitialScrollAnchor: UnitPoint {
        #if DEBUG
        DebugLaunchConfiguration.startsLogAtBottom ? .bottom : .top
        #else
        .top
        #endif
    }

    private func triggerTodayHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
    }

    private func triggerDateNavigationHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    private func triggerNavigationHaptic(_ haptic: DateNavigationHaptic) {
        switch haptic {
        case .dateNavigation:
            triggerDateNavigationHaptic()
        case .today:
            triggerTodayHaptic()
        }
    }

}

private struct LogDayPage: View {
    @EnvironmentObject private var locationRecorder: LocationRecorder
    let motionActivityStore: MotionActivityStore

    let date: Date
    let dataStore: LogDayDataStore
    let aliases: [PlaceAliasEntity]
    let onSelectStay: (StayEntity) -> Void
    let onSelectCandidate: (StayCandidateEntity) -> Void

    @ViewBuilder
    var body: some View {
        if Calendar.current.isDateInToday(date) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                pageContent(at: context.date)
            }
        } else {
            pageContent(at: Date())
        }
    }

    @ViewBuilder
    private func pageContent(at now: Date) -> some View {
        if isFuture {
            emptyState
        } else if let snapshot = dataStore.snapshot(for: date) {
            let stays = visibleStays(in: snapshot)
            let previousStay = contextualPreviousStay(
                before: stays.first,
                in: snapshot
            )
            let provisionalCandidates = visibleProvisionalCandidates(
                in: snapshot,
                at: now
            )

            if stays.isEmpty && provisionalCandidates.isEmpty {
                emptyState
            } else {
                timeline(
                    stays: stays,
                    provisionalCandidates: provisionalCandidates,
                    previousStay: previousStay,
                    movementPoints: snapshot.movementPoints,
                    now: now
                )
                    .padding(.horizontal, 14)
            }
        } else {
            loadingState
        }
    }

    private func visibleStays(in snapshot: LogDaySnapshot) -> [StayEntity] {
        guard isFuture == false else {
            return []
        }
        let dayInterval = DateSupport.dayInterval(containing: date)
        let now = Date()
        return snapshot.stays.indices.compactMap { index in
            let stay = snapshot.stays[index]
            return DateSupport.overlaps(
                arrivalAt: stay.arrivalAt,
                departureAt: stay.departureAt,
                dayInterval: dayInterval,
                now: now
            ) ? stay : nil
        }
    }

    private func contextualPreviousStay(
        before firstVisibleStay: StayEntity?,
        in snapshot: LogDaySnapshot
    ) -> StayEntity? {
        guard let firstVisibleStay,
              let index = snapshot.stays.firstIndex(where: { $0.id == firstVisibleStay.id }) else {
            return snapshot.previousStay
        }
        return index > snapshot.stays.startIndex
            ? snapshot.stays[snapshot.stays.index(before: index)]
            : snapshot.previousStay
    }

    private func visibleProvisionalCandidates(
        in snapshot: LogDaySnapshot,
        at now: Date
    ) -> [StayCandidateEntity] {
        guard isFuture == false else {
            return []
        }
        return snapshot.pendingCandidates.filter { candidate in
            guard DateSupport.overlaps(
                arrivalAt: candidate.arrivalAt,
                departureAt: candidate.temporalBoundaryAt,
                dayInterval: DateSupport.dayInterval(containing: date),
                now: now
            ) else {
                return false
            }
            let alreadyRepresented = snapshot.stays.contains { stay in
                abs(stay.arrivalAt.timeIntervalSince(candidate.arrivalAt)) <= 2 * 60 &&
                    GeoDistance.meters(from: stay.coordinate, to: candidate.presentationCoordinate) <= 500
            }
            guard alreadyRepresented == false else {
                return false
            }
            return true
        }
    }

    private var isFuture: Bool {
        date > Calendar.current.startOfDay(for: Date())
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isFuture {
            ContentUnavailableView(
                AppLanguage.localized("記録はありません"),
                systemImage: "calendar",
                description: Text(AppLanguage.localized("未来の日付には位置ログはありません。"))
            )
            .padding(.horizontal, 14)
            .padding(.top, 54)
        } else if isToday && locationRecorder.isInitialLocationRequestInFlight {
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel(AppLanguage.localized("今いる場所を確認中"))
                ContentUnavailableView(
                    AppLanguage.localized("今いる場所を確認中"),
                    systemImage: "location.circle"
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 42)
        } else if isToday &&
                    (locationRecorder.isMonitoring == false ||
                     locationRecorder.hasAutomaticRecordingPermission == false) {
            ContentUnavailableView(
                AppLanguage.localized("自動記録が停止しています"),
                systemImage: "location.slash",
                description: Text(AppLanguage.localized(
                    "設定タブで位置情報の「常に許可」と「正確な位置情報」を確認してください。"
                ))
            )
            .padding(.horizontal, 14)
            .padding(.top, 54)
        } else {
            ContentUnavailableView(
                AppLanguage.localized("位置ログはまだありません"),
                systemImage: "calendar",
                description: Text(AppLanguage.localized(
                    "滞在が記録されると、移動を含む一日の流れがここに現れます。"
                ))
            )
            .padding(.horizontal, 14)
            .padding(.top, 54)
        }
    }

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, 82)
            .accessibilityLabel(AppLanguage.localized("位置ログを読み込み中"))
    }

    private func timeline(
        stays: [StayEntity],
        provisionalCandidates: [StayCandidateEntity],
        previousStay: StayEntity?,
        movementPoints: [MovementPointEntity],
        now: Date
    ) -> some View {
        let anchorCutoff = Calendar.current.date(byAdding: .hour, value: -6, to: date) ?? date
        let leadingAnchor = previousStay.flatMap { stay -> StayEntity? in
            let endAt = stay.departureAt ?? stay.arrivalAt
            return endAt >= anchorCutoff ? stay : nil
        }
        let items = (
            stays.map { TimelineItem.confirmed($0) } +
                provisionalCandidates.map { TimelineItem.provisional($0) }
        ).sorted { $0.arrivalAt < $1.arrivalAt }
        let firstVisibleTimestamp = items.first?.arrivalAt ?? date
        let firstTimestamp = min(
            firstVisibleTimestamp,
            leadingAnchor?.departureAt ?? firstVisibleTimestamp
        )
        let confirmedLastTimestamp = stays.last.flatMap(\.departureAt)
            ?? Calendar.current.date(byAdding: .day, value: 1, to: date)
            ?? date
        let candidateLastTimestamp = provisionalCandidates
            .map { $0.temporalBoundaryAt ?? now }
            .max()
        let lastTimestamp = candidateLastTimestamp.map {
            max(confirmedLastTimestamp, $0)
        } ?? confirmedLastTimestamp
        let trackedPoints: [MovementPoint] = movementPoints.compactMap { point in
            guard point.timestamp >= firstTimestamp,
                  point.timestamp <= lastTimestamp else {
                return nil
            }
            return point.corePoint
        }

        return VStack(spacing: 0) {
            mergedTimelineRows(
                items: items,
                leadingAnchor: leadingAnchor,
                trackedPoints: trackedPoints
            )
        }
    }

    @ViewBuilder
    private func mergedTimelineRows(
        items: [TimelineItem],
        leadingAnchor: StayEntity?,
        trackedPoints: [MovementPoint]
    ) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let previousItem: TimelineItem? = index > 0
                ? items[index - 1]
                : leadingAnchor.map(TimelineItem.confirmed)
            let movement: TimelineMovementPresentation? = if let previousItem,
                                                              previousItem.id != item.id {
                movementPresentation(
                    from: previousItem,
                    to: item,
                    trackedPoints: trackedPoints
                )
            } else {
                nil
            }

            switch item {
            case .confirmed(let stay):
                ConfirmedTimelineSegment(
                    stay: stay,
                    aliases: aliases,
                    displayDate: date,
                    arrivalAt: stay.arrivalAt,
                    departureAt: stay.departureAt,
                    isFirst: index == 0,
                    isLast: index == items.count - 1,
                    leadingMovement: movement,
                    leadingModes: movement.map(movementModes) ?? [],
                    movement: nil,
                    movementModes: [],
                    action: { onSelectStay(stay) }
                )
            case .provisional(let candidate):
                ProvisionalTimelineSegment(
                    candidate: candidate,
                    aliases: aliases,
                    displayDate: date,
                    isFirst: index == 0,
                    isLast: index == items.count - 1,
                    movement: movement,
                    movementModes: movement.map(movementModes) ?? [],
                    action: { onSelectCandidate(candidate) }
                )
            }
        }

    }

    private func movementPresentation(
        from origin: TimelineItem,
        to destination: TimelineItem,
        trackedPoints: [MovementPoint]
    ) -> TimelineMovementPresentation? {
        switch (origin, destination) {
        case let (.confirmed(origin), .confirmed(destination)):
            movementPresentation(
                from: origin,
                to: destination,
                trackedPoints: trackedPoints
            )
        case let (.confirmed(origin), .provisional(destination)):
            movementPresentation(
                from: origin,
                to: destination,
                trackedPoints: trackedPoints
            )
        case let (.provisional(origin), .confirmed(destination)):
            movementPresentation(
                from: origin,
                to: destination,
                trackedPoints: trackedPoints
            )
        case let (.provisional(origin), .provisional(destination)):
            movementPresentation(
                from: origin,
                to: destination,
                trackedPoints: trackedPoints
            )
        }
    }

    private func movementModes(
        for movement: TimelineMovementPresentation
    ) -> [MovementMode] {
        guard movement.persistedModes.isEmpty else {
            return movement.persistedModes
        }
        return movement.interval.map {
            motionActivityStore.modes(from: $0.start, to: $0.end)
        } ?? []
    }

    private func movementPresentation(
        from origin: StayEntity,
        to destination: StayEntity,
        trackedPoints: [MovementPoint]
    ) -> TimelineMovementPresentation? {
        movementPresentation(
            originCoordinate: origin.coordinate,
            originDepartureAt: origin.departureAt,
            originDepartureIsObserved:
                origin.departureSourceRawValue != StayDepartureSource.inferredCandidate.rawValue,
            persistedInterval: origin.storedMovementInterval,
            persistedTimingIsSensorDerived: origin.movementTimingSource.isSensorDerived,
            persistedModes: origin.movementModes,
            persistedActiveDuration: origin.movementActiveDuration,
            persistedDistanceMeters: origin.movementDistanceMeters,
            persistedStepCount: origin.movementStepCount,
            persistedDistanceSource: origin.movementDistanceSource,
            persistedEvidenceMatchesDestination:
                origin.movementEvidenceMatches(destinationID: destination.id),
            originAccuracy: origin.horizontalAccuracy,
            destinationCoordinate: destination.coordinate,
            destinationArrivalAt: destination.arrivalAt,
            destinationAccuracy: destination.horizontalAccuracy,
            trackedPoints: trackedPoints
        )
    }

    private func movementPresentation(
        from origin: StayEntity,
        to destination: StayCandidateEntity,
        trackedPoints: [MovementPoint]
    ) -> TimelineMovementPresentation? {
        movementPresentation(
            originCoordinate: origin.coordinate,
            originDepartureAt: origin.departureAt,
            originDepartureIsObserved:
                origin.departureSourceRawValue != StayDepartureSource.inferredCandidate.rawValue,
            persistedInterval: origin.storedMovementInterval,
            persistedModes: origin.movementModes,
            persistedEvidenceMatchesDestination: false,
            originAccuracy: origin.horizontalAccuracy,
            destinationCoordinate: destination.presentationCoordinate,
            destinationArrivalAt: destination.arrivalAt,
            destinationAccuracy: destination.presentationHorizontalAccuracy,
            trackedPoints: trackedPoints
        )
    }

    private func movementPresentation(
        from origin: StayCandidateEntity,
        to destination: StayEntity,
        trackedPoints: [MovementPoint]
    ) -> TimelineMovementPresentation? {
        movementPresentation(
            originCoordinate: origin.presentationCoordinate,
            originDepartureAt: origin.effectiveDepartureAt,
            originDepartureIsObserved: origin.departureAt != nil,
            persistedInterval: nil,
            persistedModes: [],
            persistedEvidenceMatchesDestination: false,
            originAccuracy: origin.presentationHorizontalAccuracy,
            destinationCoordinate: destination.coordinate,
            destinationArrivalAt: destination.arrivalAt,
            destinationAccuracy: destination.horizontalAccuracy,
            trackedPoints: trackedPoints
        )
    }

    private func movementPresentation(
        from origin: StayCandidateEntity,
        to destination: StayCandidateEntity,
        trackedPoints: [MovementPoint]
    ) -> TimelineMovementPresentation? {
        movementPresentation(
            originCoordinate: origin.presentationCoordinate,
            originDepartureAt: origin.effectiveDepartureAt,
            originDepartureIsObserved: origin.departureAt != nil,
            persistedInterval: nil,
            persistedModes: [],
            persistedEvidenceMatchesDestination: false,
            originAccuracy: origin.presentationHorizontalAccuracy,
            destinationCoordinate: destination.presentationCoordinate,
            destinationArrivalAt: destination.arrivalAt,
            destinationAccuracy: destination.presentationHorizontalAccuracy,
            trackedPoints: trackedPoints
        )
    }

    private func movementPresentation(
        originCoordinate: GeoCoordinate,
        originDepartureAt: Date?,
        originDepartureIsObserved: Bool,
        persistedInterval: DateInterval?,
        persistedTimingIsSensorDerived: Bool = false,
        persistedModes: [MovementMode],
        persistedActiveDuration: TimeInterval? = nil,
        persistedDistanceMeters: Double? = nil,
        persistedStepCount: Int? = nil,
        persistedDistanceSource: MovementDistanceSource = .unavailable,
        persistedEvidenceMatchesDestination: Bool,
        originAccuracy: Double,
        destinationCoordinate: GeoCoordinate,
        destinationArrivalAt: Date,
        destinationAccuracy: Double,
        trackedPoints: [MovementPoint]
    ) -> TimelineMovementPresentation? {
        let linkedSensorInterval = persistedInterval.flatMap { interval in
            persistedEvidenceMatchesDestination && persistedTimingIsSensorDerived
                ? interval
                : nil
        }
        let timing = MovementTimingPresentationPolicy.resolve(
            destinationLinkedSensorInterval: linkedSensorInterval,
            originDepartureAt: originDepartureAt,
            originDepartureIsObserved: originDepartureIsObserved,
            destinationArrivalAt: destinationArrivalAt
        )
        let excursionInterval: DateInterval? = switch timing.kind {
        case .measured, .observedVisitGap:
            timing.interval
        case .inferredVisitGap, .unavailable:
            nil
        }
        let sharedContainmentRadius = StayResolution.sharedRegisteredPlaceRadius(
            from: originCoordinate,
            to: destinationCoordinate,
            aliases: aliases
        )
        guard let pathEvidence = MovementPresentationPolicy.evidence(
            origin: originCoordinate,
            destination: destinationCoordinate,
            originAccuracy: originAccuracy,
            destinationAccuracy: destinationAccuracy,
            excursionInterval: excursionInterval,
            points: trackedPoints,
            containmentRadiusMeters: sharedContainmentRadius
        ) else {
            return nil
        }
        // A destination-linked classification remains useful even when its
        // timing window is too broad. The row labels it as estimated instead
        // of mixing that window with a precise travel-time claim.
        let validPersistedModes = persistedEvidenceMatchesDestination
            ? persistedModes
            : []

        if pathEvidence.kind == .excursion {
            let hasMeasuredDistance = timing.kind == .measured &&
                persistedDistanceSource != .straightLineReference &&
                persistedDistanceSource != .unavailable
            return TimelineMovementPresentation(
                distanceMeters: hasMeasuredDistance ? persistedDistanceMeters : nil,
                distanceSource: hasMeasuredDistance
                    ? persistedDistanceSource
                    : .unavailable,
                timingKind: timing.kind,
                interval: timing.interval,
                duration: timing.kind == .measured
                    ? persistedActiveDuration ?? timing.duration
                    : timing.duration,
                stepCount: timing.kind == .measured ? persistedStepCount : nil,
                persistedModes: validPersistedModes
            )
        }

        if timing.kind == .measured,
           let persistedInterval = timing.interval,
           let summary = MovementSummaryBuilder.build(
               departureAt: persistedInterval.start,
               arrivalAt: persistedInterval.end,
               origin: originCoordinate,
               destination: destinationCoordinate,
               points: trackedPoints
           ) {
            return TimelineMovementPresentation(
                distanceMeters: persistedDistanceMeters ?? summary.distanceMeters,
                distanceSource: persistedDistanceMeters.map { _ in
                    persistedDistanceSource == .unavailable
                        ? .straightLineReference
                        : persistedDistanceSource
                } ?? inferredDistanceSource(
                    for: persistedInterval,
                    trackedPoints: trackedPoints
                ),
                timingKind: .measured,
                interval: persistedInterval,
                duration: persistedActiveDuration ?? summary.duration,
                stepCount: persistedStepCount,
                persistedModes: validPersistedModes
            )
        }

        return TimelineMovementPresentation(
            distanceMeters: pathEvidence.directDistanceMeters,
            distanceSource: .straightLineReference,
            timingKind: timing.kind,
            interval: timing.interval,
            duration: timing.duration,
            stepCount: nil,
            persistedModes: validPersistedModes
        )
    }

    private func inferredDistanceSource(
        for interval: DateInterval,
        trackedPoints: [MovementPoint]
    ) -> MovementDistanceSource {
        trackedPoints.contains { point in
            interval.contains(point.timestamp) &&
                point.horizontalAccuracy >= 0 &&
                point.horizontalAccuracy <= 1_000
        } ? .locationRoute : .straightLineReference
    }

}

private struct ConfirmedTimelineSegment: View {
    let stay: StayEntity
    let aliases: [PlaceAliasEntity]
    let displayDate: Date
    let arrivalAt: Date
    let departureAt: Date?
    let isFirst: Bool
    let isLast: Bool
    let leadingMovement: TimelineMovementPresentation?
    let leadingModes: [MovementMode]
    let movement: TimelineMovementPresentation?
    let movementModes: [MovementMode]
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if let leadingMovement {
            TimelineMovementRow(
                movement: leadingMovement,
                modes: leadingModes
            )
        }
        TimelineStayRow(
            stay: stay,
            aliases: aliases,
            displayDate: displayDate,
            arrivalAt: arrivalAt,
            departureAt: departureAt,
            isFirst: isFirst && leadingMovement == nil,
            isLast: isLast,
            action: action
        )
        if let movement {
            TimelineMovementRow(
                movement: movement,
                modes: movementModes
            )
        }
    }
}

private struct ProvisionalTimelineSegment: View {
    let candidate: StayCandidateEntity
    let aliases: [PlaceAliasEntity]
    let displayDate: Date
    let isFirst: Bool
    let isLast: Bool
    let movement: TimelineMovementPresentation?
    let movementModes: [MovementMode]
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if let movement {
            TimelineMovementRow(
                movement: movement,
                modes: movementModes,
                isProvisional: true
            )
        }
        TimelineProvisionalStayRow(
            candidate: candidate,
            aliases: aliases,
            displayDate: displayDate,
            isFirst: isFirst && movement == nil,
            isLast: isLast,
            action: action
        )
    }
}

private struct TimelineProvisionalStayRow: View {
    let candidate: StayCandidateEntity
    let aliases: [PlaceAliasEntity]
    let displayDate: Date
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        let details = StayResolution.details(for: candidate, aliases: aliases)

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                TimelineRail(
                    nodeKind: .stay,
                    startsTimeline: isFirst,
                    endsTimeline: isLast,
                    tint: .orange,
                    symbolName: details.matchingAlias?.symbolName ?? "location.fill"
                )
                .frame(maxHeight: .infinity)

                Button(action: action) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(details.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        ViewThatFits(in: .horizontal) {
                            metadata
                            VStack(alignment: .leading, spacing: 7) {
                                timeRange
                                duration
                            }
                        }

                        if let address = details.address?.trimmedNonEmpty,
                           address != details.title {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .background {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(.orange.opacity(0.7), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(details: details))
                .accessibilityHint(AppLanguage.localized("タップしてマップで滞在を表示"))
                .accessibilityIdentifier(
                    candidate.isTemporallyOpen ? "ongoing-stay-row" : "provisional-stay-row"
                )
            }
            .frame(maxWidth: .infinity)

            if isLast == false {
                TimelineRowSpacer()
            }
        }
    }

    private var metadata: some View {
        HStack(alignment: .center, spacing: 10) {
            timeRange

            Divider()
                .frame(height: 14)

            duration

            Spacer(minLength: 0)
        }
    }

    private var timeRange: some View {
        let text: String
        if candidate.isTemporallyOpen || candidate.effectiveDepartureAt != nil {
            text = DateSupport.formatTimeRange(
                start: candidate.arrivalAt,
                end: candidate.effectiveDepartureAt,
                displayDate: displayDate
            )
        } else {
            text = "\(DateSupport.formatTime(candidate.arrivalAt, displayDate: displayDate))-\(AppLanguage.localized("終了時刻不明"))"
        }
        return Text(text)
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.orange)
    }

    private var duration: some View {
        let text: String
        if let endAt = candidate.effectiveDepartureAt {
            text = DateSupport.formatDuration(max(0, endAt.timeIntervalSince(candidate.arrivalAt)))
        } else if candidate.isTemporallyOpen {
            text = AppLanguage.localized(openCandidateStatusKey)
        } else {
            text = AppLanguage.localized("時間未確定")
        }
        return Text(text)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.orange)
    }

    private func accessibilityLabel(details: StayResolution.Details) -> String {
        [
            candidate.isTemporallyOpen || candidate.effectiveDepartureAt != nil
                ? DateSupport.formatTimeRange(
                    start: candidate.arrivalAt,
                    end: candidate.effectiveDepartureAt,
                    displayDate: displayDate
                )
                : "\(DateSupport.formatTime(candidate.arrivalAt, displayDate: displayDate))-\(AppLanguage.localized("終了時刻不明"))",
            details.title,
            AppLanguage.localized(
                candidate.isTemporallyOpen ? openCandidateStatusKey : "終了時刻を確認中"
            ),
            candidate.isTemporallyOpen
                ? AppLanguage.localized("未確定")
                : AppLanguage.localized("時間未確定"),
        ]
        .joined(separator: AppLanguage.current == .english ? ", " : "、")
    }

    private var openCandidateStatusKey: String {
        guard candidate.isLocationBootstrap else {
            return "滞在中"
        }
        return Date().timeIntervalSince(candidate.arrivalAt) >= StayValidationPolicy.minimumDuration
            ? "滞在中、移動後に確定"
            : "現在地を確認中"
    }
}

private struct TimelineStayRow: View {
    let stay: StayEntity
    let aliases: [PlaceAliasEntity]
    let displayDate: Date
    let arrivalAt: Date
    let departureAt: Date?
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        let details = StayResolution.details(for: stay, aliases: aliases)

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                TimelineRail(
                    nodeKind: .stay,
                    startsTimeline: isFirst,
                    endsTimeline: isLast,
                    symbolName: details.matchingAlias?.symbolName
                )
                .frame(maxHeight: .infinity)

                Button(action: action) {
                    VStack(alignment: .leading, spacing: 10) {
                        if details.placeName != nil {
                            Text(details.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        ViewThatFits(in: .horizontal) {
                            stayMetadata
                            VStack(alignment: .leading, spacing: 7) {
                                stayTimeRange
                                stayDuration
                            }
                        }

                        if let addressText = addressText(for: details) {
                            Text(addressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .background {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(details: details))
                .accessibilityHint(AppLanguage.localized("タップしてマップで滞在を表示"))
            }
            .frame(maxWidth: .infinity)

            if isLast == false {
                TimelineRowSpacer()
            }
        }
    }

    private var stayMetadata: some View {
        HStack(alignment: .center, spacing: 10) {
            stayTimeRange

            Divider()
                .frame(height: 14)

            stayDuration

            Spacer(minLength: 0)
        }
    }

    private func addressText(for details: StayResolution.Details) -> String? {
        if details.placeName != nil {
            return details.address
        }
        return details.title
    }

    private var stayTimeRange: some View {
        Text(
            DateSupport.formatTimeRange(
                start: arrivalAt,
                end: departureAt,
                displayDate: displayDate
            )
        )
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var stayDuration: some View {
        if let departureAt {
            Text(DateSupport.formatDuration(max(0, departureAt.timeIntervalSince(arrivalAt))))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        } else {
            Text(AppLanguage.localized("滞在中"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private func accessibilityLabel(details: StayResolution.Details) -> String {
        let range = DateSupport.formatTimeRange(
            start: arrivalAt,
            end: departureAt,
            displayDate: displayDate
        )
        let duration = departureAt.map {
            DateSupport.formatDuration(max(0, $0.timeIntervalSince(arrivalAt)))
        } ?? AppLanguage.localized("滞在中")
        return [range, details.title, details.address, duration]
            .compactMap { $0 }
            .joined(separator: AppLanguage.current == .english ? ", " : "、")
    }
}

private struct TimelineMovementRow: View {
    let movement: TimelineMovementPresentation
    let modes: [MovementMode]
    var isProvisional = false
    var isTerminal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TimelineRail(
                    nodeKind: .movement,
                    startsTimeline: false,
                    endsTimeline: isTerminal
                )
                .frame(maxHeight: .infinity)

                HStack(spacing: 12) {
                    Image(systemName: modeSymbolName)
                        .font(.system(.title2, design: .default).weight(.semibold))
                        .foregroundStyle(isProvisional ? Color.orange : Color.accentColor)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(modeText)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)

                        HStack(spacing: 12) {
                            if let distanceText {
                                Text(distanceText)
                                    .font(.caption.monospacedDigit())
                            }

                            if let stepCountText {
                                if distanceText != nil {
                                    Divider()
                                        .frame(height: 12)
                                }

                                Text(stepCountText)
                                    .font(.caption.monospacedDigit())
                            }

                            if let durationText {
                                if distanceText != nil || stepCountText != nil {
                                    Divider()
                                        .frame(height: 12)
                                }

                                Text(durationText)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isTerminal == false {
                TimelineRowSpacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [modeText, distanceText, stepCountText, durationText]
                .compactMap { $0 }
                .joined(separator: AppLanguage.current == .english ? ", " : "、")
        )
    }

    private var distanceText: String? {
        guard let distanceMeters = movement.distanceMeters else {
            return nil
        }
        let distance = max(0, distanceMeters)
        if distance < 100 {
            return movement.distanceSource == .straightLineReference
                ? (AppLanguage.current == .english
                    ? "Under 100 m straight-line"
                    : "直線100 m未満")
                : AppLanguage.localized("100 m未満")
        }
        let formatted: String
        if distance < 1_000 {
            let rounded = Int((distance / 50).rounded()) * 50
            formatted = "\(rounded) m"
        } else {
            formatted = String(format: "%.1f km", distance / 1_000)
        }
        guard movement.distanceSource == .straightLineReference else {
            return formatted
        }
        return AppLanguage.current == .english
            ? "\(formatted) straight-line"
            : "直線\(formatted)"
    }

    private var stepCountText: String? {
        guard let stepCount = movement.stepCount, stepCount > 0 else {
            return nil
        }
        return AppLanguage.current == .english
            ? "\(stepCount) steps"
            : "\(stepCount)歩"
    }

    private var modeText: String {
        let displayModes = effectiveModes
        guard displayModes.isEmpty == false else {
            return AppLanguage.localized("移動")
        }
        return displayModes.map(\.label).joined(separator: " → ")
    }

    private var modeSymbolName: String {
        let displayModes = effectiveModes
        guard displayModes.count == 1, let mode = displayModes.first else {
            return displayModes.isEmpty ? "arrow.down" : "arrow.triangle.swap"
        }
        switch mode {
        case .walking:
            return "figure.walk"
        case .running:
            return "figure.run"
        case .cycling:
            return "bicycle"
        case .vehicle:
            return "car.fill"
        }
    }

    private var durationText: String? {
        movement.duration.map(DateSupport.formatDuration)
    }

    private var effectiveModes: [MovementMode] {
        guard modes.isEmpty else {
            return modes
        }

        #if DEBUG
        if DebugLaunchConfiguration.seedsLongTimeline || DebugLaunchConfiguration.startsLogHistory {
            return [estimatedMode]
        }
        #endif

        return []
    }

    private var estimatedMode: MovementMode {
        guard let duration = movement.duration, duration > 0 else {
            return .walking
        }

        let metersPerSecond = max(0, movement.distanceMeters ?? 0) / duration
        if metersPerSecond < 1.8 {
            return .walking
        }
        if metersPerSecond < 5.5 {
            return .cycling
        }
        return .vehicle
    }
}
