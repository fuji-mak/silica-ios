import CoreLocation
import Foundation

enum LocationFormatter {
    private static let broadGeographicNames: Set<String> = [
        "日本", "Japan",
        "本州", "Honshu",
        "北海道", "Hokkaido",
        "四国", "Shikoku",
        "九州", "Kyushu",
        "沖縄本島", "Okinawa Island",
        "東北地方", "関東地方", "中部地方", "近畿地方", "中国地方", "四国地方", "九州地方",
    ]

    static func placeName(for stay: StayEntity) -> String? {
        guard let placeName = stay.placeName?.trimmedNonEmpty else {
            return nil
        }
        return isBroadGeographicName(placeName) ? nil : placeName
    }

    static func address(for stay: StayEntity) -> String? {
        stay.address?.trimmedNonEmpty
    }

    static func structuredAddress(
        administrativeArea: String?,
        locality: String?,
        subLocality: String?,
        thoroughfare: String?,
        subThoroughfare: String?,
        subAdministrativeArea: String? = nil
    ) -> String? {
        let rawParts = [
            administrativeArea,
            subAdministrativeArea,
            locality,
            subLocality,
            thoroughfare,
            subThoroughfare,
        ]
        let parts = uniqueNonEmpty(rawParts)
        guard parts.isEmpty == false else {
            return nil
        }

        return removingContainedParts(from: parts).joined()
    }

    static func isBroadGeographicName(_ value: String) -> Bool {
        broadGeographicNames.contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func uniqueNonEmpty(_ values: [String?]) -> [String] {
        values.compactMap { $0?.trimmedNonEmpty }.reduce(into: [String]()) { result, value in
            let normalizedValue = normalizedForComparison(value)
            guard result.contains(where: { normalizedForComparison($0) == normalizedValue }) == false else {
                return
            }
            result.append(value)
        }
    }

    private static func removingContainedParts(from parts: [String]) -> [String] {
        parts.filter { part in
            let normalizedPart = normalizedForComparison(part)
            return parts.contains { other in
                let normalizedOther = normalizedForComparison(other)
                return normalizedOther != normalizedPart &&
                    normalizedOther.count > normalizedPart.count &&
                    normalizedOther.contains(normalizedPart)
            } == false
        }
    }

    static func normalizedForComparison(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "ー", with: "-")
    }

}

enum PlacemarkDetailsResolver {
    struct Details {
        let placeName: String?
        let address: String?
    }

    static func details(for placemark: CLPlacemark) -> Details {
        let addressComponents = [
            placemark.administrativeArea,
            placemark.subAdministrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.subThoroughfare,
        ]
        let address = LocationFormatter.structuredAddress(
            administrativeArea: placemark.administrativeArea,
            locality: placemark.locality,
            subLocality: placemark.subLocality,
            thoroughfare: placemark.thoroughfare,
            subThoroughfare: placemark.subThoroughfare,
            subAdministrativeArea: placemark.subAdministrativeArea
        )
        let candidates = (placemark.areasOfInterest ?? [])
            + [placemark.name].compactMap { $0 }
        let placeName = candidates
            .compactMap(\.trimmedNonEmpty)
            .first {
                isMeaningfulPlaceName(
                    $0,
                    address: address,
                    components: addressComponents
                )
            }

        return Details(placeName: placeName, address: address)
    }

    private static func isMeaningfulPlaceName(
        _ value: String,
        address: String?,
        components: [String?]
    ) -> Bool {
        guard LocationFormatter.isBroadGeographicName(value) == false else {
            return false
        }
        let normalized = LocationFormatter.normalizedForComparison(value)
        guard normalized.isEmpty == false else {
            return false
        }
        if let address,
           LocationFormatter.normalizedForComparison(address) == normalized {
            return false
        }
        if let address,
           LocationFormatter.normalizedForComparison(address).contains(normalized),
           value.rangeOfCharacter(from: .decimalDigits) != nil {
            return false
        }
        if components.compactMap({ $0?.trimmedNonEmpty }).contains(where: {
            LocationFormatter.normalizedForComparison($0) == normalized
        }) {
            return false
        }
        return value.contains("丁目") == false
            && value.contains("番地") == false
            && value.contains("号") == false
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
