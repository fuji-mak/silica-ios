import Foundation
#if canImport(SilicaCore)
import SilicaCore
#endif

enum StayResolution {
    struct Details {
        let placeName: String?
        let address: String?
        let matchingAlias: PlaceAliasEntity?
        let title: String
    }

    static func details(for stay: StayEntity, aliases: [PlaceAliasEntity]) -> Details {
        let alias = matchingAlias(for: stay, aliases: aliases)
        let placeName = alias?.name ?? LocationFormatter.placeName(for: stay)
        let address = LocationFormatter.address(for: stay)
        let title = placeName
            ?? address
            ?? String(format: "未確定: %.5f, %.5f", stay.latitude, stay.longitude)
        return Details(
            placeName: placeName,
            address: address,
            matchingAlias: alias,
            title: title
        )
    }

    static func resolvedRecord(for stay: StayEntity, aliases: [PlaceAliasEntity]) -> StayRecord {
        let details = details(for: stay, aliases: aliases)
        return StayRecord(
            arrivalAt: stay.arrivalAt,
            departureAt: stay.departureAt,
            coordinate: stay.coordinate,
            placeName: details.placeName,
            address: details.address
        )
    }

    static func details(for candidate: StayCandidateEntity, aliases: [PlaceAliasEntity]) -> Details {
        let alias = matchingAlias(for: candidate.presentationCoordinate, aliases: aliases)
        let placeName = alias?.name ?? candidate.placeName?.trimmedNonEmpty
        let address = alias?.address?.trimmedNonEmpty ?? candidate.address?.trimmedNonEmpty
        let title = placeName
            ?? address
            ?? AppLanguage.localized("位置を確認中")
        return Details(
            placeName: placeName,
            address: address,
            matchingAlias: alias,
            title: title
        )
    }

    private static func matchingAlias(for stay: StayEntity, aliases: [PlaceAliasEntity]) -> PlaceAliasEntity? {
        matchingAlias(for: stay.coordinate, aliases: aliases)
    }

    static func matchingAlias(
        for coordinate: GeoCoordinate,
        aliases: [PlaceAliasEntity]
    ) -> PlaceAliasEntity? {
        var bestMatch: (alias: PlaceAliasEntity, distance: Double)?

        for alias in aliases {
            let distance = GeoDistance.meters(from: coordinate, to: alias.coordinate)
            guard PlaceCandidatePolicy.matchesRegisteredPlace(
                distanceMeters: distance,
                radiusMeters: alias.radiusMeters
            ) else {
                continue
            }

            guard let current = bestMatch else {
                bestMatch = (alias, distance)
                continue
            }

            if alias.priority > current.alias.priority ||
                (alias.priority == current.alias.priority && distance < current.distance) {
                bestMatch = (alias, distance)
            }
        }

        return bestMatch?.alias
    }

    static func sharedRegisteredPlaceRadius(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        aliases: [PlaceAliasEntity]
    ) -> Double? {
        guard let originAlias = matchingAlias(for: origin, aliases: aliases),
              originAlias.id == matchingAlias(for: destination, aliases: aliases)?.id else {
            return nil
        }
        return originAlias.radiusMeters
    }
}
