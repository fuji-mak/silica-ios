import MapKit
import SwiftData
import SwiftUI
import UIKit

private final class LocationMapViewportState {
    var visibleRegion: MKCoordinateRegion?
}

struct LocationMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Query(sort: \StayEntity.arrivalAt, order: .forward) private var stays: [StayEntity]
    @Query(sort: \StayCandidateEntity.arrivalAt, order: .forward) private var stayCandidates: [StayCandidateEntity]
    @Query(sort: \PlaceAliasEntity.priority, order: .reverse) private var aliases: [PlaceAliasEntity]
    @Binding var selectedDate: Date
    @Binding var requestedSelectionID: UUID?
    let onRegisterPlace: (UUID) -> Void
    let onRegisterNewPlace: (UUID) -> Void
    @State private var mapRegion: MKCoordinateRegion?
    @State private var mapRecenterRequest = 0
    @State private var selectedStay: StayEntity?
    @State private var selectedCandidate: StayCandidateEntity?
    @State private var showingDatePicker = false
    @State private var datePickerDate = Calendar.current.startOfDay(for: Date())
    @State private var replayVisibleCount: Int?
    @State private var replayPlaceNameStayID: UUID?
    @State private var replayTask: Task<Void, Never>?
    @State private var viewportState = LocationMapViewportState()
    @State private var edgeZoomStartRegion: MKCoordinateRegion?
    @State private var isEdgeZooming = false
    @State private var mapPlaceRegistrationRequest: MapPlaceRegistrationRequest?
    @State private var isPaywallPresented = false
    @State private var provisionalEvaluationDate = Date()
    @Namespace private var mapDateGlassNamespace

    private static let mapDateControlWidth: CGFloat = 148
    private static let mapTodayControlWidth: CGFloat = 64
    private static let mapDateControlSpacing: CGFloat = 26
    private static let mapDateGlassMorphSpacing: CGFloat = 24

    init(
        selectedDate: Binding<Date>,
        requestedSelectionID: Binding<UUID?>,
        onRegisterPlace: @escaping (UUID) -> Void,
        onRegisterNewPlace: @escaping (UUID) -> Void
    ) {
        self._selectedDate = selectedDate
        self._requestedSelectionID = requestedSelectionID
        self.onRegisterPlace = onRegisterPlace
        self.onRegisterNewPlace = onRegisterNewPlace

        let dayInterval = DateSupport.dayInterval(containing: selectedDate.wrappedValue)
        let dayStart = dayInterval.start
        let dayEnd = dayInterval.end
        let pendingState = StayCandidateState.pending.rawValue
        _stays = Query(
            filter: #Predicate<StayEntity> { stay in
                stay.arrivalAt < dayEnd &&
                    (stay.departureAt ?? dayStart) >= dayStart
            },
            sort: \StayEntity.arrivalAt,
            order: .forward
        )
        _stayCandidates = Query(
            filter: #Predicate<StayCandidateEntity> { candidate in
                candidate.stateRawValue == pendingState &&
                    candidate.arrivalAt < dayEnd
            },
            sort: \StayCandidateEntity.arrivalAt,
            order: .forward
        )
    }

    private var visibleStays: [StayEntity] {
        let dayInterval = DateSupport.dayInterval(containing: selectedDate)
        let now = Date()
        return stays.filter {
            DateSupport.overlaps(
                arrivalAt: $0.arrivalAt,
                departureAt: $0.departureAt,
                dayInterval: dayInterval,
                now: now
            )
        }
    }

    private var displayedStays: [StayEntity] {
        guard let replayVisibleCount else {
            return visibleStays
        }
        return Array(visibleStays.prefix(replayVisibleCount))
    }

    private var mapItems: [StayMapItem] {
        let confirmedItems = displayedStays.enumerated().map { index, stay in
            StayMapItem(
                id: stay.id,
                coordinate: CLLocationCoordinate2D(latitude: stay.latitude, longitude: stay.longitude),
                number: index + 1,
                title: StayResolution.details(for: stay, aliases: aliases).title,
                stay: stay,
                candidate: nil,
                isProvisional: false
            )
        }
        guard replayVisibleCount == nil else {
            return confirmedItems
        }

        let provisionalItems = visibleProvisionalCandidates(at: provisionalEvaluationDate)
            .enumerated()
            .map { index, candidate in
                let details = StayResolution.details(for: candidate, aliases: aliases)
                return StayMapItem(
                    id: candidate.id,
                    coordinate: CLLocationCoordinate2D(
                        latitude: candidate.presentationCoordinate.latitude,
                        longitude: candidate.presentationCoordinate.longitude
                    ),
                    number: confirmedItems.count + index + 1,
                    title: details.title,
                    stay: nil,
                    candidate: candidate,
                    isProvisional: true
                )
            }
        return confirmedItems + provisionalItems
    }

    private func visibleProvisionalCandidates(at now: Date) -> [StayCandidateEntity] {
        let dayInterval = DateSupport.dayInterval(containing: selectedDate)
        guard dayInterval.start <= Calendar.current.startOfDay(for: now) else {
            return []
        }
        return stayCandidates.filter { candidate in
            guard candidate.stateRawValue == StayCandidateState.pending.rawValue else {
                return false
            }
            guard DateSupport.overlaps(
                arrivalAt: candidate.arrivalAt,
                departureAt: candidate.temporalBoundaryAt,
                dayInterval: dayInterval,
                now: now
            ) else {
                return false
            }
            let alreadyRepresented = visibleStays.contains { stay in
                abs(stay.arrivalAt.timeIntervalSince(candidate.arrivalAt)) <= 2 * 60 &&
                    GeoDistance.meters(from: stay.coordinate, to: candidate.presentationCoordinate) <= 500
            }
            guard alreadyRepresented == false else {
                return false
            }
            return true
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            StayMapView(
                region: $mapRegion,
                recenterRequest: mapRecenterRequest,
                animateRegionChanges: isEdgeZooming == false,
                animateNewAnnotations: replayVisibleCount != nil && reduceMotion == false,
                placeNameStayID: replayPlaceNameStayID,
                reportRegionChanges: replayVisibleCount == nil && isEdgeZooming == false,
                selectedStay: $selectedStay,
                selectedCandidate: $selectedCandidate,
                items: mapItems,
                onRegionChange: { region in
                    viewportState.visibleRegion = region
                },
                onLongPressCoordinate: { coordinate in
                    beginMapPlaceRegistration(at: coordinate)
                }
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            rightEdgeZoomGestureArea
                .frame(width: MapEdgeZoom.gestureWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .ignoresSafeArea(.container, edges: .top)

            topDateControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .zIndex(20)

            VStack(spacing: 8) {
                mapControlButton(
                    systemName: "wand.and.stars",
                    accessibilityLabel: AppLanguage.localized("訪問順を再生"),
                    prominent: false
                ) {
                    replayVisitOrder()
                }

                mapControlButton(
                    systemName: "location.fill",
                    accessibilityLabel: AppLanguage.localized("現在地を表示"),
                    prominent: false
                ) {
                    stopReplay()
                    mapRecenterRequest += 1
                    mapRegion = nil
                    triggerRecenterHaptic()
                }

                mapControlButton(
                    systemName: "calendar",
                    accessibilityLabel: AppLanguage.localized("日付を設定"),
                    prominent: true
                ) {
                    openDatePicker()
                }
            }
            .zIndex(10)
            .padding(.trailing, 16)
            .padding(.bottom, 14)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(title: "表示日", date: $datePickerDate) {
                let requestedDate = datePickerDate
                showingDatePicker = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(260))
                    updateSelectedDate(requestedDate)
                }
            }
        }
        .onChange(of: selectedDate) {
            stopReplay()
        }
        .onChange(of: requestedSelectionID, initial: true) {
            selectRequestedMapItem()
        }
        .onChange(of: selectedStay?.id) { _, newValue in
            guard newValue != nil else {
                return
            }
            triggerPinSelectionHaptic()
        }
        .onChange(of: selectedCandidate?.id) { _, newValue in
            guard newValue != nil else {
                return
            }
            triggerPinSelectionHaptic()
        }
        #if DEBUG
        .onAppear {
            guard DebugLaunchConfiguration.usesWideMap else {
                return
            }
            mapRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.682, longitude: 139.745),
                span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.13)
            )
        }
        #endif
        .onDisappear {
            stopReplay()
        }
        .task {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(60))
                guard Task.isCancelled == false else {
                    return
                }
                provisionalEvaluationDate = Date()
            }
        }
        .sheet(item: $selectedStay) { stay in
            StayDetailView(
                stay: stay,
                aliases: aliases,
                displayDate: selectedDate,
                onRegisterPlace: onRegisterPlace,
                onRegisterNewPlace: onRegisterNewPlace,
                onDelete: {
                    selectedStay = nil
                }
            )
                .presentationDetents([.medium])
        }
        .sheet(item: $selectedCandidate) { candidate in
            StayCandidateDetailView(
                candidate: candidate,
                aliases: aliases,
                displayDate: selectedDate,
                onRegisterPlace: onRegisterPlace
            )
            .presentationDetents([.medium])
        }
        .sheet(item: $mapPlaceRegistrationRequest) { request in
            MapPlaceRegistrationSheet(
                coordinate: request.coordinate,
                aliases: aliases
            )
        }
        .sheet(isPresented: $isPaywallPresented) {
            SilicaCustomPaywallView()
        }
    }

    private var visiblePlaceCount: Int {
        PlaceAliasStore.visibleAliases(from: aliases).count
    }

    private func selectRequestedMapItem() {
        guard let requestedSelectionID else {
            return
        }
        guard let item = mapItems.first(where: { $0.id == requestedSelectionID }) else {
            self.requestedSelectionID = nil
            return
        }

        stopReplay()
        if let stay = item.stay {
            selectedCandidate = nil
            selectedStay = stay
        } else if let candidate = item.candidate {
            selectedStay = nil
            selectedCandidate = candidate
        }
        self.requestedSelectionID = nil
    }

    private var requiresProForNewPlace: Bool {
        subscriptionManager.requiresProForNewPlace(existingPlaceCount: visiblePlaceCount)
    }

    private var isPlaceCreationAccessLoading: Bool {
        subscriptionManager.isPlaceCreationAccessLoading(existingPlaceCount: visiblePlaceCount)
    }

    private func beginMapPlaceRegistration(at coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate),
              isPlaceCreationAccessLoading == false else {
            return
        }
        guard requiresProForNewPlace == false else {
            isPaywallPresented = true
            return
        }

        triggerPlaceRegistrationHaptic()
        mapPlaceRegistrationRequest = MapPlaceRegistrationRequest(coordinate: coordinate)
    }

    private var isShowingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private func openDatePicker() {
        datePickerDate = Calendar.current.startOfDay(for: selectedDate)
        showingDatePicker = true
    }

    @ViewBuilder
    private var topDateControls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: Self.mapDateGlassMorphSpacing) {
                topDateControlRow
            }
        } else {
            topDateControlRow
        }
    }

    private var topDateControlRow: some View {
        HStack(spacing: Self.mapDateControlSpacing) {
            mapDateButton

            if isShowingToday == false {
                mapTodayButton
            }
        }
        // Keep the date capsule centered while the trailing control changes
        // the intrinsic width of the HStack.
        .offset(
            x: isShowingToday
                ? 0
                : (Self.mapDateControlSpacing + Self.mapTodayControlWidth) / 2
        )
    }

    @ViewBuilder
    private var mapDateButton: some View {
        let formattedDate = DateSupport.formatDay(selectedDate)
        let button = Button {
            openDatePicker()
        } label: {
            Label(formattedDate, systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.mapDateControlWidth, height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AppLanguage.current == .english
                ? "Display date, \(formattedDate)"
                : "表示日、\(formattedDate)"
        )
        .accessibilityHint(AppLanguage.localized("日付を変更"))

        if #available(iOS 26.0, *) {
            button
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("map-date", in: mapDateGlassNamespace)
        } else {
            button
                .mapHeaderFallbackSurface()
        }
    }

    @ViewBuilder
    private var mapTodayButton: some View {
        let button = Button {
            let today = Calendar.current.startOfDay(for: Date())
            triggerTodayHaptic()
            updateSelectedDate(today, playHaptic: false)
        } label: {
            Text(AppLanguage.localized("今日"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.mapTodayControlWidth, height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLanguage.localized("今日を表示"))
        .accessibilityHint(AppLanguage.localized("今日の位置履歴に戻る"))

        if #available(iOS 26.0, *) {
            button
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("map-today", in: mapDateGlassNamespace)
        } else {
            button
                .mapHeaderFallbackSurface()
        }
    }

    private func triggerDateNavigationHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    private func triggerTodayHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
    }

    private func triggerRecenterHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
    }

    private func triggerPlaceRegistrationHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.82)
    }

    private func triggerReplayHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    private func triggerPinSelectionHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.58)
    }

    private func updateSelectedDate(_ date: Date, playHaptic: Bool = true) {
        guard Calendar.current.isDate(date, inSameDayAs: selectedDate) == false else {
            return
        }
        if playHaptic {
            triggerDateNavigationHaptic()
        }

        if reduceMotion {
            selectedDate = date
            return
        }

        withAnimation {
            selectedDate = date
        }
    }

    private var rightEdgeZoomGestureArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        isEdgeZooming = true
                        updateEdgeZoom(for: value)
                    }
                    .onEnded { _ in
                        isEdgeZooming = false
                        edgeZoomStartRegion = nil
                    }
            )
            .accessibilityHidden(true)
    }

    private func updateEdgeZoom(for value: DragGesture.Value) {
        if edgeZoomStartRegion == nil {
            edgeZoomStartRegion = viewportState.visibleRegion
        }

        guard let startRegion = edgeZoomStartRegion,
              let zoomedRegion = MapEdgeZoom.region(
                startingAt: startRegion,
                translationHeight: value.translation.height
              ) else {
            return
        }

        stopReplay()
        mapRegion = zoomedRegion
    }

    private func replayVisitOrder() {
        let replayStays = visibleStays
        guard let firstStay = replayStays.first else {
            return
        }
        let firstPoint = CLLocationCoordinate2D(
            latitude: firstStay.latitude,
            longitude: firstStay.longitude
        )

        replayTask?.cancel()
        selectedStay = nil
        selectedCandidate = nil
        replayVisibleCount = 0
        replayPlaceNameStayID = nil

        if reduceMotion {
            mapRegion = replayRegion(centeredAt: firstPoint)
            replayVisibleCount = replayStays.count
            triggerReplayHaptic()
            replayTask = nil
            return
        }

        replayTask = Task { @MainActor in
            var previousPoint: CLLocationCoordinate2D?

            for (index, stay) in replayStays.enumerated() {
                if Task.isCancelled {
                    return
                }
                let point = CLLocationCoordinate2D(
                    latitude: stay.latitude,
                    longitude: stay.longitude
                )

                if previousPoint != nil {
                    replayPlaceNameStayID = nil
                    await Task.yield()
                }

                let cameraDuration = replayCameraDuration(from: previousPoint, to: point)
                await moveReplayCamera(from: previousPoint, to: point, duration: cameraDuration)
                if Task.isCancelled {
                    return
                }

                replayPlaceNameStayID = stay.id
                replayVisibleCount = index + 1
                triggerReplayHaptic()

                let pinHoldDelay = replayPinHoldDelay(from: previousPoint, to: point)
                previousPoint = point

                try? await Task.sleep(for: .milliseconds(pinHoldDelay))
            }

            replayPlaceNameStayID = nil
            try? await Task.sleep(for: .milliseconds(240))
            replayVisibleCount = nil
            replayTask = nil
        }
    }

    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        replayPlaceNameStayID = nil
        replayVisibleCount = nil
    }

    private func replayRegion(centeredAt coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        replayRegion(centeredAt: coordinate, spanDelta: 0.025)
    }

    private func replayRegion(centeredAt coordinate: CLLocationCoordinate2D, spanDelta: CLLocationDegrees) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
        )
    }

    private func moveReplayCamera(
        from previous: CLLocationCoordinate2D?,
        to next: CLLocationCoordinate2D,
        duration: TimeInterval
    ) async {
        guard let previous else {
            mapRegion = replayRegion(centeredAt: next)
            try? await Task.sleep(for: .milliseconds(520))
            return
        }

        let zoomedOutSpan = replayZoomedOutSpan(from: previous, to: next)
        let pauseDelay = replayCameraPauseDelay(from: previous, to: next)

        mapRegion = replayRegion(centeredAt: previous, spanDelta: zoomedOutSpan)
        try? await Task.sleep(for: .milliseconds(420 + pauseDelay))
        if Task.isCancelled {
            return
        }

        mapRegion = replayRegion(centeredAt: next, spanDelta: zoomedOutSpan)
        try? await Task.sleep(for: .milliseconds(max(560, Int(duration * 1000))))
        if Task.isCancelled {
            return
        }

        mapRegion = replayRegion(centeredAt: next)
        try? await Task.sleep(for: .milliseconds(540 + pauseDelay / 2))
    }

    private func replayCameraDuration(from previous: CLLocationCoordinate2D?, to next: CLLocationCoordinate2D) -> TimeInterval {
        guard let previous else {
            return 0.7
        }

        let distance = replayDistance(from: previous, to: next)
        return min(2.55, 0.72 + log1p(distance / 350) * 0.42)
    }

    private func replayZoomedOutSpan(from previous: CLLocationCoordinate2D, to next: CLLocationCoordinate2D) -> CLLocationDegrees {
        let latitudeDelta = abs(previous.latitude - next.latitude)
        let longitudeDelta = abs(previous.longitude - next.longitude)
        let distance = replayDistance(from: previous, to: next)
        let distanceSpan = 0.025 + log1p(distance / 800) * 0.035
        return min(0.28, max(0.045, latitudeDelta * 2.6, longitudeDelta * 2.6, distanceSpan))
    }

    private func replayCameraPauseDelay(from previous: CLLocationCoordinate2D, to next: CLLocationCoordinate2D) -> Int {
        let distance = replayDistance(from: previous, to: next)
        return min(520, Int(log1p(distance / 500) * 150))
    }

    private func replayPinHoldDelay(from previous: CLLocationCoordinate2D?, to next: CLLocationCoordinate2D) -> Int {
        guard let previous else {
            return 760
        }

        let distance = replayDistance(from: previous, to: next)
        return min(1_120, 760 + Int(log1p(distance / 500) * 110))
    }

    private func replayDistance(
        from previous: CLLocationCoordinate2D,
        to next: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
    }

    @ViewBuilder
    private func mapControlButton(
        systemName: String,
        accessibilityLabel: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let foregroundColor = prominent ? Color.white : Color.accentColor
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(accessibilityLabel)

        if #available(iOS 26.0, *) {
            if prominent {
                button
                    .buttonStyle(.plain)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .glassEffect(
                        .regular
                            .tint(Color.accentColor)
                            .interactive(),
                        in: Circle()
                    )
            } else {
                button
                    .buttonStyle(.plain)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        } else {
            button
                .buttonStyle(.plain)
                .frame(width: 52, height: 52)
                .background(
                    prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(.white.opacity(prominent ? 0.28 : 0.62), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        }
    }
}

private extension View {
    func mapHeaderFallbackSurface() -> some View {
        background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.5), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
    }
}

