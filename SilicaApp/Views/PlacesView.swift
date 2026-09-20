import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit
#if canImport(SilicaCore)
import SilicaCore
#endif

private final class PlacesViewportState {
    var visibleRegion: MKCoordinateRegion?
}

private enum PlacesRoute: Hashable {
    case alias(UUID)
    case register(UUID)
}

struct PlacesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    let isGuidedSetup: Bool
    let onGuidedPlaceSaved: () -> Void
    @State private var didSaveGuidedPlace = false
    @Binding var selectedAliasID: UUID?
    @Binding var pendingStayRegistrationID: UUID?
    @Query(sort: \PlaceAliasEntity.priority, order: .reverse) private var aliases: [PlaceAliasEntity]
    @Query(sort: \StayEntity.arrivalAt, order: .reverse) private var stays: [StayEntity]
    @State private var path: [PlacesRoute] = []
    @State private var displayMode = PlacesDisplayMode.list
    @State private var modeSwipeProgress: CGFloat = 0
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var viewportState = PlacesViewportState()
    @State private var edgeZoomStartRegion: MKCoordinateRegion?
    @State private var showingPlacePicker = false
    @State private var isPaywallPresented = false
    @State private var mapPlaceRegistrationRequest: MapPlaceRegistrationRequest?
    @Namespace private var mapScope

    private static let modeSwipeMinimumDistance: CGFloat = 24
    private static let modeSwipeActivationDistance: CGFloat = 56

    init(
        selectedAliasID: Binding<UUID?>,
        pendingStayRegistrationID: Binding<UUID?>,
        isGuidedSetup: Bool = false,
        onGuidedPlaceSaved: @escaping () -> Void = {}
    ) {
        self.isGuidedSetup = isGuidedSetup
        self.onGuidedPlaceSaved = onGuidedPlaceSaved
        _displayMode = State(initialValue: isGuidedSetup ? .map : .list)
        _modeSwipeProgress = State(initialValue: isGuidedSetup ? 1 : 0)
        _selectedAliasID = selectedAliasID
        _pendingStayRegistrationID = pendingStayRegistrationID
        _aliases = Query(sort: \PlaceAliasEntity.priority, order: .reverse)
        _stays = Query(sort: \StayEntity.arrivalAt, order: .reverse)
    }

    private var visibleAliases: [PlaceAliasEntity] {
        PlaceAliasStore.visibleAliases(from: aliases)
    }

    private func makeNumberedPlaces(from aliases: [PlaceAliasEntity]) -> [NumberedPlace] {
        aliases.enumerated().map { offset, alias in
            NumberedPlace(
                number: offset + 1,
                alias: alias
            )
        }
    }

    var body: some View {
        let currentVisibleAliases = visibleAliases
        let numberedPlaces = makeNumberedPlaces(from: currentVisibleAliases)

        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear
                                .frame(height: 68)
                                .accessibilityHidden(true)

                            placesList(numberedPlaces: numberedPlaces, stays: stays)
                        }
                        .padding(.bottom, 36)
                    }
                    .offset(x: -geometry.size.width * modeSwipeProgress)
                    .allowsHitTesting(displayMode == .list)
                    .accessibilityHidden(displayMode != .list)
                    .simultaneousGesture(listToMapSwipeGesture(width: geometry.size.width))

                    if displayMode == .map || modeSwipeProgress > 0 {
                        placesMap(numberedPlaces: numberedPlaces)
                            .frame(width: geometry.size.width)
                            .ignoresSafeArea(
                                .container,
                                edges: isGuidedSetup ? [.top, .horizontal] : .all
                            )
                            .offset(x: geometry.size.width * (1 - modeSwipeProgress))
                            .allowsHitTesting(displayMode == .map)
                            .accessibilityHidden(displayMode != .map)
                    }

                    if displayMode == .map {
                        userLocationButton
                            .zIndex(30)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .bottomTrailing
                            )
                            .padding(.trailing, 16)
                            .padding(.bottom, 14)
                    }
                }

            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isGuidedSetup {
                    placeSetupGuide
                }
            }
            .onChange(of: isGuidedSetup) { _, isActive in
                if isActive {
                    path = []
                    displayMode = .map
                    modeSwipeProgress = 1
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(AppLanguage.localized("場所"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isShowingFullscreenMap ? .hidden : .visible, for: .navigationBar)
            .sheet(isPresented: $showingPlacePicker) {
                PlaceCandidatePicker(stays: stays, aliases: currentVisibleAliases) { aliasID in
                    path = [.alias(aliasID)]
                }
            }
            .onAppear {
                PlaceAliasStore.deduplicate(aliases: aliases, modelContext: modelContext)
                updateCameraPosition()
                openSelectedAliasIfNeeded()
                openPendingPlaceRegistrationIfNeeded()
            }
            .onChange(of: selectedAliasID) {
                openSelectedAliasIfNeeded()
            }
            .onChange(of: pendingStayRegistrationID) {
                openPendingPlaceRegistrationIfNeeded()
            }
            .onChange(of: stays.map(\.id)) {
                openPendingPlaceRegistrationIfNeeded()
            }
            .onChange(of: aliases.map(\.id)) {
                updateCameraPosition()
                openSelectedAliasIfNeeded()
            }
            .onChange(of: aliases.map(\.radiusMeters)) {
                updateCameraPosition()
            }
            .onChange(of: displayMode) { _, newMode in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                    modeSwipeProgress = newMode == .map ? 1 : 0
                }
            }
            .navigationDestination(for: PlacesRoute.self, destination: destination)
        }
        .overlay(alignment: .top) {
            if path.isEmpty && isGuidedSetup == false {
                persistentTopControls
                    .safeAreaPadding(.top, 8)
                    .offset(y: displayMode == .list ? 44 : 0)
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.62),
                        value: displayMode
                    )
                    .zIndex(20)
            }
        }
        .sheet(isPresented: $isPaywallPresented) {
            SilicaCustomPaywallView()
        }
        .sheet(item: $mapPlaceRegistrationRequest, onDismiss: {
            if didSaveGuidedPlace {
                didSaveGuidedPlace = false
                onGuidedPlaceSaved()
            }
        }) { request in
            MapPlaceRegistrationSheet(
                coordinate: request.coordinate,
                aliases: aliases,
                isGuidedSetup: isGuidedSetup,
                onSaved: { _ in
                    didSaveGuidedPlace = isGuidedSetup
                }
            )
        }
    }

    private var placeSetupGuide: some View {
        GuidedSetupCard(
            step: 1,
            title: "自宅や職場を登録しましょう",
            message: "地図を動かし、登録する場所を長押ししてください。",
            titleIdentifier: "guidedSetup.placeGuide"
        )
    }

    private var isShowingFullscreenMap: Bool {
        path.isEmpty && (displayMode == .map || modeSwipeProgress > 0.001)
    }

    private var persistentTopControls: some View {
        ZStack {
            persistentModePicker

            HStack {
                Spacer()
                floatingAddPlaceButton
            }
        }
        .padding(.horizontal, 16)
    }

    private var persistentModePicker: some View {
        PlacesModePicker(selection: $displayMode)
            .frame(width: 224, height: 48)
    }

    @ViewBuilder
    private var floatingAddPlaceButton: some View {
        if #available(iOS 26.0, *) {
            addPlaceButton
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            addPlaceButton
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.primary.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
        }
    }

    private var addPlaceButton: some View {
        Button {
            guard isPlaceCreationAccessLoading == false else {
                return
            }
            guard requiresProForNewPlace == false else {
                isPaywallPresented = true
                return
            }
            showingPlacePicker = true
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .foregroundStyle(.primary)
        .disabled(isPlaceCreationAccessLoading)
        .accessibilityLabel(AppLanguage.localized("場所を追加"))
    }

    private var requiresProForNewPlace: Bool {
        subscriptionManager.requiresProForNewPlace(existingPlaceCount: visibleAliases.count)
    }

    private func openPendingPlaceRegistrationIfNeeded() {
        guard let stayID = pendingStayRegistrationID,
              stays.contains(where: { $0.id == stayID }) else {
            return
        }

        path = [.register(stayID)]
        pendingStayRegistrationID = nil
    }

    private func savePlace(
        from stay: StayEntity,
        name: String,
        symbolName: String,
        radiusMeters: Double,
        priority: Int
    ) {
        let alias = PlaceAliasStore.upsert(
            name: name,
            latitude: stay.latitude,
            longitude: stay.longitude,
            radiusMeters: radiusMeters,
            priority: priority,
            sourcePlaceName: LocationFormatter.placeName(for: stay),
            address: LocationFormatter.address(for: stay),
            aliases: aliases,
            modelContext: modelContext
        )
        alias.symbolName = symbolName
        alias.updatedAt = Date()
        try? modelContext.save()
        path = [.alias(alias.id)]
        selectedAliasID = alias.id
    }

    @ViewBuilder
    private func destination(for route: PlacesRoute) -> some View {
        switch route {
        case .alias(let aliasID):
            if let alias = aliases.first(where: { $0.id == aliasID }) {
                PlaceEditorView(alias: alias)
            } else {
                ContentUnavailableView(
                    AppLanguage.localized("場所が見つかりません"),
                    systemImage: "mappin.slash"
                )
            }
        case .register(let stayID):
            if let stay = stays.first(where: { $0.id == stayID }) {
            PlaceRegistrationView(stay: stay) { name, symbolName, radiusMeters, priority in
                savePlace(
                    from: stay,
                    name: name,
                    symbolName: symbolName,
                    radiusMeters: radiusMeters,
                    priority: priority
                )
            }
            } else {
                ContentUnavailableView(
                    AppLanguage.localized("滞在が見つかりません"),
                    systemImage: "mappin.slash"
                )
            }
        }
    }

    private var isPlaceCreationAccessLoading: Bool {
        subscriptionManager.isPlaceCreationAccessLoading(existingPlaceCount: visibleAliases.count)
    }

    private func placesMap(numberedPlaces: [NumberedPlace]) -> some View {
        MapReader { proxy in
            Map(position: $cameraPosition, scope: mapScope) {
                UserAnnotation()

                ForEach(numberedPlaces) { place in
                    MapCircle(
                        center: CLLocationCoordinate2D(
                            latitude: place.alias.latitude,
                            longitude: place.alias.longitude
                        ),
                        radius: max(1, place.alias.radiusMeters)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.10))
                    .stroke(Color.accentColor.opacity(0.64), lineWidth: 1.15)
                }

                ForEach(numberedPlaces) { place in
                    Annotation(
                        "",
                        coordinate: CLLocationCoordinate2D(
                            latitude: place.alias.latitude,
                            longitude: place.alias.longitude
                        ),
                        anchor: .center
                    ) {
                        PlaceMapMarker(place: place) {
                            triggerPlaceSelectionHaptic()
                            path = [.alias(place.id)]
                        }
                        .zIndex(Double(place.number))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapScope(mapScope)
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .continuous) { context in
                viewportState.visibleRegion = context.region
            }
            .simultaneousGesture(mapPlaceLongPressGesture(proxy: proxy))
            .accessibilityHint(AppLanguage.localized("地図を長押しして場所を登録"))
            .accessibilityIdentifier("places.map")
            .accessibilityAction(named: AppLanguage.localized("地図の中心を登録")) {
                if let coordinate = viewportState.visibleRegion?.center {
                    beginMapPlaceRegistration(at: coordinate)
                }
            }
            .overlay(alignment: .trailing) {
                rightEdgeZoomGestureArea
                    .frame(width: MapEdgeZoom.gestureWidth)
            }
        }
    }

    private func mapPlaceLongPressGesture(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .local
                )
            )
            .onEnded { value in
                guard
                    case .second(true, let dragValue?) = value,
                    let coordinate = proxy.convert(dragValue.location, from: .local)
                else {
                    return
                }
                beginMapPlaceRegistration(at: coordinate)
            }
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

    private func listToMapSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Self.modeSwipeMinimumDistance)
            .onChanged { value in
                guard displayMode == .list,
                      value.translation.width < 0,
                      abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                modeSwipeProgress = min(
                    1,
                    max(0, -value.translation.width / max(width, 1))
                )
            }
            .onEnded { value in
                guard displayMode == .list else {
                    return
                }

                let progress = min(
                    1,
                    max(0, -value.translation.width / max(width, 1))
                )
                let isHorizontalSwipe = abs(value.translation.width) > abs(value.translation.height)
                let shouldOpenMap = isHorizontalSwipe && (
                    -value.translation.width >= Self.modeSwipeActivationDistance
                        || progress >= 0.28
                        || -value.predictedEndTranslation.width >= width * 0.5
                )

                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                    if shouldOpenMap {
                        displayMode = .map
                        modeSwipeProgress = 1
                    } else {
                        modeSwipeProgress = 0
                    }
                }
            }
    }

    @ViewBuilder
    private var userLocationButton: some View {
        if #available(iOS 26.0, *) {
            userLocationControl
                .buttonStyle(.plain)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            userLocationControl
                .buttonStyle(.plain)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    ZStack {
                        Circle()
                            .stroke(.primary.opacity(0.10), lineWidth: 0.8)
                        userLocationIcon
                    }
                }
                .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
        }
    }

    private var userLocationControl: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                cameraPosition = .userLocation(
                    followsHeading: false,
                    fallback: .automatic
                )
            }
            triggerRecenterHaptic()
        } label: {
            userLocationIcon
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(AppLanguage.localized("現在地を表示"))
    }

    private func triggerRecenterHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.9)
    }

    private func triggerPlaceSelectionHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    private func triggerPlaceRegistrationHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.82)
    }

    private var userLocationIcon: some View {
        Image(systemName: "location.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var rightEdgeZoomGestureArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged(updateEdgeZoom)
                    .onEnded { _ in
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

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cameraPosition = .region(zoomedRegion)
        }
    }

    private func placesList(
        numberedPlaces: [NumberedPlace],
        stays: [StayEntity]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if numberedPlaces.isEmpty {
                ContentUnavailableView(
                    AppLanguage.localized("登録場所はありません"),
                    systemImage: "mappin.and.ellipse",
                    description: Text(AppLanguage.localized("上部の＋から、過去の滞在を場所として登録できます。"))
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(numberedPlaces) { place in
                        Button {
                        path = [.alias(place.id)]
                        } label: {
                            PlaceRow(place: place, stays: stays)
                        }
                        .buttonStyle(.plain)

                        if place.id != numberedPlaces.last?.id {
                            Divider()
                                .padding(.leading, 88)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    private func updateCameraPosition() {
        guard visibleAliases.isEmpty == false else {
            cameraPosition = .automatic
            return
        }

        let bounds = visibleAliases.map { alias in
            let radiusMeters = max(0, alias.radiusMeters)
            let latitudeRadius = radiusMeters / 111_000
            let longitudeMetersPerDegree = 111_000 * max(
                0.2,
                cos(alias.latitude * .pi / 180)
            )
            let longitudeRadius = radiusMeters / longitudeMetersPerDegree
            return (
                minimumLatitude: alias.latitude - latitudeRadius,
                maximumLatitude: alias.latitude + latitudeRadius,
                minimumLongitude: alias.longitude - longitudeRadius,
                maximumLongitude: alias.longitude + longitudeRadius
            )
        }
        guard let minimumLatitude = bounds.map(\.minimumLatitude).min(),
              let maximumLatitude = bounds.map(\.maximumLatitude).max(),
              let minimumLongitude = bounds.map(\.minimumLongitude).min(),
              let maximumLongitude = bounds.map(\.maximumLongitude).max() else {
            return
        }

        let center = CLLocationCoordinate2D(
            latitude: (minimumLatitude + maximumLatitude) / 2,
            longitude: (minimumLongitude + maximumLongitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.012, (maximumLatitude - minimumLatitude) * 1.45),
            longitudeDelta: max(0.012, (maximumLongitude - minimumLongitude) * 1.45)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func openSelectedAliasIfNeeded() {
        guard let selectedAliasID else {
            return
        }
        guard aliases.contains(where: { $0.id == selectedAliasID }) else {
            return
        }
        path = [.alias(selectedAliasID)]
        self.selectedAliasID = nil
    }
}

private enum PlacesDisplayMode: String, CaseIterable, Identifiable {
    case list = "一覧"
    case map = "地図"

    var id: Self { self }

    var localizedTitle: String {
        AppLanguage.localized(rawValue)
    }
}

private struct NumberedPlace: Identifiable {
    let number: Int
    let alias: PlaceAliasEntity

    var id: UUID { alias.id }
}

private struct PlacesModePicker: View {
    @Binding var selection: PlacesDisplayMode

    var body: some View {
        GlassSegmentedPicker(
            selection: $selection,
            options: PlacesDisplayMode.allCases.map {
                GlassSegmentOption(title: $0.localizedTitle, value: $0)
            },
            accessibilityLabel: AppLanguage.localized("場所の表示")
        )
    }
}

private struct GlassSegmentOption<Value: Hashable>: Identifiable {
    let title: String
    let value: Value

    var id: Value { value }
}

private struct GlassSegmentedPicker<Value: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Value
    let options: [GlassSegmentOption<Value>]
    let accessibilityLabel: String

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let horizontalPadding: CGFloat = 4
            let contentWidth = max(0, geometry.size.width - horizontalPadding * 2)
            let segmentWidth = max(
                0,
                (contentWidth - spacing * CGFloat(max(0, options.count - 1)))
                    / CGFloat(max(1, options.count))
            )

            ZStack(alignment: .leading) {
                selectedSurface
                    .frame(width: segmentWidth, height: 40)
                    .offset(
                        x: horizontalPadding
                            + CGFloat(selectedIndex) * (segmentWidth + spacing)
                    )

                HStack(spacing: spacing) {
                    ForEach(options) { option in
                        Button {
                            guard selection != option.value else {
                                return
                            }
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.30)) {
                                selection = option.value
                            }
                        } label: {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    selection == option.value ? Color.accentColor : Color.secondary
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                    }
                }
                .padding(horizontalPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .modifier(GlassSegmentedPickerSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var selectedIndex: Int {
        options.firstIndex(where: { $0.value == selection }) ?? 0
    }

    @ViewBuilder
    private var selectedSurface: some View {
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.14)).interactive(),
                    in: Capsule()
                )
        } else {
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.30), lineWidth: 0.8)
                }
        }
    }
}

private struct GlassSegmentedPickerSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.primary.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
        }
    }
}

