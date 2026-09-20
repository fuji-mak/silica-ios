import CoreLocation
import MapKit
import SwiftData
import SwiftUI
#if canImport(SilicaCore)
import SilicaCore
#endif

struct StayDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var locationRecorder: LocationRecorder
    @Bindable var stay: StayEntity
    let aliases: [PlaceAliasEntity]
    let displayDate: Date
    let onRegisterPlace: (UUID) -> Void
    let onRegisterNewPlace: (UUID) -> Void
    let onDelete: () -> Void
    @State private var showingDeleteConfirmation = false
    @State private var isPaywallPresented = false
    @State private var isLocationEditorPresented = false

    var body: some View {
        let details = StayResolution.details(for: stay, aliases: aliases)

        NavigationStack {
            Form {
                Section(AppLanguage.localized("滞在")) {
                    Text(DateSupport.formatTimeRange(start: stay.arrivalAt, end: stay.departureAt, displayDate: displayDate))
                    if stay.isLocationManuallyAdjusted {
                        LabeledContent(
                            AppLanguage.localized("位置"),
                            value: AppLanguage.localized("手動で修正済み")
                        )
                    } else {
                        LabeledContent(AppLanguage.localized("位置精度"), value: "\(Int(stay.horizontalAccuracy))m")
                    }
                    LabeledContent(AppLanguage.localized("信頼度"), value: AppLanguage.localized(stay.confidenceRawValue))
                    Text(details.address ?? AppLanguage.localized("住所未取得"))
                        .textSelection(.enabled)

                    Button(AppLanguage.localized("位置を修正"), systemImage: "mappin.and.ellipse") {
                        isLocationEditorPresented = true
                    }
                    .accessibilityIdentifier("stay-location-edit-button")
                }

                if let matchingAlias = details.matchingAlias {
                    Section(AppLanguage.localized("登録場所")) {
                        Text(matchingAlias.name)
                        Button(AppLanguage.localized("場所を編集")) {
                            dismiss()
                            onRegisterPlace(matchingAlias.id)
                        }
                    }
                }

                if details.matchingAlias == nil {
                    Section {
                        Button(AppLanguage.localized("この場所を地点として登録")) {
                            guard isPlaceCreationAccessLoading == false else {
                                return
                            }
                            guard requiresProForNewPlace == false else {
                                isPaywallPresented = true
                                return
                            }
                            dismiss()
                            onRegisterNewPlace(stay.id)
                        }
                        .disabled(isPlaceCreationAccessLoading)
                    }
                }

                Section {
                    Button(AppLanguage.localized("記録を削除"), role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle(details.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(AppLanguage.localized("この記録を削除しますか？"), isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button(AppLanguage.localized("削除"), role: .destructive) {
                    deleteStay()
                }
                Button(AppLanguage.localized("キャンセル"), role: .cancel) {}
            } message: {
                Text(AppLanguage.localized("この操作は取り消せません。"))
            }
        }
        .sheet(isPresented: $isPaywallPresented) {
            SilicaCustomPaywallView()
        }
        .fullScreenCover(isPresented: $isLocationEditorPresented) {
            StayLocationEditorView(stay: stay) { coordinate in
                try locationRecorder.updateStayLocation(stay, to: coordinate)
            }
        }
    }

    private var visiblePlaceCount: Int {
        PlaceAliasStore.visibleAliases(from: aliases).count
    }

    private var requiresProForNewPlace: Bool {
        subscriptionManager.requiresProForNewPlace(existingPlaceCount: visiblePlaceCount)
    }

    private var isPlaceCreationAccessLoading: Bool {
        subscriptionManager.isPlaceCreationAccessLoading(existingPlaceCount: visiblePlaceCount)
    }

    private func deleteStay() {
        modelContext.delete(stay)
        try? modelContext.save()
        onDelete()
        NotificationCenter.default.post(
            name: .silicaLocationDataDidChange,
            object: nil
        )
        dismiss()
    }
}

private struct StayLocationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stay: StayEntity
    let onSave: (CLLocationCoordinate2D) throws -> Void
    @State private var coordinate: CLLocationCoordinate2D
    @State private var saveError: String?

    init(
        stay: StayEntity,
        onSave: @escaping (CLLocationCoordinate2D) throws -> Void
    ) {
        self.stay = stay
        self.onSave = onSave
        _coordinate = State(
            initialValue: CLLocationCoordinate2D(
                latitude: stay.latitude,
                longitude: stay.longitude
            )
        )
    }

    private var hasChangedLocation: Bool {
        let original = CLLocation(latitude: stay.latitude, longitude: stay.longitude)
        let edited = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return edited.distance(from: original) >= 0.5
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                DraggableStayLocationMap(
                    coordinate: $coordinate,
                    reduceMotion: reduceMotion
                )
                .ignoresSafeArea()
                .accessibilityIdentifier("stay-location-editor-map")

                Label(
                    AppLanguage.localized("ピンをドラッグして、正しい滞在位置に移動してください。"),
                    systemImage: "hand.draw"
                )
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.primary.opacity(0.10), lineWidth: 0.8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationTitle(AppLanguage.localized("滞在位置を修正"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("キャンセル")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLanguage.localized("保存")) {
                        save()
                    }
                    .disabled(hasChangedLocation == false)
                    .accessibilityIdentifier("stay-location-editor-save")
                }
            }
        }
        .alert(
            AppLanguage.localized("位置を保存できませんでした"),
            isPresented: Binding(
                get: { saveError != nil },
                set: { if $0 == false { saveError = nil } }
            )
        ) {
            Button(AppLanguage.localized("OK"), role: .cancel) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        guard hasChangedLocation else {
            return
        }
        do {
            try onSave(coordinate)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct DraggableStayLocationMap: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(coordinate: $coordinate, reduceMotion: reduceMotion)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .includingAll
        mapView.addAnnotation(context.coordinator.annotation)
        mapView.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 700,
                longitudinalMeters: 700
            ),
            animated: false
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.coordinate = $coordinate
        context.coordinator.reduceMotion = reduceMotion
        guard context.coordinator.isDragging == false,
              coordinatesMatch(context.coordinator.annotation.coordinate, coordinate) == false else {
            return
        }
        context.coordinator.annotation.coordinate = coordinate
    }

    private func coordinatesMatch(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000_000_1 &&
            abs(lhs.longitude - rhs.longitude) < 0.000_000_1
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let annotation: MKPointAnnotation
        var coordinate: Binding<CLLocationCoordinate2D>
        var reduceMotion = false
        var isDragging = false

        init(coordinate: Binding<CLLocationCoordinate2D>, reduceMotion: Bool) {
            self.coordinate = coordinate
            self.reduceMotion = reduceMotion
            annotation = MKPointAnnotation()
            annotation.coordinate = coordinate.wrappedValue
            annotation.title = AppLanguage.localized("滞在位置")
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: MKAnnotation
        ) -> MKAnnotationView? {
            guard annotation === self.annotation else {
                return nil
            }

            let reuseIdentifier = DraggableStayLocationAnnotationView.reuseIdentifier
            let view = (mapView.dequeueReusableAnnotationView(
                withIdentifier: reuseIdentifier
            ) as? DraggableStayLocationAnnotationView) ?? DraggableStayLocationAnnotationView(
                annotation: annotation,
                reuseIdentifier: reuseIdentifier
            )
            view.annotation = annotation
            view.canShowCallout = false
            view.isDraggable = false
            view.displayPriority = .required
            view.isUserInteractionEnabled = true
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "stay-location-editor-pin"
            view.accessibilityLabel = AppLanguage.localized("滞在位置")
            view.accessibilityHint = AppLanguage.localized("ドラッグして位置を修正")
            view.accessibilityTraits = [.button, .allowsDirectInteraction]
            view.configure(
                mapView: mapView,
                reduceMotion: reduceMotion,
                onDragBegan: { [weak self] in
                    self?.isDragging = true
                },
                onDragEnded: { [weak self] newCoordinate in
                    guard let self else { return }
                    self.isDragging = false
                    self.annotation.coordinate = newCoordinate
                    self.coordinate.wrappedValue = newCoordinate
                },
                onDragCancelled: { [weak self] originalCoordinate in
                    guard let self else { return }
                    self.isDragging = false
                    self.annotation.coordinate = originalCoordinate
                }
            )
            return view
        }
    }
}

private final class DraggableStayLocationAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "DraggableStayLocationAnnotationView"

    private let markerSurface = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemMaterial)
    )
    private let markerIcon = UIImageView(
        image: UIImage(systemName: "mappin")
    )
    private let coordinateDot = UIView()
    private weak var mapView: MKMapView?
    private var reduceMotion = false
    private var dragStartCoordinate: CLLocationCoordinate2D?
    private var onDragBegan: (() -> Void)?
    private var onDragEnded: ((CLLocationCoordinate2D) -> Void)?
    private var onDragCancelled: ((CLLocationCoordinate2D) -> Void)?
    private lazy var dragGestureRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleDrag(_:))
        )
        recognizer.minimumPressDuration = 0.15
        recognizer.allowableMovement = 18
        return recognizer
    }()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        let markerDiameter: CGFloat = 52
        let dotDiameter: CGFloat = 10
        let itemSpacing: CGFloat = 6
        let totalHeight = markerDiameter + itemSpacing + dotDiameter

        bounds = CGRect(x: 0, y: 0, width: 64, height: totalHeight)
        centerOffset = CGPoint(x: 0, y: bounds.midY - (totalHeight - dotDiameter / 2))
        collisionMode = .circle

        markerSurface.frame = CGRect(
            x: (bounds.width - markerDiameter) / 2,
            y: 0,
            width: markerDiameter,
            height: markerDiameter
        )
        markerSurface.layer.cornerRadius = markerDiameter / 2
        markerSurface.layer.cornerCurve = .continuous
        markerSurface.layer.masksToBounds = true
        markerSurface.layer.borderWidth = 0.8
        markerSurface.layer.borderColor = UIColor.white.withAlphaComponent(0.68).cgColor
        addSubview(markerSurface)

        markerIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 24,
            weight: .medium
        )
        markerIcon.tintColor = .systemBlue
        markerIcon.contentMode = .center
        markerIcon.frame = markerSurface.bounds
        markerSurface.contentView.addSubview(markerIcon)

        coordinateDot.frame = CGRect(
            x: (bounds.width - dotDiameter) / 2,
            y: markerDiameter + itemSpacing,
            width: dotDiameter,
            height: dotDiameter
        )
        coordinateDot.backgroundColor = .systemBlue
        coordinateDot.layer.cornerRadius = dotDiameter / 2
        coordinateDot.layer.borderWidth = 1.5
        coordinateDot.layer.borderColor = UIColor.white.cgColor
        addSubview(coordinateDot)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)

        addGestureRecognizer(dragGestureRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        mapView: MKMapView,
        reduceMotion: Bool,
        onDragBegan: @escaping () -> Void,
        onDragEnded: @escaping (CLLocationCoordinate2D) -> Void,
        onDragCancelled: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        self.mapView = mapView
        self.reduceMotion = reduceMotion
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
        self.onDragCancelled = onDragCancelled
    }

    @objc private func handleDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard let mapView,
              let pointAnnotation = annotation as? MKPointAnnotation else {
            return
        }

        switch recognizer.state {
        case .began:
            dragStartCoordinate = pointAnnotation.coordinate
            mapView.isScrollEnabled = false
            setDragging(true, animated: reduceMotion == false)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDragBegan?()
        case .changed:
            pointAnnotation.coordinate = mapView.convert(
                recognizer.location(in: mapView),
                toCoordinateFrom: mapView
            )
        case .ended:
            let newCoordinate = mapView.convert(
                recognizer.location(in: mapView),
                toCoordinateFrom: mapView
            )
            pointAnnotation.coordinate = newCoordinate
            dragStartCoordinate = nil
            mapView.isScrollEnabled = true
            setDragging(false, animated: reduceMotion == false)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            onDragEnded?(newCoordinate)
        case .cancelled, .failed:
            guard let dragStartCoordinate else { return }
            self.dragStartCoordinate = nil
            mapView.isScrollEnabled = true
            setDragging(false, animated: reduceMotion == false)
            onDragCancelled?(dragStartCoordinate)
        default:
            break
        }
    }

    func setDragging(_ isDragging: Bool, animated: Bool) {
        let changes = {
            let transform = isDragging
                ? CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 1.06, y: 1.06)
                : .identity
            self.markerSurface.transform = transform
            self.coordinateDot.transform = transform
            self.layer.shadowOpacity = isDragging ? 0.28 : 0.18
        }

        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.25,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }
}