private struct StayMapItem {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let number: Int
    let title: String
    let stay: StayEntity?
    let candidate: StayCandidateEntity?
    let isProvisional: Bool
}

private final class StayMapAnnotation: NSObject, MKAnnotation {
    let id: UUID
    dynamic var coordinate: CLLocationCoordinate2D
    var number: Int
    var title: String?

    init(item: StayMapItem) {
        id = item.id
        coordinate = item.coordinate
        number = item.number
        title = item.title
    }
}

private struct AnnotationSignature: Equatable {
    let id: UUID
    let number: Int
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
    let title: String
    let isProvisional: Bool
}

private struct StayMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion?
    let recenterRequest: Int
    let animateRegionChanges: Bool
    let animateNewAnnotations: Bool
    let placeNameStayID: UUID?
    let reportRegionChanges: Bool
    @Binding var selectedStay: StayEntity?
    @Binding var selectedCandidate: StayCandidateEntity?
    let items: [StayMapItem]
    let onRegionChange: (MKCoordinateRegion) -> Void
    let onLongPressCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            region: $region,
            selectedStay: $selectedStay,
            selectedCandidate: $selectedCandidate,
            onRegionChange: onRegionChange,
            onLongPressCoordinate: onLongPressCoordinate
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        mapView.isPitchEnabled = false
        mapView.accessibilityHint = AppLanguage.localized("地図を長押しして場所を登録")
        let longPressRecognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapLongPress(_:))
        )
        longPressRecognizer.minimumPressDuration = 0.55
        longPressRecognizer.allowableMovement = 18
        mapView.addGestureRecognizer(longPressRecognizer)
        context.coordinator.updateAnnotations(in: mapView, items: items)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.region = $region
        context.coordinator.selectedStay = $selectedStay
        context.coordinator.selectedCandidate = $selectedCandidate
        context.coordinator.onLongPressCoordinate = onLongPressCoordinate
        context.coordinator.animateNewAnnotations = animateNewAnnotations
        context.coordinator.placeNameStayID = placeNameStayID
        context.coordinator.setRegionReporting(reportRegionChanges)
        context.coordinator.updateAnnotations(in: mapView, items: items)
        context.coordinator.apply(
            region: region,
            recenterRequest: recenterRequest,
            animated: animateRegionChanges,
            to: mapView
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var region: Binding<MKCoordinateRegion?>
        var selectedStay: Binding<StayEntity?>
        var selectedCandidate: Binding<StayCandidateEntity?>
        let onRegionChange: (MKCoordinateRegion) -> Void
        var onLongPressCoordinate: (CLLocationCoordinate2D) -> Void
        var animateNewAnnotations = false
        var placeNameStayID: UUID?
        private var itemsByID: [UUID: StayMapItem] = [:]
        private var shouldReportRegionChanges = false
        private var latestRegion: MKCoordinateRegion?
        private var lastAnnotationSignature: [AnnotationSignature] = []
        private var lastSelectedStayID: UUID?
        private var lastPlaceNameStayID: UUID?
        private var lastRecenterRequest = 0
        private var hasAppliedInitialMapState = false

        init(
            region: Binding<MKCoordinateRegion?>,
            selectedStay: Binding<StayEntity?>,
            selectedCandidate: Binding<StayCandidateEntity?>,
            onRegionChange: @escaping (MKCoordinateRegion) -> Void,
            onLongPressCoordinate: @escaping (CLLocationCoordinate2D) -> Void
        ) {
            self.region = region
            self.selectedStay = selectedStay
            self.selectedCandidate = selectedCandidate
            self.onRegionChange = onRegionChange
            self.onLongPressCoordinate = onLongPressCoordinate
        }

        @objc
        func handleMapLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let mapView = recognizer.view as? MKMapView else {
                return
            }
            let coordinate = mapView.convert(
                recognizer.location(in: mapView),
                toCoordinateFrom: mapView
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else {
                return
            }
            onLongPressCoordinate(coordinate)
        }

        func setRegionReporting(_ enabled: Bool) {
            let didEnableReporting = enabled && shouldReportRegionChanges == false
            shouldReportRegionChanges = enabled

            if didEnableReporting, let latestRegion {
                onRegionChange(latestRegion)
            }
        }

        func updateAnnotations(in mapView: MKMapView, items: [StayMapItem]) {
            itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

            let annotationSignature = items.map {
                AnnotationSignature(
                    id: $0.id,
                    number: $0.number,
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    title: $0.title,
                    isProvisional: $0.isProvisional
                )
            }
            let itemsChanged = annotationSignature != lastAnnotationSignature
            let selectedItemID = selectedStay.wrappedValue?.id
                ?? selectedCandidate.wrappedValue?.id
            let selectionChanged = selectedItemID != lastSelectedStayID
            let placeNameIDChanged = placeNameStayID != lastPlaceNameStayID

            if itemsChanged {
                lastAnnotationSignature = annotationSignature

                let existing = mapView.annotations.compactMap { $0 as? StayMapAnnotation }
                let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                let ids = Set(itemsByID.keys)
                let removed = existing.filter { ids.contains($0.id) == false }
                if removed.isEmpty == false {
                    mapView.removeAnnotations(removed)
                }

                for item in items {
                    if let annotation = existingByID[item.id] {
                        annotation.coordinate = item.coordinate
                        annotation.number = item.number
                        annotation.title = item.title
                    } else {
                        mapView.addAnnotation(StayMapAnnotation(item: item))
                    }
                }
            }

            if placeNameIDChanged {
                if itemsChanged || selectionChanged {
                    refreshAnnotationViews(in: mapView, activePlaceNameID: lastPlaceNameStayID)
                }
                if let lastPlaceNameStayID {
                    hidePlaceName(for: lastPlaceNameStayID, in: mapView)
                }
                if let placeNameStayID {
                    refreshAnnotationView(
                        for: placeNameStayID,
                        in: mapView,
                        showsPlaceName: true
                    )
                }
            } else if itemsChanged || selectionChanged {
                refreshAnnotationViews(in: mapView, activePlaceNameID: placeNameStayID)
            }
            lastSelectedStayID = selectedItemID
            lastPlaceNameStayID = placeNameStayID
            if let selectedItemID,
               mapView.selectedAnnotations.contains(where: {
                   ($0 as? StayMapAnnotation)?.id == selectedItemID
               }) == false,
               let annotation = mapView.annotations
                   .compactMap({ $0 as? StayMapAnnotation })
                   .first(where: { $0.id == selectedItemID }) {
                hasAppliedInitialMapState = true
                mapView.setUserTrackingMode(.none, animated: false)
                mapView.selectAnnotation(annotation, animated: false)
                mapView.setCenter(annotation.coordinate, animated: true)
            } else if selectedItemID == nil,
                      let selected = mapView.selectedAnnotations.first {
                mapView.deselectAnnotation(selected, animated: false)
            }
        }

        func apply(
            region: MKCoordinateRegion?,
            recenterRequest: Int,
            animated: Bool,
            to mapView: MKMapView
        ) {
            if recenterRequest != lastRecenterRequest {
                lastRecenterRequest = recenterRequest
                hasAppliedInitialMapState = true
                mapView.setUserTrackingMode(.follow, animated: true)
                return
            }

            if let region {
                hasAppliedInitialMapState = true
                mapView.userTrackingMode = .none
                if approximatelyEqual(mapView.region, region) == false {
                    mapView.setRegion(region, animated: animated)
                }
            } else if hasAppliedInitialMapState == false {
                hasAppliedInitialMapState = true
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let item = item(for: annotation) else {
                return nil
            }

            let view = (mapView.dequeueReusableAnnotationView(
                withIdentifier: VisitOrderAnnotationView.reuseIdentifier
            ) as? VisitOrderAnnotationView) ?? VisitOrderAnnotationView(
                annotation: annotation,
                reuseIdentifier: VisitOrderAnnotationView.reuseIdentifier
            )
            view.annotation = annotation
            view.isEnabled = item.stay != nil || item.candidate != nil
            view.configure(
                number: item.number,
                title: item.title,
                isSelected: selectedItemID == item.id,
                showsPlaceName: item.id == placeNameStayID,
                isProvisional: item.isProvisional
            )
            return view
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            guard animateNewAnnotations else {
                return
            }

            for view in views {
                (view as? VisitOrderAnnotationView)?.animateIn()
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard
                let annotation = view.annotation as? StayMapAnnotation,
                let item = item(for: annotation)
            else {
                return
            }

            // Selecting a pin should take the map out of user-location
            // tracking first. Otherwise a location update can immediately
            // move the map back after the pin has been centered.
            hasAppliedInitialMapState = true
            mapView.setUserTrackingMode(.none, animated: false)
            mapView.setCenter(annotation.coordinate, animated: true)
            region.wrappedValue = nil
            if let stay = item.stay {
                selectedCandidate.wrappedValue = nil
                selectedStay.wrappedValue = stay
            } else if let candidate = item.candidate {
                selectedStay.wrappedValue = nil
                selectedCandidate.wrappedValue = candidate
            } else {
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            refreshAnnotationViews(in: mapView, activePlaceNameID: placeNameStayID)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let annotation = view.annotation as? StayMapAnnotation else {
                return
            }
            if selectedStay.wrappedValue?.id == annotation.id {
                selectedStay.wrappedValue = nil
            }
            if selectedCandidate.wrappedValue?.id == annotation.id {
                selectedCandidate.wrappedValue = nil
            }
            region.wrappedValue = nil
            refreshAnnotationViews(in: mapView, activePlaceNameID: placeNameStayID)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            latestRegion = mapView.region
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            latestRegion = mapView.region
            if shouldReportRegionChanges {
                onRegionChange(mapView.region)
            }
        }

        private func item(for annotation: MKAnnotation?) -> StayMapItem? {
            guard let annotation = annotation as? StayMapAnnotation else {
                return nil
            }
            return itemsByID[annotation.id]
        }

        private func refreshAnnotationViews(
            in mapView: MKMapView,
            activePlaceNameID: UUID?
        ) {
            for annotation in mapView.annotations {
                guard
                    let stayAnnotation = annotation as? StayMapAnnotation,
                    let item = item(for: stayAnnotation),
                    let view = mapView.view(for: stayAnnotation) as? VisitOrderAnnotationView
                else {
                    continue
                }
                view.configure(
                    number: item.number,
                    title: item.title,
                    isSelected: selectedItemID == item.id,
                    showsPlaceName: item.id == activePlaceNameID,
                    isProvisional: item.isProvisional
                )
            }
        }

        private func refreshAnnotationView(
            for id: UUID,
            in mapView: MKMapView,
            showsPlaceName: Bool
        ) {
            guard
                let annotation = mapView.annotations
                    .compactMap({ $0 as? StayMapAnnotation })
                    .first(where: { $0.id == id }),
                let item = item(for: annotation),
                let view = mapView.view(for: annotation) as? VisitOrderAnnotationView
            else {
                return
            }
            view.configure(
                number: item.number,
                title: item.title,
                isSelected: selectedItemID == item.id,
                showsPlaceName: showsPlaceName,
                isProvisional: item.isProvisional
            )
        }

        private func hidePlaceName(for id: UUID, in mapView: MKMapView) {
            guard
                let annotation = mapView.annotations
                    .compactMap({ $0 as? StayMapAnnotation })
                    .first(where: { $0.id == id })
            else {
                return
            }
            (mapView.view(for: annotation) as? VisitOrderAnnotationView)?
                .hidePlaceName(animated: true)
        }

        private func approximatelyEqual(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.00001 &&
                abs(lhs.center.longitude - rhs.center.longitude) < 0.00001 &&
                abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.00001 &&
                abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.00001
        }

        private var selectedItemID: UUID? {
            selectedStay.wrappedValue?.id ?? selectedCandidate.wrappedValue?.id
        }
    }
}

private final class VisitOrderAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "VisitOrderAnnotationView"

    private let numberLabel = UILabel()
    private let placeNameLabel = UILabel()
    private var isSelectedPin = false
    private var showsPlaceName = false
    private var placeNameAnimationToken = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false
        displayPriority = .required
        selectedZPriority = .max

        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        numberLabel.clipsToBounds = true
        numberLabel.layer.borderWidth = 2
        numberLabel.layer.borderColor = UIColor.white.cgColor
        numberLabel.layer.masksToBounds = true
        numberLabel.layer.cornerCurve = .continuous
        numberLabel.isAccessibilityElement = false
        addSubview(numberLabel)

        placeNameLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        placeNameLabel.textColor = .label
        placeNameLabel.textAlignment = .center
        placeNameLabel.numberOfLines = 1
        placeNameLabel.lineBreakMode = .byTruncatingTail
        placeNameLabel.clipsToBounds = false
        placeNameLabel.layer.masksToBounds = false
        placeNameLabel.backgroundColor = .clear
        placeNameLabel.shadowColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.82)
                : UIColor.white.withAlphaComponent(0.9)
        }
        placeNameLabel.shadowOffset = CGSize(width: 0, height: 1)
        placeNameLabel.isAccessibilityElement = false
        addSubview(placeNameLabel)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        number: Int,
        title: String,
        isSelected: Bool,
        showsPlaceName: Bool,
        isProvisional: Bool
    ) {
        placeNameAnimationToken += 1
        isSelectedPin = isSelected
        self.showsPlaceName = (showsPlaceName || isProvisional) && title.isEmpty == false
        numberLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: number < 100 ? 15 : 13,
            weight: .bold
        )
        numberLabel.text = "\(number)"
        if isProvisional {
            numberLabel.backgroundColor = .systemOrange
        } else {
            numberLabel.backgroundColor = isSelected
                ? UIColor(red: 0.02, green: 0.31, blue: 0.72, alpha: 1)
                : UIColor.systemBlue
        }

        placeNameLabel.text = title
        placeNameLabel.isHidden = self.showsPlaceName == false
        placeNameLabel.alpha = 1
        applyLayout(showingPlaceName: self.showsPlaceName)

        transform = isSelected ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity

        // MapKit uses this value when annotation views overlap. Give the
        // larger visit number the larger priority, independent of latitude.
        zPriority = MKAnnotationViewZPriority(Float(number))
        accessibilityLabel = if isProvisional {
            AppLanguage.current == .english
                ? "Unconfirmed visit \(number)"
                : "未確定の\(number)番目の訪問"
        } else {
            AppLanguage.current == .english
                ? "Visit \(number)"
                : "\(number)番目の訪問"
        }
        accessibilityValue = title
        accessibilityIdentifier = isProvisional
            ? "provisional-map-pin"
            : "confirmed-map-pin"
        isAccessibilityElement = true
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    func animateIn() {
        layer.removeAllAnimations()
        numberLabel.layer.removeAllAnimations()

        alpha = 0
        placeNameLabel.alpha = showsPlaceName ? 0 : 1
        transform = CGAffineTransform(translationX: 0, y: 12)
            .scaledBy(x: 0.48, y: 0.48)

        UIView.animate(
            withDuration: 0.56,
            delay: 0,
            usingSpringWithDamping: 0.66,
            initialSpringVelocity: 0.25,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) { [weak self] in
            guard let self else {
                return
            }
            alpha = 1
            transform = isSelectedPin
                ? CGAffineTransform(scaleX: 1.12, y: 1.12)
                : .identity
        }

        guard showsPlaceName else {
            return
        }

        UIView.animate(
            withDuration: 0.28,
            delay: 0.08,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { [weak self] in
            self?.placeNameLabel.alpha = 1
        }
    }

    func hidePlaceName(animated: Bool) {
        guard showsPlaceName else {
            return
        }

        placeNameAnimationToken += 1
        let animationToken = placeNameAnimationToken
        let finish = { [weak self] in
            guard let self, self.placeNameAnimationToken == animationToken else {
                return
            }
            self.showsPlaceName = false
            self.placeNameLabel.isHidden = true
            self.placeNameLabel.alpha = 1
            self.applyLayout(showingPlaceName: false)
        }

        guard animated else {
            finish()
            return
        }

        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) { [weak self] in
            guard let self else {
                return
            }
            self.placeNameLabel.alpha = 0
            self.applyLayout(showingPlaceName: false)
        } completion: { _ in
            finish()
        }
    }

    private func applyLayout(showingPlaceName: Bool) {
        let badgeHeight: CGFloat = 34
        let nameHeight: CGFloat = 22
        let numberTextCount = numberLabel.text?.count ?? 0
        let badgeWidth = max(
            badgeHeight,
            numberLabel.intrinsicContentSize.width + (numberTextCount < 2 ? 0 : 14)
        )

        let nameWidth: CGFloat
        if showingPlaceName {
            let nameSize = placeNameLabel.sizeThatFits(CGSize(width: 180, height: nameHeight))
            nameWidth = min(180, max(42, nameSize.width + 16))
        } else {
            nameWidth = 0
        }

        let totalWidth = showingPlaceName ? max(badgeWidth, nameWidth) : badgeWidth
        let totalHeight = showingPlaceName ? badgeHeight + 4 + nameHeight : badgeHeight
        bounds = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)

        let badgeFrame = CGRect(
            x: (totalWidth - badgeWidth) / 2,
            y: showingPlaceName ? nameHeight + 4 : 0,
            width: badgeWidth,
            height: badgeHeight
        )
        numberLabel.frame = badgeFrame
        numberLabel.layer.cornerRadius = badgeHeight / 2

        if showingPlaceName {
            placeNameLabel.frame = CGRect(
                x: (totalWidth - nameWidth) / 2,
                y: 0,
                width: nameWidth,
                height: nameHeight
            )
        } else {
            placeNameLabel.frame = .zero
        }
        centerOffset = CGPoint(x: 0, y: -totalHeight / 2)

        let shadowPath = CGMutablePath()
        shadowPath.addRoundedRect(
            in: badgeFrame,
            cornerWidth: badgeHeight / 2,
            cornerHeight: badgeHeight / 2,
            transform: .identity
        )
        layer.shadowPath = shadowPath
    }
}