private struct PlaceRow: View {
    let place: NumberedPlace
    let stays: [StayEntity]

    private var address: String? {
        PlaceAddressResolver.address(for: place.alias, stays: stays)
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: place.alias.symbolName)
                .font(.system(size: 29, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(place.alias.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let address {
                    Text(address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

private struct PlaceMapMarker: View {
    let place: NumberedPlace
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlaceMapMarkerContent(
                symbolName: place.alias.symbolName,
                name: place.alias.name,
                isInteractive: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.alias.name)
        .accessibilityHint(AppLanguage.localized("タップして場所を編集"))
    }
}

private struct PlaceMapMarkerContent: View {
    private static let itemSpacing: CGFloat = 4
    private static let iconDiameter: CGFloat = 58
    private static let coordinateDotDiameter: CGFloat = 10
    private static let coordinateCenteredHeight = 2 * (
        iconDiameter + itemSpacing + coordinateDotDiameter / 2
    )

    let symbolName: String
    let name: String
    var isInteractive = false

    var body: some View {
        VStack(spacing: Self.itemSpacing) {
            markerIcon

            Circle()
                .fill(Color.accentColor)
                .frame(
                    width: Self.coordinateDotDiameter,
                    height: Self.coordinateDotDiameter
                )
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 1.5)
                }

            placeNameLabel
        }
        // Annotation(anchor: .center) aligns the center of this view with the
        // map coordinate. Keep the coordinate dot at that exact center rather
        // than centering the combined icon/dot/label stack.
        .frame(height: Self.coordinateCenteredHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Image(systemName: symbolName)
            .font(.system(size: 26, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.accentColor)
            .frame(width: Self.iconDiameter, height: Self.iconDiameter)
    }

    @ViewBuilder
    private var markerIcon: some View {
        if #available(iOS 26.0, *) {
            if isInteractive {
                icon
                    .glassEffect(.regular.interactive(), in: Circle())
            } else {
                icon
                    .glassEffect(.regular, in: Circle())
            }
        } else {
            icon
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.62), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        }
    }

    private var nameContent: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minWidth: 72, maxWidth: 174)
    }

    @ViewBuilder
    private var placeNameLabel: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        if #available(iOS 26.0, *) {
            if isInteractive {
                nameContent
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                nameContent
                    .glassEffect(.regular, in: shape)
            }
        } else {
            nameContent
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(.white.opacity(0.46), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.13), radius: 6, y: 3)
        }
    }
}

