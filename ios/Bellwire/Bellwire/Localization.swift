import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "bellwireAppLanguage"

    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Follow system"
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        }
    }

    static func selected(from rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }
}