struct StayCandidateDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Bindable var candidate: StayCandidateEntity
    let aliases: [PlaceAliasEntity]
    let displayDate: Date
    let onRegisterPlace: (UUID) -> Void
    @State private var isPaywallPresented = false
    @State private var isPlaceRegistrationPresented = false

    var body: some View {
        let details = StayResolution.details(for: candidate, aliases: aliases)

        NavigationStack {
            Form {
                Section(AppLanguage.localized("滞在")) {
                    Text(
                        DateSupport.formatTimeRange(
                            start: candidate.arrivalAt,
                            end: candidate.effectiveDepartureAt,
                            displayDate: displayDate
                        )
                    )
                    LabeledContent(
                        AppLanguage.localized("状態"),
                        value: statusText
                    )
                    .accessibilityIdentifier("stay-candidate-detail-status")
                    LabeledContent(
                        AppLanguage.localized("位置精度"),
                        value: "\(Int(candidate.presentationHorizontalAccuracy))m"
                    )
                    Text(details.address ?? AppLanguage.localized("住所未取得"))
                        .textSelection(.enabled)
                }

                if let matchingAlias = details.matchingAlias {
                    Section(AppLanguage.localized("登録場所")) {
                        Text(matchingAlias.name)
                        Button(AppLanguage.localized("場所を編集")) {
                            dismiss()
                            onRegisterPlace(matchingAlias.id)
                        }
                    }
                } else {
                    Section {
                        Button(AppLanguage.localized("この場所を地点として登録")) {
                            guard isPlaceCreationAccessLoading == false else {
                                return
                            }
                            guard requiresProForNewPlace == false else {
                                isPaywallPresented = true
                                return
                            }
                            isPlaceRegistrationPresented = true
                        }
                        .disabled(isPlaceCreationAccessLoading)
                        .accessibilityIdentifier("candidate-place-registration-button")
                    }
                }
            }
            .navigationTitle(details.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isPlaceRegistrationPresented) {
            MapPlaceRegistrationSheet(
                coordinate: CLLocationCoordinate2D(
                    latitude: candidate.presentationCoordinate.latitude,
                    longitude: candidate.presentationCoordinate.longitude
                ),
                aliases: aliases
            )
        }
        .sheet(isPresented: $isPaywallPresented) {
            SilicaCustomPaywallView()
        }
    }

    private var statusText: String {
        if candidate.isLocationBootstrap, candidate.isTemporallyOpen {
            return AppLanguage.localized(
                Date().timeIntervalSince(candidate.arrivalAt) >= StayValidationPolicy.minimumDuration
                    ? "滞在中、移動後に確定"
                    : "現在地を確認中"
            )
        }
        return AppLanguage.localized(
            candidate.isTemporallyOpen
                ? "滞在中、判定中"
                : "終了時刻を推定、判定中"
        )
    }

    private var visiblePlaceCount: Int {
        PlaceAliasStore.visibleAliases(from: aliases).count
    }

    private var requiresProForNewPlace: Bool {
        subscriptionManager.requiresProForNewPlace(existingPlaceCount: visiblePlaceCount)
    }

    private var isPlaceCreationAccessLoading: Bool {
        subscriptionManager.isPlaceCreationAccessLoading(existingPlaceCount: visiblePlaceCount)
    }
}
