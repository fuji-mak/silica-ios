import Foundation
import SwiftData

@Model
final class PlaceAliasEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var priority: Int
    var symbolName: String = "mappin"
    var sourcePlaceName: String?
    var address: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 100,
        priority: Int = 0,
        sourcePlaceName: String? = nil,
        address: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.priority = priority
        self.symbolName = "mappin"
        self.sourcePlaceName = sourcePlaceName
        self.address = address
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
