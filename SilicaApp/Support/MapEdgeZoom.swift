import MapKit
import SwiftUI

enum MapEdgeZoom {
    static let gestureWidth: CGFloat = 52

    private static let activationDistance: CGFloat = 2
    private static let curveDistance: CGFloat = 48
    private static let curveExponent = 1.35
    private static let minimumSpanDelta: CLLocationDegrees = 0.0001
    private static let maximumSpanDelta: CLLocationDegrees = 60

    static func region(
        startingAt startRegion: MKCoordinateRegion,
        translationHeight: CGFloat
    ) -> MKCoordinateRegion? {
        guard abs(translationHeight) >= activationDistance else {
            return nil
        }

        let signedDistance = Double(translationHeight / curveDistance)
        let curvedDistance = signedDistance.sign == .minus
            ? -pow(abs(signedDistance), curveExponent)
            : pow(signedDistance, curveExponent)
        let scale = pow(2.0, curvedDistance)

        return MKCoordinateRegion(
            center: startRegion.center,
            span: MKCoordinateSpan(
                latitudeDelta: clamped(startRegion.span.latitudeDelta * scale),
                longitudeDelta: clamped(startRegion.span.longitudeDelta * scale)
            )
        )
    }

    private static func clamped(_ delta: CLLocationDegrees) -> CLLocationDegrees {
        min(maximumSpanDelta, max(minimumSpanDelta, delta))
    }
}