private struct PlaceCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let stays: [StayEntity]
    let aliases: [PlaceAliasEntity]
    let onAdded: (UUID) -> Void
    @State private var selectedCandidateID: UUID?

    private var candidates: [StayEntity] {
        var result: [StayEntity] = []
        for stay in stays {
            guard stay.latitude.isFinite, stay.longitude.isFinite,
                  (-90...90).contains(stay.latitude),
                  (-180...180).contains(stay.longitude),
                  hasMatchingAlias(for: stay) == false,
                  hasNearbyCandidate(for: stay, in: result) == false else {
                continue
            }
            result.append(stay)
            if result.count == 40 {
                break
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        AppLanguage.localized("追加できる滞在がありません"),
                        systemImage: "mappin.slash",
                        description: Text(AppLanguage.localized("新しい場所に滞在すると、ここから登録できます。"))
                    )
                } else {
                    List(candidates) { stay in
                        Button {
                            selectedCandidateID = stay.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocationFormatter.placeName(for: stay) ?? LocationFormatter.address(for: stay) ?? AppLanguage.localized("名称未取得"))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                if let address = LocationFormatter.address(for: stay),
                                   address != LocationFormatter.placeName(for: stay) {
                                    Text(address)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(AppLanguage.localized("滞在から場所を追加"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("閉じる")) {
                        dismiss()
                    }
                }
            }
            .navigationDestination(item: $selectedCandidateID) { stayID in
                if let stay = candidates.first(where: { $0.id == stayID }) {
                    PlaceRegistrationView(stay: stay) { name, symbolName, radiusMeters, priority in
                        addPlace(
                            from: stay,
                            name: name,
                            symbolName: symbolName,
                            radiusMeters: radiusMeters,
                            priority: priority
                        )
                    }
                } else {
                    ContentUnavailableView(AppLanguage.localized("滞在が見つかりません"), systemImage: "mappin.slash")
                }
            }
        }
    }

    private func addPlace(
        from stay: StayEntity,
        name: String,
        symbolName: String,
        radiusMeters: Double,
        priority: Int
    ) {
        let alias = PlaceAliasStore.upsert(
            name: name,
            latitude: stay.latitude,
            longitude: stay.longitude,
            radiusMeters: radiusMeters,
            priority: priority,
            sourcePlaceName: LocationFormatter.placeName(for: stay),
            address: LocationFormatter.address(for: stay),
            aliases: aliases,
            modelContext: modelContext
        )
        alias.symbolName = symbolName
        alias.updatedAt = Date()
        try? modelContext.save()
        dismiss()
        onAdded(alias.id)
    }

    private func hasMatchingAlias(for stay: StayEntity) -> Bool {
        aliases.contains { alias in
            PlaceCandidatePolicy.matchesRegisteredPlace(
                coordinate: stay.coordinate,
                registeredCoordinate: alias.coordinate,
                radiusMeters: alias.radiusMeters
            )
        }
    }

    private func hasNearbyCandidate(for stay: StayEntity, in candidates: [StayEntity]) -> Bool {
        candidates.contains { candidate in
            PlaceCandidatePolicy.representsSameCandidate(
                candidate.coordinate,
                stay.coordinate
            )
        }
    }
}

