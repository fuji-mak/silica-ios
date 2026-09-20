public enum PlaceConfidence: String, Sendable {
    case high
    case medium
    case low

    public static func from(horizontalAccuracy: Double) -> PlaceConfidence {
        if horizontalAccuracy <= 50 {
            return .high
        }
        if horizontalAccuracy <= 150 {
            return .medium
        }
        return .low
    }

    public static func best(_ lhs: PlaceConfidence, _ rhs: PlaceConfidence) -> PlaceConfidence {
        rank(of: lhs) >= rank(of: rhs) ? lhs : rhs
    }

    private static func rank(of confidence: PlaceConfidence) -> Int {
        switch confidence {
        case .high:
            return 3
        case .medium:
            return 2
        case .low:
            return 1
        }
    }
}
