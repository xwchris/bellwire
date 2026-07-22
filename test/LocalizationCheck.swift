import Foundation

@main
struct LocalizationCheck {
    static func main() throws {
        let reference = Date(timeIntervalSince1970: 1_753_200_000)
        let earlier = reference.addingTimeInterval(-2 * 60 * 60)
        let english = BellwireDateFormatting.relative(
            earlier,
            relativeTo: reference,
            locale: Locale(identifier: "en")
        )
        let chinese = BellwireDateFormatting.relative(
            earlier,
            relativeTo: reference,
            locale: Locale(identifier: "zh-Hans")
        )

        guard english != chinese, english.lowercased().contains("ago"), chinese.contains("前") else {
            throw LocalizationCheckError.localeWasIgnored(english: english, chinese: chinese)
        }
    }
}

enum LocalizationCheckError: Error {
    case localeWasIgnored(english: String, chinese: String)
}