struct MapPlaceRegistrationRequest: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct MapPlaceRegistrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let coordinate: CLLocationCoordinate2D
    let aliases: [PlaceAliasEntity]
    let isGuidedSetup: Bool
    @State private var saveError: String?
    let onSaved: (UUID) -> Void
    @State private var name = ""
    @State private var symbolName = "mappin"
    @State private var radiusMeters: Double = 100
    @State private var priority = 10
    @State private var address = AppLanguage.localized("住所を取得中")
    @State private var resolvedAddress: String?
    @State private var sourcePlaceName: String?
    @State private var namePlaceholder = AppLanguage.localized("場所名を入力")

    init(
        coordinate: CLLocationCoordinate2D,
        aliases: [PlaceAliasEntity],
        isGuidedSetup: Bool = false,
        onSaved: @escaping (UUID) -> Void = { _ in }
    ) {
        self.coordinate = coordinate
        self.aliases = aliases
        self.onSaved = onSaved
        self.isGuidedSetup = isGuidedSetup
    }

    var body: some View {
        NavigationStack {
            PlaceFormScreen(
                title: "場所を追加",
                coordinate: coordinate,
                address: address,
                sourcePlaceName: sourcePlaceName,
                namePlaceholder: namePlaceholder,
                name: $name,
                symbolName: $symbolName,
                radiusMeters: $radiusMeters,
                priority: $priority,
                primaryActionTitle: "この場所を登録",
                onSave: save,
                isGuidedSetup: isGuidedSetup
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized(isGuidedSetup ? "戻る" : "閉じる")) {
                        dismiss()
                    }
                    .accessibilityLabel(AppLanguage.localized(isGuidedSetup ? "場所を選び直す" : "閉じる"))
                }
            }
        }
        .alert(AppLanguage.localized("場所を保存できませんでした"), isPresented: Binding(
            get: { saveError != nil },
            set: { if $0 == false { saveError = nil } }
        )) {
            Button(AppLanguage.localized("OK"), role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .task {
            await resolvePlaceDetails()
        }
    }

    private func save() {
        guard let trimmedName = name.trimmedNonEmpty else {
            return
        }

        let alias = PlaceAliasStore.upsert(
            name: trimmedName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters,
            priority: priority,
            sourcePlaceName: sourcePlaceName,
            address: resolvedAddress,
            aliases: aliases,
            modelContext: modelContext
        )
        alias.symbolName = symbolName
        alias.updatedAt = Date()
        do {
            try modelContext.save()
            onSaved(alias.id)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    @MainActor
    private func resolvePlaceDetails() async {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ),
                preferredLocale: AppLanguage.currentLocale
            )
            guard Task.isCancelled == false,
                  let placemark = placemarks.first else {
                return
            }

            let details = PlacemarkDetailsResolver.details(for: placemark)
            resolvedAddress = details.address
            address = details.address ?? AppLanguage.localized("住所未取得")
            sourcePlaceName = details.placeName
        } catch {
            guard Task.isCancelled == false else {
                return
            }
            address = AppLanguage.localized("住所未取得")
        }
    }
}

