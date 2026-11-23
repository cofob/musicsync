/// One HLSL token. `hidden` holds the macros that made it, so a macro does not expand inside itself.
struct Token: Equatable {
    enum Kind { case ident, number, punct, directive, eof }
    var kind: Kind
    var text: String
    var line: Int
    var hidden: Set<String> = []
}

/// Splits one line of HLSL (comments already removed) into tokens.
enum HLSLLexer {
    private static let puncts3 = ["<<=", ">>="]
    private static let puncts2 = ["++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "##"]
    private static let puncts1 = Set("+-*/%<>=!&|^~?:;,.(){}[]#")

    static func tokens(_ line: Substring, line number: Int) throws -> [Token] {
        let chars = Array(line.unicodeScalars)
        var out: [Token] = []
        var i = 0
        func text(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(chars[from..<to])) }
        func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
        func isIdent(_ c: Unicode.Scalar) -> Bool { c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c) || isDigit(c) }
        while i < chars.count {
            let c = chars[i]
            if c.properties.isWhitespace || c.value < 32 { i += 1; continue }
            let start = i
            if isDigit(c) || (c == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
                if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                    i += 2
                    while i < chars.count, chars[i].properties.isASCIIHexDigit { i += 1 }
                } else {
                    while i < chars.count, isDigit(chars[i]) || chars[i] == "." { i += 1 }
                    if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                        var j = i + 1
                        if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                        if j < chars.count, isDigit(chars[j]) {
                            i = j
                            while i < chars.count, isDigit(chars[i]) { i += 1 }
                        }
                    }
                }
                while i < chars.count, "fFhHlLuU".unicodeScalars.contains(chars[i]) { i += 1 }
                out.append(Token(kind: .number, text: text(start, i), line: number))
            } else if isIdent(c) {
                while i < chars.count, isIdent(chars[i]) { i += 1 }
                out.append(Token(kind: .ident, text: text(start, i), line: number))
            } else {
                let rest = text(i, min(i + 3, chars.count))
                if let p = puncts3.first(where: rest.hasPrefix) ?? puncts2.first(where: rest.hasPrefix) {
                    out.append(Token(kind: .punct, text: p, line: number))
                    i += p.unicodeScalars.count
                } else if puncts1.contains(Character(c)) {
                    out.append(Token(kind: .punct, text: String(c), line: number))
                    i += 1
                } else {
                    throw HLSLError("unexpected character '\(c)'", line: number)
                }
            }
        }
        return out
    }
}
