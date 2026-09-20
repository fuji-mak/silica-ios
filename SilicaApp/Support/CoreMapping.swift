import Foundation
import SwiftData
#if canImport(SilicaCore)
import SilicaCore
#endif

extension StayEntity {
    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

extension MovementPointEntity {
    var corePoint: MovementPoint {
        MovementPoint(
            timestamp: timestamp,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            horizontalAccuracy: horizontalAccuracy
        )
    }
}

extension PlaceAliasEntity {
    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

enum PlaceAliasStore {
    static func visibleAliases(from aliases: [PlaceAliasEntity]) -> [PlaceAliasEntity] {
        var result: [PlaceAliasEntity] = []
        for alias in aliases.sorted(by: aliasSort) {
            guard result.contains(where: { isDuplicate($0, alias) }) == false else {
                continue
            }
            result.append(alias)
        }
        return result
    }

    @discardableResult
    static func upsert(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        priority: Int = 0,
        sourcePlaceName: String? = nil,
        address: String? = nil,
        aliases: [PlaceAliasEntity],
        modelContext: ModelContext
    ) -> PlaceAliasEntity {
        if let existing = visibleAliases(from: aliases).first(where: {
            isDuplicate($0, latitude: latitude, longitude: longitude)
        }) {
            existing.name = name
            existing.latitude = latitude
            existing.longitude = longitude
            existing.radiusMeters = max(existing.radiusMeters, radiusMeters)
            existing.priority = max(existing.priority, priority)
            if let sourcePlaceName = sourcePlaceName?.trimmedNonEmpty {
                existing.sourcePlaceName = sourcePlaceName
            }
            if let address = address?.trimmedNonEmpty {
                existing.address = address
            }
            existing.updatedAt = Date()
            try? modelContext.save()
            return existing
        }

        let alias = PlaceAliasEntity(
            name: name,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            priority: priority,
            sourcePlaceName: sourcePlaceName?.trimmedNonEmpty,
            address: address?.trimmedNonEmpty
        )
        modelContext.insert(alias)
        try? modelContext.save()
        return alias
    }

    static func deduplicate(aliases: [PlaceAliasEntity], modelContext: ModelContext) {
        var kept: [PlaceAliasEntity] = []
        var didChange = false
        for alias in aliases.sorted(by: aliasSort) {
            if let existing = kept.first(where: { isDuplicate($0, alias) }) {
                existing.radiusMeters = max(existing.radiusMeters, alias.radiusMeters)
                existing.priority = max(existing.priority, alias.priority)
                existing.updatedAt = Date()
                modelContext.delete(alias)
                didChange = true
            } else {
                kept.append(alias)
            }
        }
        if didChange {
            try? modelContext.save()
        }
    }

    private static func isDuplicate(_ lhs: PlaceAliasEntity, _ rhs: PlaceAliasEntity) -> Bool {
        isDuplicate(lhs, latitude: rhs.latitude, longitude: rhs.longitude)
    }

    private static func isDuplicate(_ alias: PlaceAliasEntity, latitude: Double, longitude: Double) -> Bool {
        PlaceCandidatePolicy.representsSameCandidate(
            alias.coordinate,
            GeoCoordinate(latitude: latitude, longitude: longitude)
        )
    }

    private static func aliasSort(_ lhs: PlaceAliasEntity, _ rhs: PlaceAliasEntity) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}
