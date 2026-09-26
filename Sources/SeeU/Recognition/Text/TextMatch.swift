import Foundation

/// 文字比较工具。OCR 每帧会有细小差异（标点、空格、个别错字），
/// 所以跨帧对齐用规范化后的字符二元组 Dice 相似度，不用字符串全等。
nonisolated enum TextMatch {
    static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        })).lowercased()
    }

    /// 0...1。两个串都已规范化。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let ca = Array(a), cb = Array(b)
        guard !ca.isEmpty, !cb.isEmpty else { return 0 }
        let shorter = Double(min(ca.count, cb.count)), longer = Double(max(ca.count, cb.count))
        guard shorter / longer >= 0.5 else { return 0 }
        if ca.count < 2 || cb.count < 2 { return 0 }
        var bigrams: [String: Int] = [:]
        for i in 0..<(ca.count - 1) { bigrams[String(ca[i...i + 1]), default: 0] += 1 }
        var hits = 0
        for i in 0..<(cb.count - 1) {
            let key = String(cb[i...i + 1])
            if let n = bigrams[key], n > 0 { hits += 1; bigrams[key] = n - 1 }
        }
        return 2 * Double(hits) / Double(ca.count - 1 + cb.count - 1)
    }
}
