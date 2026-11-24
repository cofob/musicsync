/// Recursive descent parser from preprocessed tokens to the HLSL AST.
struct HLSLParser {
    private var tokens: [Token]
    private var pos = 0

    private static let qualifiers: Set<String> = [
        "static", "const", "uniform", "extern", "volatile", "shared", "precise", "inline",
        "in", "out", "inout", "row_major", "column_major", "nointerpolation", "linear", "centroid",
    ]

    init(_ tokens: [Token]) { self.tokens = tokens }

    static func parse(_ source: String) throws -> [TopLevel] {
        var parser = HLSLParser(try HLSLPreprocessor.process(source))
        return try parser.program()
    }

    // MARK: Helpers

    private var current: Token { tokens[pos] }
    private func peek(_ offset: Int = 0) -> Token { tokens[min(pos + offset, tokens.count - 1)] }

    private mutating func advance() -> Token {
        let t = tokens[pos]
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    private mutating func accept(_ text: String) -> Bool {
        guard current.kind == .punct || current.kind == .ident, current.text == text else { return false }
        pos += 1
        return true
    }

    private mutating func expect(_ text: String) throws {
        guard accept(text) else { throw error("expected '\(text)'") }
    }

    private func error(_ message: String) -> HLSLError {
        HLSLError("\(message), found '\(current.kind == .eof ? "end of shader" : current.text)'", line: current.line)
    }

    private mutating func identifier() throws -> String {
        guard current.kind == .ident else { throw error("expected a name") }
        return advance().text
    }

    private func isType(_ t: Token) -> Bool { t.kind == .ident && HType(keyword: t.text) != nil }

    /// True when a declaration starts here (qualifiers or a type name that is not a constructor call).
    private func atDeclaration() -> Bool {
        var i = 0
        while Self.qualifiers.contains(peek(i).text), peek(i).kind == .ident { i += 1 }
        return isType(peek(i)) && peek(i + 1).kind == .ident
    }

    // MARK: Top level

    private mutating func program() throws -> [TopLevel] {
        var items: [TopLevel] = []
        while current.kind != .eof {
            if accept(";") { continue }
            if current.text == "shader_body" {
                _ = advance()
                try expect("{")
                items.append(.shaderBody(try statements(until: "}")))
                return items // MilkDrop ignores text after the body.
            }
            if current.text == "struct" || current.text == "typedef" { throw error("unsupported declaration") }
            var quals: Set<String> = []
            while Self.qualifiers.contains(current.text), current.kind == .ident { quals.insert(advance().text) }
            guard let type = HType(keyword: current.text), current.kind == .ident else { throw error("expected a declaration") }
            let line = advance().line
            let name = try identifier()
            if current.text == "(" {
                items.append(.function(try function(type, name, line)))
            } else {
                items.append(.variable(try declaration(quals, type, first: name, line: line)))
                try expect(";")
            }
        }
        throw HLSLError("missing shader_body")
    }

    private mutating func function(_ type: HType, _ name: String, _ line: Int) throws -> FuncDecl {
        try expect("(")
        var params: [Param] = []
        if current.text == "void", peek(1).text == ")" { _ = advance() }
        while current.text != ")" {
            var quals: Set<String> = []
            while Self.qualifiers.contains(current.text) { quals.insert(advance().text) }
            guard var t = HType(keyword: current.text) else { throw error("expected a parameter type") }
            _ = advance()
            let pname = try identifier()
            if accept("[") {
                guard case .number(let n, _) = try expression(), let size = Int(n) else { throw error("expected an array size") }
                try expect("]")
                t = .array(t, size)
            }
            try skipSemantic()
            if accept("=") { _ = try assignment() }
            params.append(Param(qualifiers: quals, type: t, name: pname))
            if !accept(",") { break }
        }
        try expect(")")
        try skipSemantic()
        if accept(";") { return FuncDecl(returnType: type, name: name, params: params, body: nil, line: line) }
        try expect("{")
        return FuncDecl(returnType: type, name: name, params: params, body: try statements(until: "}"), line: line)
    }

    /// Skips `: SEMANTIC` and `: register(x)`.
    private mutating func skipSemantic() throws {
        guard accept(":") else { return }
        _ = try identifier()
        if accept("(") {
            while current.text != ")", current.kind != .eof { _ = advance() }
            try expect(")")
        }
    }

    private mutating func declaration(_ quals: Set<String>, _ type: HType, first: String, line: Int) throws -> VarDecl {
        var decls: [Declarator] = []
        var name = first
        var line = line
        while true {
            var d = Declarator(name: name, line: line)
            if accept("[") {
                d.arraySize = current.text == "]" ? .number("0", line: current.line) : try expression()
                try expect("]")
            }
            try skipSemantic()
            if current.text == "=", peek(1).text == "sampler_state" { // effect state: MilkDrop picks it from the name
                pos += 2
                try expect("{")
                while !accept("}") { if advance().kind == .eof { throw error("expected '}'") } }
            } else if accept("=") {
                d.initializer = current.text == "{" ? try list() : try assignment()
            }
            decls.append(d)
            guard accept(",") else { break }
            line = current.line
            name = try identifier()
        }
        return VarDecl(qualifiers: quals, type: type, declarators: decls)
    }

    private mutating func list() throws -> Expr {
        try expect("{")
        var items: [Expr] = []
        while current.text != "}" {
            items.append(current.text == "{" ? try list() : try assignment())
            if !accept(",") { break }
        }
        try expect("}")
        return .list(items)
    }

    // MARK: Statements

    private mutating func statements(until end: String) throws -> [Stmt] {
        var out: [Stmt] = []
        while !accept(end) {
            if current.kind == .eof { throw error("expected '\(end)'") }
            out.append(try statement())
        }
        return out
    }

    private mutating func statement() throws -> Stmt {
        let word = current.kind == .ident ? current.text : ""
        switch word {
        case "if":
            _ = advance()
            try expect("(")
            let cond = try expression()
            try expect(")")
            let then = try statement()
            return .ifElse(cond, then, accept("else") ? try statement() : nil)
        case "for":
            _ = advance()
            try expect("(")
            let initial: Stmt? = accept(";") ? nil : try simpleStatement()
            let cond = current.text == ";" ? nil : try expression()
            try expect(";")
            let step = current.text == ")" ? nil : try expression()
            try expect(")")
            return .forLoop(initial, cond, step, try statement())
        case "while":
            _ = advance()
            try expect("(")
            let cond = try expression()
            try expect(")")
            return .whileLoop(cond, try statement())
        case "do":
            _ = advance()
            let body = try statement()
            try expect("while")
            try expect("(")
            let cond = try expression()
            try expect(")")
            try expect(";")
            return .doWhile(body, cond)
        case "return":
            _ = advance()
            let value = current.text == ";" ? nil : try expression()
            try expect(";")
            return .ret(value)
        case "break", "continue", "discard":
            _ = advance()
            try expect(";")
            return word == "break" ? .breakLoop : word == "continue" ? .continueLoop : .discard
        default:
            if current.text == "[" { // attributes such as [unroll]
                while current.text != "]", current.kind != .eof { _ = advance() }
                try expect("]")
                return try statement()
            }
            if accept("{") { return .block(try statements(until: "}")) }
            if accept(";") { return .empty }
            return try simpleStatement()
        }
    }

    /// A declaration or an expression, with its `;`.
    private mutating func simpleStatement() throws -> Stmt {
        if atDeclaration() {
            var quals: Set<String> = []
            while Self.qualifiers.contains(current.text) { quals.insert(advance().text) }
            guard let type = HType(keyword: current.text) else { throw error("expected a type") }
            let line = advance().line
            let decl = try declaration(quals, type, first: try identifier(), line: line)
            try expect(";")
            return .decl(decl)
        }
        let e = try expression()
        try expect(";")
        return .expr(e)
    }

    // MARK: Expressions

    mutating func expression() throws -> Expr {
        var e = try assignment()
        while accept(",") { e = .comma(e, try assignment()) }
        return e
    }

    private static let assignOps: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
    private static let binaryLevels: [[String]] = [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"],
    ]

    private mutating func assignment() throws -> Expr {
        let lhs = try ternary()
        if current.kind == .punct, Self.assignOps.contains(current.text) {
            let op = advance().text
            return .assign(op, lhs, try assignment())
        }
        return lhs
    }

    private mutating func ternary() throws -> Expr {
        let cond = try binary(0)
        guard accept("?") else { return cond }
        let a = try assignment()
        try expect(":")
        return .ternary(cond, a, try assignment())
    }

    private mutating func binary(_ level: Int) throws -> Expr {
        guard level < Self.binaryLevels.count else { return try unary() }
        var lhs = try binary(level + 1)
        while current.kind == .punct, Self.binaryLevels[level].contains(current.text) {
            let op = advance().text
            lhs = .binary(op, lhs, try binary(level + 1))
        }
        return lhs
    }

    private mutating func unary() throws -> Expr {
        if current.kind == .punct, ["-", "+", "!", "~", "++", "--"].contains(current.text) {
            let op = advance().text
            return .unary(op, try unary())
        }
        // C-style cast: `(float3) x`.
        if current.text == "(", isType(peek(1)), peek(2).text == ")" {
            _ = advance()
            let type = HType(keyword: advance().text)!
            _ = advance()
            return .cast(type, try unary())
        }
        return try postfix(try primary())
    }

    private mutating func postfix(_ base: Expr) throws -> Expr {
        var e = base
        while true {
            if accept(".") {
                e = .member(e, try identifier())
            } else if accept("[") {
                e = .index(e, try expression())
                try expect("]")
            } else if current.text == "++" || current.text == "--" {
                e = .postfix(advance().text, e)
            } else {
                return e
            }
        }
    }

    private mutating func primary() throws -> Expr {
        let t = current
        switch t.kind {
        case .number:
            _ = advance()
            return .number(t.text, line: t.line)
        case .ident:
            _ = advance()
            if t.text == "true" || t.text == "false" { return .bool(t.text == "true") }
            if accept("(") {
                var args: [Expr] = []
                while current.text != ")" {
                    args.append(try assignment())
                    if !accept(",") { break }
                }
                try expect(")")
                return .call(t.text, args, line: t.line)
            }
            return .ident(t.text, line: t.line)
        default:
            if accept("(") {
                let e = try expression()
                try expect(")")
                return e
            }
            if current.text == "{" { return try list() }
            throw error("expected an expression")
        }
    }
}