struct PlaceRegistrationView: View {
    let stay: StayEntity
    let onSave: (String, String, Double, Int) -> Void
    @State private var name: String
    @State private var symbolName: String
    @State private var radiusMeters: Double
    @State private var priority = 10

    init(
        stay: StayEntity,
        onSave: @escaping (String, String, Double, Int) -> Void
    ) {
        self.stay = stay
        self.onSave = onSave
        let suggestedName = LocationFormatter.placeName(for: stay)
            ?? LocationFormatter.address(for: stay)
            ?? AppLanguage.localized("場所名を入力")
        let initialRadius = max(50, min(200, stay.horizontalAccuracy * 2))
        _name = State(initialValue: "")
        _symbolName = State(initialValue: Self.suggestedSymbol(for: suggestedName))
        _radiusMeters = State(initialValue: (initialRadius / 10).rounded() * 10)
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: stay.latitude, longitude: stay.longitude)
    }

    private var address: String {
        LocationFormatter.address(for: stay) ?? AppLanguage.localized("住所未取得")
    }

    private var sourcePlaceName: String? {
        let placeName = LocationFormatter.placeName(for: stay)
        return placeName == address ? nil : placeName
    }

    private var namePlaceholder: String {
        AppLanguage.localized("場所名を入力")
    }

    var body: some View {
        PlaceFormScreen(
            title: "場所を追加",
            coordinate: coordinate,
            address: address,
            sourcePlaceName: sourcePlaceName,
            namePlaceholder: namePlaceholder,
            name: $name,
            symbolName: $symbolName,
            radiusMeters: $radiusMeters,
            priority: $priority,
            primaryActionTitle: "この場所を登録",
            onSave: {
                guard let trimmedName = name.trimmedNonEmpty else {
                    return
                }
                onSave(trimmedName, symbolName, radiusMeters, priority)
            }
        )
    }

    private static func suggestedSymbol(for name: String) -> String {
        let normalized = name.localizedLowercase
        if normalized.contains("大学") || normalized.contains("学校") {
            return "graduationcap"
        }
        if normalized.contains("カフェ") || normalized.contains("珈琲") || normalized.contains("coffee") {
            return "cup.and.saucer"
        }
        if normalized.contains("ジム") || normalized.contains("gym") {
            return "dumbbell"
        }
        if normalized.contains("駅") {
            return "tram"
        }
        if normalized.contains("ホテル") || normalized.contains("hotel") {
            return "bed.double"
        }
        if normalized.contains("自宅") || normalized.contains("家") {
            return "house"
        }
        return "mappin"
    }
}

