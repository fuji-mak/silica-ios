import Foundation
import SwiftData

enum ExportStatus: String {
    case success
    case failed
}

@Model
final class ExportRecordEntity {
    @Attribute(.unique) var id: UUID
    var date: Date
    var filePath: String
    var exportedAt: Date
    var statusRawValue: String
    var errorMessage: String?

    var status: ExportStatus? {
        ExportStatus(rawValue: statusRawValue)
    }

    init(
        date: Date,
        filePath: String,
        status: ExportStatus,
        errorMessage: String? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.filePath = filePath
        self.exportedAt = Date()
        self.statusRawValue = status.rawValue
        self.errorMessage = errorMessage
    }
}
