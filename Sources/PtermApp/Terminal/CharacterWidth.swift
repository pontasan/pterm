import Foundation

/// Determine the display width of a Unicode codepoint in a terminal.
///
/// Returns 2 for East Asian Wide/Fullwidth characters (CJK, etc.),
/// 0 for combining characters and zero-width codepoints,
/// 1 for all other printable characters.
/// -1 for non-printable control characters.
///
/// This is a self-contained implementation (no external dependency on wcwidth).
/// Based on Unicode 15.0 East Asian Width property.
enum CharacterWidth {

    static func width(of codepoint: UInt32) -> Int {
        // C0/C1 control characters
        if codepoint < 0x20 || (codepoint >= 0x7F && codepoint < 0xA0) {
            return -1
        }

        // Zero-width characters
        if isZeroWidth(codepoint) {
            return 0
        }

        // East Asian Wide / Fullwidth
        if isWide(codepoint) {
            return 2
        }

        return 1
    }

    /// Zero-width characters: combining marks, zero-width space/joiner, etc.
    private static func isZeroWidth(_ cp: UInt32) -> Bool {
        // Combining Diacritical Marks
        if cp >= 0x0300 && cp <= 0x036F { return true }
        // Combining Diacritical Marks Extended
        if cp >= 0x1AB0 && cp <= 0x1AFF { return true }
        // Combining Diacritical Marks Supplement
        if cp >= 0x1DC0 && cp <= 0x1DFF { return true }
        // Combining Diacritical Marks for Symbols
        if cp >= 0x20D0 && cp <= 0x20FF { return true }
        // Combining Half Marks
        if cp >= 0xFE20 && cp <= 0xFE2F { return true }

        // Zero-width space, zero-width non-joiner, zero-width joiner
        if cp == 0x200B || cp == 0x200C || cp == 0x200D { return true }
        // Word joiner, FEFF (BOM/ZWNBSP)
        if cp == 0x2060 || cp == 0xFEFF { return true }
        // Soft hyphen
        if cp == 0x00AD { return true }

        // Variation selectors
        if cp >= 0xFE00 && cp <= 0xFE0F { return true }
        // Variation selectors supplement
        if cp >= 0xE0100 && cp <= 0xE01EF { return true }

        // Tags
        if cp >= 0xE0001 && cp <= 0xE007F { return true }

        // General combining characters (Mn, Mc, Me categories)
        // Thai combining marks
        if cp >= 0x0E31 && cp <= 0x0E3A { return true }
        if cp >= 0x0E47 && cp <= 0x0E4E { return true }

        // Devanagari, Bengali, etc. combining marks (selected ranges)
        if cp >= 0x0900 && cp <= 0x0903 { return true }
        if cp >= 0x093A && cp <= 0x094F { return true }
        if cp >= 0x0951 && cp <= 0x0957 { return true }

        // Hangul Jamo combining
        if cp >= 0x1160 && cp <= 0x11FF { return true }

        return false
    }

    /// East Asian Wide and Fullwidth characters.
    private static func isWide(_ cp: UInt32) -> Bool {
        // CJK Unified Ideographs
        if cp >= 0x4E00 && cp <= 0x9FFF { return true }
        // CJK Unified Ideographs Extension A
        if cp >= 0x3400 && cp <= 0x4DBF { return true }
        // CJK Unified Ideographs Extension B
        if cp >= 0x20000 && cp <= 0x2A6DF { return true }
        // CJK Unified Ideographs Extension C-F
        if cp >= 0x2A700 && cp <= 0x2CEAF { return true }
        // CJK Compatibility Ideographs
        if cp >= 0xF900 && cp <= 0xFAFF { return true }
        // CJK Compatibility Ideographs Supplement
        if cp >= 0x2F800 && cp <= 0x2FA1F { return true }

        // Fullwidth Forms
        if cp >= 0xFF01 && cp <= 0xFF60 { return true }
        if cp >= 0xFFE0 && cp <= 0xFFE6 { return true }

        // Hiragana
        if cp >= 0x3040 && cp <= 0x309F { return true }
        // Katakana
        if cp >= 0x30A0 && cp <= 0x30FF { return true }
        // Katakana Phonetic Extensions
        if cp >= 0x31F0 && cp <= 0x31FF { return true }
        // Bopomofo
        if cp >= 0x3100 && cp <= 0x312F { return true }
        if cp >= 0x31A0 && cp <= 0x31BF { return true }

        // Hangul Syllables
        if cp >= 0xAC00 && cp <= 0xD7AF { return true }
        // Hangul Jamo Extended
        if cp >= 0xA960 && cp <= 0xA97F { return true }
        if cp >= 0xD7B0 && cp <= 0xD7FF { return true }

        // CJK Symbols and Punctuation
        if cp >= 0x3000 && cp <= 0x303F { return true }
        // Enclosed CJK Letters and Months
        if cp >= 0x3200 && cp <= 0x32FF { return true }
        // CJK Compatibility
        if cp >= 0x3300 && cp <= 0x33FF { return true }
        // Enclosed Ideographic Supplement
        if cp >= 0x1F200 && cp <= 0x1F2FF { return true }

        // CJK Radicals Supplement
        if cp >= 0x2E80 && cp <= 0x2EFF { return true }
        // Kangxi Radicals
        if cp >= 0x2F00 && cp <= 0x2FDF { return true }
        // Ideographic Description Characters
        if cp >= 0x2FF0 && cp <= 0x2FFF { return true }

        // Yi Syllables and Radicals
        if cp >= 0xA000 && cp <= 0xA4CF { return true }

        // Emoji that are typically rendered wide
        if cp >= 0x1F300 && cp <= 0x1F9FF { return true }
        if cp >= 0x1FA00 && cp <= 0x1FA6F { return true }
        if cp >= 0x1FA70 && cp <= 0x1FAFF { return true }
        // Note: U+2600-U+27BF (Misc Symbols, Dingbats) are East Asian Width
        // Neutral/Ambiguous and rendered as width 1 in standard terminals.
        // Treating them as wide breaks CLI tools (e.g. Ink) that rely on
        // wcwidth-compatible column counting.

        return false
    }
}
