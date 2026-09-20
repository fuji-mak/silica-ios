import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    static let userDefaultsKey = "appLanguage"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var title: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        }
    }

    static var systemDefault: AppLanguage {
        let languageCode = Locale.autoupdatingCurrent.language.languageCode?.identifier
        return languageCode == AppLanguage.japanese.rawValue ? .japanese : .english
    }

    static var current: AppLanguage {
        if let storedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let storedLanguage = AppLanguage(rawValue: storedValue) {
            return storedLanguage
        }
        return systemDefault
    }

    static var currentLocale: Locale {
        current.locale
    }

    static func localized(_ key: String) -> String {
        localized(key, language: current)
    }

    static func localized(_ key: String, language: AppLanguage) -> String {
        guard let localizationPath = Bundle.main.path(
            forResource: language.rawValue,
            ofType: "lproj"
        ),
        let localizationBundle = Bundle(path: localizationPath) else {
            return key
        }

        return NSLocalizedString(
            key,
            bundle: localizationBundle,
            value: key,
            comment: ""
        )
    }

    static func persist(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: userDefaultsKey)
    }

    static func count(_ value: Int) -> String {
        switch current {
        case .japanese:
            return "\(value)件"
        case .english:
            return value == 1 ? "1 item" : "\(value) items"
        }
    }
}
