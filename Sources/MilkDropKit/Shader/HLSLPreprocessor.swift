/// The C preprocessor subset MilkDrop shaders use: comments, `#define` (also with parameters), `#undef`,
/// `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`. Other directives are ignored.
struct HLSLPreprocessor {
    struct Macro {
        var params: [String]?
        var body: [Token]
    }

    /// The macros of MilkDrop's `include.fx`.
    static let builtins = """
    #define M_PI 3.14159265359
    #define M_PI_2 6.28318530718
    #define M_INV_PI_2 0.159154943091895
    #define GetMain(uv) (tex2D(sampler_main,uv).xyz)
    #define GetPixel(uv) (tex2D(sampler_main,uv).xyz)
    #define GetBlur1(uv) (tex2D(sampler_blur1,uv).xyz*scale1 + bias1)
    #define GetBlur2(uv) (tex2D(sampler_blur2,uv).xyz*scale2 + bias2)
    #define GetBlur3(uv) (tex2D(sampler_blur3,uv).xyz*scale3 + bias3)
    #define lum(x) (dot(x,float3(0.32,0.49,0.29)))
    #define tex2d tex2D
    #define tex3d tex3D
    """

    private var macros: [String: Macro] = [:]

    /// Tokens of `source` after preprocessing, ending with an `.eof` token.
    static func process(_ source: String) throws -> [Token] {
        var pp = HLSLPreprocessor()
        let stream = try pp.scan(builtins, firstLine: -1000) + pp.scan(source, firstLine: 1)
        pp.macros = [:]
        var out = pp.expand(stream)
        out.append(Token(kind: .eof, text: "", line: out.last?.line ?? 0))
        return out
    }