private struct PlaceFormScreen: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let coordinate: CLLocationCoordinate2D
    let address: String
    let sourcePlaceName: String?
    let namePlaceholder: String
    @Binding var name: String
    @Binding var symbolName: String
    @Binding var radiusMeters: Double
    @Binding var priority: Int
    let primaryActionTitle: String?
    let onSave: () -> Void
    var isGuidedSetup = false
    var destructiveActionTitle: String?
    var destructiveAction: (() -> Void)?
    @State private var showingIconPicker = false
    @FocusState private var isNameFocused: Bool

    private var canSave: Bool {
        name.trimmedNonEmpty != nil
    }

    private var selectedIconLabel: String {
        guard let label = PlaceIconOption.all.first(where: { $0.symbolName == symbolName })?.label else {
            return AppLanguage.localized("その他")
        }
        return AppLanguage.localized(label)
    }

    private var mapPosition: MapCameraPosition {
        let latitudeDelta = max(0.004, radiusMeters * 3.4 / 111_000)
        let longitudeScale = max(0.2, cos(coordinate.latitude * .pi / 180))
        let longitudeDelta = max(0.004, latitudeDelta / longitudeScale)
        return .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: latitudeDelta,
                    longitudeDelta: longitudeDelta
                )
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isGuidedSetup {
                    Button {
                        isNameFocused = false
                        dismiss()
                    } label: {
                        Label(AppLanguage.localized("場所を選び直す"), systemImage: "chevron.left")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isGuidedSetup {
                    nameField
                    iconField
                    locationCard
                } else {
                    locationCard
                    nameField
                    iconField
                }
                recognitionSettings
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            isNameFocused = false
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppLanguage.localized(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isGuidedSetup ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if let destructiveActionTitle, let destructiveAction {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized(destructiveActionTitle), role: .destructive, action: destructiveAction)
                        .foregroundStyle(.red)
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(AppLanguage.localized("保存"), action: onSave)
                    .foregroundStyle(Color.accentColor)
                    .disabled(canSave == false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isGuidedSetup {
                guidedNameSetupCard
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let primaryActionTitle {
                Button(action: onSave) {
                    Text(AppLanguage.localized(primaryActionTitle))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(canSave == false)
                .accessibilityIdentifier("placeForm.save")
                .opacity(canSave ? 1 : 0.45)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showingIconPicker) {
            PlaceIconSelectionSheet(selection: $symbolName)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }

    private var guidedNameSetupCard: some View {
        GuidedSetupCard(
            step: 1,
            title: "場所に名前をつけましょう",
            message: "「自宅」「職場」など、わかりやすい名前を入力し、保存してください。"
        )
        .onTapGesture {
            isNameFocused = false
        }
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(position: .constant(mapPosition), interactionModes: []) {
                MapCircle(center: coordinate, radius: max(1, radiusMeters))
                    .foregroundStyle(Color.accentColor.opacity(0.10))
                    .stroke(Color.accentColor.opacity(0.62), lineWidth: 1.1)

                Annotation("", coordinate: coordinate) {
                    PlaceMapMarkerContent(
                        symbolName: symbolName,
                        name: name.trimmedNonEmpty ?? AppLanguage.localized(namePlaceholder)
                    )
                    .accessibilityHidden(true)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 178)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 4) {
                if let sourcePlaceName, sourcePlaceName != address {
                    Text(sourcePlaceName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Text(address)
                    .font(.caption2.weight(.light))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.8)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLanguage.localized("場所名"))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(AppLanguage.localized(namePlaceholder), text: $name)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("placeForm.name")
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit {
                    isNameFocused = false
                }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.8)
        }
    }

    private var iconField: some View {
        Button {
            isNameFocused = false
            showingIconPicker = true
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLanguage.localized("アイコン"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(selectedIconLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: symbolName)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 82)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.12), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(AppLanguage.localized("アイコン")), \(selectedIconLabel)")
        .accessibilityHint(AppLanguage.localized("タップして変更"))
    }

    private var recognitionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLanguage.localized("登録半径"))
                        .font(.headline)
                    Text(AppLanguage.localized("この範囲に入ると同じ場所として扱います"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("\(Int(radiusMeters.rounded())) m")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }

            Slider(
                value: $radiusMeters,
                in: 25...max(1_000, ceil(radiusMeters / 500) * 500),
                step: 25
            )
            .accessibilityLabel(AppLanguage.localized("登録半径"))
            .accessibilityValue(
                AppLanguage.current == .english
                    ? "\(Int(radiusMeters.rounded())) meters"
                    : "\(Int(radiusMeters.rounded()))メートル"
            )

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text(AppLanguage.localized("優先度"))
                    .font(.headline)
                Text(AppLanguage.localized("登録範囲が重なったとき、優先度が高い場所を採用します"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PlacePriorityPicker(selection: priorityLevel)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.8)
        }
    }

    private var priorityLevel: Binding<Int> {
        Binding(
            get: {
                if priority <= 0 {
                    return 0
                }
                if priority >= 55 {
                    return 100
                }
                return 10
            },
            set: { priority = $0 }
        )
    }
}

private struct PlaceIconCircle: View {
    let option: PlaceIconOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLanguage.localized(option.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var icon: some View {
        Image(systemName: option.symbolName)
            .font(.system(size: 25, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
            .frame(width: 68, height: 68)
            .contentShape(Circle())
            .modifier(SelectedIconSurface(isSelected: isSelected))
    }
}

private struct SelectedIconSurface: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        .regular
                            .tint(Color.accentColor.opacity(0.14))
                            .interactive(),
                        in: Circle()
                    )
            } else {
                content
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.72), lineWidth: 1.5)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
            }
        } else {
            content
        }
    }
}

