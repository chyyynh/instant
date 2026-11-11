import CoreText
import Foundation
import SwiftUI

/// Furigana over Japanese captions, drawn by the Furifont font (github.com/antfu/furifont): it
/// holds a ligature for each dictionary word, so 今日 renders as one glyph with きょう above it
/// while the text itself stays plain. Readings come from the word alone, not the sentence, so a
/// kanji with several readings may be left bare or read wrong.
enum Furigana {
    static let family = "Furifont Sans VF"

    /// Registers the bundled font once, for this process. False if it couldn't be loaded, in
    /// which case captions fall back to the system font.
    static let isAvailable: Bool = {
        guard let url = Bundle.main.url(forResource: "FurifontSansVF", withExtension: "woff2") else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered counts as loaded.
        let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) }
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }()

    /// Whether captions in this language get furigana.
    static func applies(toLanguageCode code: String?) -> Bool { code == "ja" }

    /// Saved listenings keep only their title ("日本語 → 中文"), not the locale.
    static func applies(toLanguages title: String) -> Bool {
        let japanese = Locale(identifier: "ja").localizedString(forLanguageCode: "ja") ?? "日本語"
        return title.hasPrefix(japanese)
    }
}

extension CaptionMetrics {
    /// Japanese with furigana, at this size. The font's ascent already leaves room for the readings.
    static func furiganaFont(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .custom(Furigana.family, fixedSize: size).weight(weight)
    }
}
