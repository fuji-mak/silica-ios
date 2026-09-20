import Foundation

enum AppDataProtection {
    private static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    static func applyApplicationSupportProtection() {
        let fileManager = FileManager.default
        guard let directoryURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        applyProtection(to: directoryURL, fileManager: fileManager)

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            applyProtection(to: fileURL, fileManager: fileManager)
        }
    }

    private static func applyProtection(to url: URL, fileManager: FileManager) {
        try? fileManager.setAttributes(
            [.protectionKey: fileProtection],
            ofItemAtPath: url.path
        )
    }
}