private struct PlaceIconSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var draftSelection: String
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    init(selection: Binding<String>) {
        _selection = selection
        _draftSelection = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text(AppLanguage.localized("アイコンを選択"))
                        .font(.largeTitle.weight(.bold))

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .modifier(CloseButtonSurface())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguage.localized("閉じる"))
                }

                Text(AppLanguage.localized("場所を見分けやすいアイコンを選んでください"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 22)

                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(PlaceIconOption.registration) { option in
                        let isSelected = option.symbolName == draftSelection

                        VStack(spacing: 9) {
                            PlaceIconCircle(
                                option: option,
                                isSelected: isSelected
                            ) {
                                draftSelection = option.symbolName
                            }
                            .frame(minWidth: 68, minHeight: 68)

                            Text(AppLanguage.localized(option.label))
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 92)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                selection = draftSelection
                dismiss()
            } label: {
                Text(AppLanguage.localized("決定"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

private struct CloseButtonSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.primary.opacity(0.10), lineWidth: 0.8)
                }
        }
    }
}

private struct PlacePriorityPicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker(AppLanguage.localized("優先度"), selection: $selection) {
            Text(AppLanguage.localized("低")).tag(0)
            Text(AppLanguage.localized("標準")).tag(10)
            Text(AppLanguage.localized("高")).tag(100)
        }
        .pickerStyle(.segmented)
        .frame(height: 36)
        .accessibilityHint(AppLanguage.localized("登録範囲が重なったときに採用する場所の優先度を選択します"))
    }
}

private enum PlaceAddressResolver {
    static func address(for alias: PlaceAliasEntity, stays: [StayEntity]) -> String? {
        alias.address?.trimmedNonEmpty
            ?? nearestStay(for: alias, stays: stays).flatMap(LocationFormatter.address)
    }