    /// Lexes the active lines. Directives that change macros stay in the stream as `.directive` tokens.
    private mutating func scan(_ source: String, firstLine: Int) throws -> [Token] {
        var out: [Token] = []
        var conditions: [(active: Bool, taken: Bool)] = []
        let lines = Self.stripComments(source).replacingOccurrences(of: "\\\n", with: " ").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let number = firstLine + index
            let active = conditions.allSatisfy(\.active)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.first == "#" else {
                if active { out += try HLSLLexer.tokens(line, line: number) }
                continue
            }
            var words = try HLSLLexer.tokens(trimmed.dropFirst(), line: number)
            guard !words.isEmpty else { continue }
            let directive = words.removeFirst().text
            switch directive {
            case "if", "ifdef", "ifndef":
                let value = directive == "if" ? evaluate(words) : (macros[words.first?.text ?? ""] != nil) == (directive == "ifdef")
                conditions.append((value, value))
            case "elif":
                guard let last = conditions.popLast() else { throw HLSLError("#elif without #if", line: number) }
                let value = !last.taken && evaluate(words)
                conditions.append((value, last.taken || value))
            case "else":
                guard let last = conditions.popLast() else { throw HLSLError("#else without #if", line: number) }
                conditions.append((!last.taken, true))
            case "endif":
                guard conditions.popLast() != nil else { throw HLSLError("#endif without #if", line: number) }
            case "define" where active:
                guard let name = words.first, name.kind == .ident else { throw HLSLError("bad #define", line: number) }
                var macro = Macro(params: nil, body: Array(words.dropFirst()))
                // A `(` right after the name (no space) starts a parameter list.
                if words.count > 1, words[1].text == "(", trimmed.contains("\(name.text)(") {
                    guard let close = words.firstIndex(where: { $0.text == ")" }) else { throw HLSLError("bad #define", line: number) }
                    macro.params = words[2..<close].filter { $0.kind == .ident }.map(\.text)
                    macro.body = Array(words[(close + 1)...])
                }
                macros[name.text] = macro
                out.append(Token(kind: .directive, text: name.text, line: number))
                pendingMacros.append(macro)
            case "undef" where active:
                if let name = words.first?.text {
                    macros[name] = nil
                    out.append(Token(kind: .directive, text: name, line: number))
                    pendingMacros.append(nil)
                }
            default:
                break
            }
        }
        return out
    }

    /// Macro definitions in stream order, replayed by `expand`; nil is an `#undef`.
    private var pendingMacros: [Macro?] = []

    private mutating func expand(_ stream: [Token]) -> [Token] {
        var input = Array(stream.reversed())
        var out: [Token] = []
        var directive = 0
        while let token = input.popLast() {
            if token.kind == .directive {
                macros[token.text] = pendingMacros[directive]
                directive += 1
                continue
            }
            guard token.kind == .ident, let macro = macros[token.text], !token.hidden.contains(token.text) else {
                out.append(token)
                continue
            }
            var body = macro.body
            if let params = macro.params {
                guard input.last?.text == "(", let args = Self.arguments(&input) else {
                    out.append(token)
                    continue
                }
                let expanded = args.map { arg in
                    var sub = HLSLPreprocessor()
                    sub.macros = macros
                    return sub.expand(arg)
                }
                body = body.flatMap { t in
                    if t.kind == .ident, let i = params.firstIndex(of: t.text), i < expanded.count { return expanded[i] }
                    return [t]
                }
            }
            let hidden = token.hidden.union([token.text])
            input += body.reversed().map { t in
                var t = t
                t.line = token.line
                t.hidden.formUnion(hidden)
                return t
            }
        }
        return out
    }

    /// Reads `( a, b )` from the reversed input. Returns nil when the parentheses do not close.
    private static func arguments(_ input: inout [Token]) -> [[Token]]? {
        let saved = input
        _ = input.popLast()
        var args: [[Token]] = [[]]
        var depth = 0
        while let t = input.popLast() {
            if t.kind == .directive { continue }
            if t.text == "(" { depth += 1 }
            if t.text == ")" {
                if depth == 0 { return args.count == 1 && args[0].isEmpty ? [] : args }
                depth -= 1
            }
            if t.text == ",", depth == 0 { args.append([]) } else { args[args.count - 1].append(t) }
        }
        input = saved
        return nil
    }

    /// Value of a `#if` expression: numbers, `defined(X)`, macro names, `!`, `&&`, `||`, `==`, `!=`, parentheses.
    private func evaluate(_ tokens: [Token]) -> Bool {
        var i = 0
        func atom() -> Int {
            guard i < tokens.count else { return 0 }
            let t = tokens[i]
            i += 1
            switch t.text {
            case "!": return atom() == 0 ? 1 : 0
            case "(":
                let v = or()
                i += 1
                return v
            case "defined":
                let paren = i < tokens.count && tokens[i].text == "("
                if paren { i += 1 }
                let name = i < tokens.count ? tokens[i].text : ""
                i += paren ? 2 : 1
                return macros[name] != nil ? 1 : 0
            default:
                if t.kind == .number { return Int(Double(t.text.filter { $0.isNumber || $0 == "." }) ?? 0) }
                if let body = macros[t.text]?.body, let first = body.first, first.kind == .number { return Int(Double(first.text) ?? 0) }
                return 0
            }
        }
        func compare() -> Int {
            var v = atom()
            while i < tokens.count, tokens[i].text == "==" || tokens[i].text == "!=" {
                let op = tokens[i].text
                i += 1
                let r = atom()
                v = (op == "==") == (v == r) ? 1 : 0
            }
            return v
        }
        func and() -> Int {
            var v = compare()
            while i < tokens.count, tokens[i].text == "&&" {
                i += 1
                v = (compare() != 0 && v != 0) ? 1 : 0
            }
            return v
        }
        func or() -> Int {
            var v = and()
            while i < tokens.count, tokens[i].text == "||" {
                i += 1
                v = (and() != 0 || v != 0) ? 1 : 0
            }
            return v
        }
        return or() != 0
    }

    /// Replaces `//` and `/* */` comments with spaces, keeping line breaks.
    static func stripComments(_ source: String) -> String {
        var out = String.UnicodeScalarView()
        let s = Array(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").unicodeScalars)
        var i = 0
        while i < s.count {
            if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i < s.count, !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") {
                    if s[i] == "\n" { out.append("\n") }
                    i += 1
                }
                i += 2
                out.append(" ")
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return String(out)
    }
}
