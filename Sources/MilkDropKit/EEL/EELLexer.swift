/// One token of EEL source.
struct EELToken {
    enum Kind: Equatable {
        case number(Double)
        case name(String)
        case symbol(String)
        case end
    }

    var kind: Kind
    var line: Int

    var symbol: String? {
        if case .symbol(let s) = kind { s } else { nil }
    }
}

/// Splits EEL source into tokens; skips whitespace and `//`, `/* */` comments. Names come out lowercased.
enum EELLexer {
    private static let symbols2: Set<String> = ["&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "^="]
    private static let symbols1 = Set("+-*/%^&|!<>=?:(),;".utf8)

    static func tokens(_ source: String) throws -> [EELToken] {
        let s = Array(source.utf8)
        var tokens: [EELToken] = []
        var i = 0, line = 1
        func at(_ k: Int) -> UInt8 { k < s.count ? s[k] : 0 }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func isNameStart(_ c: UInt8) -> Bool { (c | 0x20) >= 97 && (c | 0x20) <= 122 || c == 95 }
        func text(_ from: Int) -> String { String(decoding: s[from..<i], as: UTF8.self) }

        while i < s.count {
            let c = s[i]
            if c == 10 { line += 1; i += 1; continue }
            if c == 32 || c == 9 || c == 13 { i += 1; continue }
            if c == 47, at(i + 1) == 47 {
                while i < s.count, s[i] != 10 { i += 1 }
                continue
            }
            if c == 47, at(i + 1) == 42 {
                i += 2
                while i < s.count, !(s[i] == 42 && at(i + 1) == 47) {
                    if s[i] == 10 { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            let start = i
            if isDigit(c) || c == 46 && isDigit(at(i + 1)) {
                while isDigit(at(i)) { i += 1 }
                if at(i) == 46 { i += 1 }
                while isDigit(at(i)) { i += 1 }
                if at(i) | 0x20 == 101, isDigit(at(i + 1)) || (at(i + 1) == 43 || at(i + 1) == 45) && isDigit(at(i + 2)) {
                    i += 2
                    while isDigit(at(i)) { i += 1 }
                }
                guard let value = Double(text(start)) else { throw EELError("line \(line): bad number '\(text(start))'") }
                tokens.append(EELToken(kind: .number(value), line: line))
            } else if isNameStart(c) {
                while isNameStart(at(i)) || isDigit(at(i)) { i += 1 }
                tokens.append(EELToken(kind: .name(text(start).lowercased()), line: line))
            } else if i + 1 < s.count, symbols2.contains(String(decoding: s[i...i + 1], as: UTF8.self)) {
                i += 2
                tokens.append(EELToken(kind: .symbol(text(start)), line: line))
            } else if symbols1.contains(c) {
                i += 1
                tokens.append(EELToken(kind: .symbol(text(start)), line: line))
            } else {
                throw EELError("line \(line): unexpected character '\(String(decoding: [c], as: UTF8.self))'")
            }
        }
        tokens.append(EELToken(kind: .end, line: line))
        return tokens
    }
}