    static func placeName(for alias: PlaceAliasEntity, stays: [StayEntity]) -> String? {
        alias.sourcePlaceName?.trimmedNonEmpty
            ?? nearestStay(for: alias, stays: stays).flatMap(LocationFormatter.placeName)
    }

    private static func nearestStay(
        for alias: PlaceAliasEntity,
        stays: [StayEntity]
    ) -> StayEntity? {
        stays
            .lazy
            .compactMap { stay -> (stay: StayEntity, distance: Double)? in
                let distance = GeoDistance.meters(from: alias.coordinate, to: stay.coordinate)
                guard distance <= alias.radiusMeters else {
                    return nil
                }
                return (stay, distance)
            }
            .min { $0.distance < $1.distance }?
            .stay
    }
}

struct PlaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let alias: PlaceAliasEntity
    @Query(sort: \StayEntity.arrivalAt, order: .reverse) private var stays: [StayEntity]
    @State private var showingDeleteConfirmation = false
    @State private var name: String
    @State private var symbolName: String
    @State private var radiusMeters: Double
    @State private var priority: Int

    init(alias: PlaceAliasEntity) {
        self.alias = alias
        _stays = Query(sort: \StayEntity.arrivalAt, order: .reverse)
        _name = State(initialValue: alias.name)
        _symbolName = State(initialValue: alias.symbolName)
        _radiusMeters = State(initialValue: alias.radiusMeters)
        _priority = State(initialValue: alias.priority)
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: alias.latitude, longitude: alias.longitude)
    }

    private var addressText: String? {
        PlaceAddressResolver.address(for: alias, stays: stays)
    }

    private var sourcePlaceName: String? {
        PlaceAddressResolver.placeName(for: alias, stays: stays)
    }

    var body: some View {
        PlaceFormScreen(
            title: "場所を編集",
            coordinate: coordinate,
            address: addressText ?? AppLanguage.localized("住所未取得"),
            sourcePlaceName: sourcePlaceName,
            namePlaceholder: "場所名",
            name: $name,
            symbolName: $symbolName,
            radiusMeters: $radiusMeters,
            priority: $priority,
            primaryActionTitle: nil,
            onSave: save,
            destructiveActionTitle: "解除",
            destructiveAction: {
                showingDeleteConfirmation = true
            }
        )
        .confirmationDialog(AppLanguage.localized("この場所登録を解除しますか？"), isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button(AppLanguage.localized("解除"), role: .destructive) {
                modelContext.delete(alias)
                try? modelContext.save()
                dismiss()
            }
            Button(AppLanguage.localized("キャンセル"), role: .cancel) {}
        } message: {
            Text(AppLanguage.localized("位置ログは削除されません。登録場所の名前と半径設定だけが解除されます。"))
        }
    }

    private func save() {
        guard let trimmedName = name.trimmedNonEmpty else {
            return
        }
        alias.name = trimmedName
        alias.symbolName = symbolName
        alias.radiusMeters = radiusMeters
        alias.priority = priority
        alias.updatedAt = Date()
        try? modelContext.save()
        dismiss()
    }
}

private struct PlaceIconOption: Identifiable {
    let symbolName: String
    let label: String

    var id: String { symbolName }

    static let registration: [PlaceIconOption] = [
        PlaceIconOption(symbolName: "house", label: "自宅"),
        PlaceIconOption(symbolName: "building.2", label: "職場"),
        PlaceIconOption(symbolName: "graduationcap", label: "学校・大学"),
        PlaceIconOption(symbolName: "cross.case", label: "病院"),

        PlaceIconOption(symbolName: "cup.and.saucer", label: "カフェ"),
        PlaceIconOption(symbolName: "fork.knife", label: "食事"),
        PlaceIconOption(symbolName: "wineglass", label: "バー・居酒屋"),
        PlaceIconOption(symbolName: "cart", label: "スーパー"),

        PlaceIconOption(symbolName: "dumbbell", label: "ジム"),
        PlaceIconOption(symbolName: "water.waves", label: "サウナ・温泉"),
        PlaceIconOption(symbolName: "scissors", label: "美容室"),
        PlaceIconOption(symbolName: "tree", label: "公園"),

        PlaceIconOption(symbolName: "books.vertical", label: "図書館"),
        PlaceIconOption(symbolName: "film", label: "映画館"),
        PlaceIconOption(symbolName: "tram", label: "駅"),
        PlaceIconOption(symbolName: "airplane", label: "空港"),

        PlaceIconOption(symbolName: "bed.double", label: "ホテル"),
        PlaceIconOption(symbolName: "bag", label: "買い物"),
        PlaceIconOption(symbolName: "heart", label: "お気に入り"),
        PlaceIconOption(symbolName: "mappin", label: "その他")
    ]

    static let all: [PlaceIconOption] = registration + [
        PlaceIconOption(symbolName: "building.columns", label: "施設"),
        PlaceIconOption(symbolName: "briefcase", label: "仕事"),
        PlaceIconOption(symbolName: "figure.walk", label: "散歩"),
        PlaceIconOption(symbolName: "car", label: "車"),
        PlaceIconOption(symbolName: "leaf", label: "自然"),
        PlaceIconOption(symbolName: "person.2", label: "家族")
    ]

}
