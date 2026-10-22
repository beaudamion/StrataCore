import Foundation

public struct LanguageInfo: Identifiable, Hashable {
    public let code: String // ISO 639-2 (3 letters: eng, fra, deu, jpn, etc.)
    public let name: String
    
    public var id: String { code }
    
    public var displayName: String {
        "\(name) (\(code))"
    }
}

public enum LanguageDirectory {
    public static let commonLanguages: [LanguageInfo] = [
        LanguageInfo(code: "und", name: "Undetermined / None"),
        LanguageInfo(code: "eng", name: "English"),
        LanguageInfo(code: "spa", name: "Spanish"),
        LanguageInfo(code: "fra", name: "French"),
        LanguageInfo(code: "deu", name: "German"),
        LanguageInfo(code: "ita", name: "Italian"),
        LanguageInfo(code: "jpn", name: "Japanese"),
        LanguageInfo(code: "kor", name: "Korean"),
        LanguageInfo(code: "zho", name: "Chinese"),
        LanguageInfo(code: "por", name: "Portuguese"),
        LanguageInfo(code: "rus", name: "Russian"),
        LanguageInfo(code: "ara", name: "Arabic"),
        LanguageInfo(code: "hin", name: "Hindi"),
        LanguageInfo(code: "nld", name: "Dutch"),
        LanguageInfo(code: "swe", name: "Swedish"),
        LanguageInfo(code: "nor", name: "Norwegian"),
        LanguageInfo(code: "dan", name: "Danish"),
        LanguageInfo(code: "fin", name: "Finnish"),
        LanguageInfo(code: "pol", name: "Polish"),
        LanguageInfo(code: "tur", name: "Turkish"),
        LanguageInfo(code: "vie", name: "Vietnamese"),
        LanguageInfo(code: "tha", name: "Thai"),
        LanguageInfo(code: "ukr", name: "Ukrainian"),
        LanguageInfo(code: "heb", name: "Hebrew"),
        LanguageInfo(code: "ell", name: "Greek"),
        LanguageInfo(code: "ces", name: "Czech"),
        LanguageInfo(code: "hun", name: "Hungarian"),
        LanguageInfo(code: "ron", name: "Romanian")
    ]
    
    public static func displayName(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = commonLanguages.first(where: { $0.code == trimmed }) {
            return match.name
        }
        // Try Locale
        let locale = Locale(identifier: trimmed)
        if let localized = locale.localizedString(forLanguageCode: trimmed) {
            return localized.capitalized
        }
        return code.isEmpty ? "Undetermined" : code.uppercased()
    }
}
