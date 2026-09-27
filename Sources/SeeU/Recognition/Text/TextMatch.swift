import CoreGraphics
import Foundation

/// 文字比较工具。OCR 每帧会有细小差异（标点、空格、个别错字），
/// 所以跨帧对齐用规范化后的字符二元组 Dice 相似度，不用字符串全等。
nonisolated enum TextMatch {
    static func normalize(_ text: String) -> String {
        foldSplitRadicals(String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        })).lowercased())
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

    // MARK: - 左右结构拆字

    /// Vision 对聊天里的口字旁语气词常拆成两个字（“哈” → “口合”）。
    /// 只收录拼在一起几乎不会是真实词语的组合；“口令”“口里”“口可（可口可乐）”等真实词不在表中。
    static let splitRadicals: [Character: Character] = [
        "合": "哈", "阿": "啊", "尼": "呢", "马": "吗", "巴": "吧", "那": "哪", "恩": "嗯",
        "屋": "喔", "牙": "呀", "乎": "呼", "非": "啡", "加": "咖", "欠": "吹", "乞": "吃",
        "斤": "听", "拉": "啦", "土": "吐", "昌": "唱", "曷": "喝", "亥": "咳", "麻": "嘛",
        "奥": "噢", "我": "哦", "艾": "哎", "卡": "咔", "各": "咯", "多": "哆", "喜": "嘻",
        "黑": "嘿", "包": "咆", "者": "啫", "永": "咏", "亨": "哼", "罗": "啰", "庶": "嗻"
    ]

    /// 把“口X”合成一个字。用于跨帧比较：同一气泡被读成“哈哈”或“口合口合”时视为同一文字。
    static func foldSplitRadicals(_ text: String) -> String {
        guard text.contains("口") else { return text }
        var result = ""
        var iterator = Array(text).makeIterator()
        var pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if c == "口", let next = iterator.next() {
                if let merged = splitRadicals[next] {
                    result.append(merged)
                } else {
                    result.append(c)
                    pending = next
                }
            } else {
                result.append(c)
            }
        }
        return result
    }

    static func hasSplitRadical(_ text: String) -> Bool {
        foldSplitRadicals(text) != text
    }

    /// 以宽度为证据修复拆字：同一行的字框宽度对应的字数更接近合字版本时才替换原文。
    /// 例如 4 个字宽的气泡被读成 8 个字“口合口合口合口合”，改为“哈哈哈哈”；真实写了“口”字的文本不受影响。
    static func repairSplitRadicals(_ text: String, width: CGFloat, height: CGFloat) -> String {
        guard height > 0, width > 0, hasSplitRadical(text) else { return text }
        let folded = foldSplitRadicals(text)
        let actual = width / height
        return abs(units(folded) - actual) < abs(units(text) - actual) ? folded : text
    }

    /// 估计一行文字的宽度（以行高为单位）：中日韩全角字约 1，其他字符约 0.55。
    static func units(_ text: String) -> CGFloat {
        text.reduce(0) { total, c in
            total + (c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
                || (0x1F300...0x1FAFF).contains($0.value) } ? 1 : 0.55)
        }
    }
}
