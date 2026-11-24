/// Syntax tree of EEL code. Variables are already resolved to scope slots.
indirect enum EELNode {
    case number(Double)
    case read(EELTarget)
    /// `op` is set for compound assignment (`+=` and others).
    case assign(EELTarget, op: EELOp?, EELNode)
    case call(EELOp, [EELNode])
    case and(EELNode, EELNode)
    case or(EELNode, EELNode)
    case select(EELNode, EELNode, EELNode)
    case sequence([EELNode])
    case loop(EELNode, EELNode)
    case whileLoop(EELNode)
}

/// What can be read and assigned: a variable slot, or a megabuf / gmegabuf cell.
enum EELTarget {
    case variable(Int)
    case memory(EELNode, global: Bool)
}

/// Recursive descent parser with NS-EEL2 precedence (low to high):
/// assignment, `?:`, `&& ||`, comparisons, `& |`, `+ -`, `* / %`, `^`, unary `- + !`.
/// As in NS-EEL2, an assignment binds to the variable right before it: `a * b = c` is `a * (b = c)`.
struct EELParser {
    private static let levels: [[String: EELOp]] = [
        ["&&": .and, "||": .or],
        ["==": .eq, "!=": .ne, "<": .lt, ">": .gt, "<=": .le, ">=": .ge],
        ["&": .bitAnd, "|": .bitOr],
        ["+": .add, "-": .sub],
        ["*": .mul, "/": .div, "%": .mod],
        ["^": .pow],
    ]
    private static let assignments: [String: EELOp?] = ["=": nil, "+=": .add, "-=": .sub, "*=": .mul, "/=": .div, "%=": .mod, "^=": .pow]
    private static let functions: [String: (EELOp, Int)] = [
        "sin": (.sin, 1), "cos": (.cos, 1), "tan": (.tan, 1), "asin": (.asin, 1), "acos": (.acos, 1), "atan": (.atan, 1),
        "exp": (.exp, 1), "log": (.log, 1), "log10": (.log10, 1), "sqrt": (.sqrt, 1), "sqr": (.sqr, 1), "abs": (.abs, 1),
        "sign": (.sign, 1), "floor": (.floor, 1), "int": (.floor, 1), "ceil": (.ceil, 1), "invsqrt": (.invsqrt, 1),
        "rand": (.rand, 1), "bnot": (.not, 1), "atan2": (.atan2, 2), "pow": (.pow, 2), "min": (.min, 2), "max": (.max, 2),
        "above": (.gt, 2), "below": (.lt, 2), "equal": (.eq, 2), "band": (.band, 2), "bor": (.bor, 2),
        "sigmoid": (.sigmoid, 2), "memcpy": (.memcpy, 3), "memset": (.memset, 3),
        // MilkDrop's NS-EEL2 compiles `a >= b` as `_aboeq(a, b)` and so on, and presets may call these names too.
        "_equal": (.eq, 2), "_noteq": (.ne, 2), "_below": (.lt, 2), "_above": (.gt, 2), "_beleq": (.le, 2), "_aboeq": (.ge, 2),
        "_mod": (.mod, 2), "_not": (.not, 1),
    ]

    private let tokens: [EELToken]
    private var pos = 0
    private let resolve: (String) -> Int

    /// `resolve` maps a lowercased variable name to its slot.
    init(_ source: String, resolve: @escaping (String) -> Int) throws {
        tokens = try EELLexer.tokens(source)
        self.resolve = resolve
    }

    mutating func parseProgram() throws -> EELNode {
        let node = try sequence()
        guard tokens[pos].kind == .end else { throw unexpected() }
        return node
    }

    /// Expressions separated by `;`, up to `)`, `,` or the end. Its value is the last one.
    private mutating func sequence() throws -> EELNode {
        var items: [EELNode] = []
        while true {
            while accept(";") {}
            if tokens[pos].kind == .end || peek(")") || peek(",") { break }
            items.append(try ternary())
            if !accept(";") { break }
        }
        return items.count == 1 ? items[0] : .sequence(items)
    }

    private mutating func ternary() throws -> EELNode {
        let condition = try binary(0)
        guard accept("?") else { return condition }
        let then = peek(":") ? EELNode.number(0) : try ternary()
        let otherwise = accept(":") ? try ternary() : .number(0)
        return .select(condition, then, otherwise)
    }

    private mutating func binary(_ level: Int) throws -> EELNode {
        guard level < Self.levels.count else { return try unary() }
        var left = try binary(level + 1)
        while let symbol = tokens[pos].symbol, let op = Self.levels[level][symbol] {
            pos += 1
            let right = try binary(level + 1)
            left = switch op {
            case .and: .and(left, right)
            case .or: .or(left, right)
            default: .call(op, [left, right])
            }
        }
        return left
    }

    private mutating func unary() throws -> EELNode {
        if accept("+") { return try unary() }
        if accept("!") { return .call(.not, [try unary()]) }
        guard accept("-") else { return try primary() }
        let value = try unary()
        if case .number(let n) = value { return .number(-n) }
        return .call(.neg, [value])
    }

    private mutating func primary() throws -> EELNode {
        let token = tokens[pos]
        switch token.kind {
        case .number(let n):
            pos += 1
            // NS-EEL2 also takes `0 = x` (it stores x into the constant's own cell): its value is x.
            guard accept("=") else { return .number(n) }
            return try ternary()
        case .name(let name):
            pos += 1
            return accept("(") ? try call(name) : try assignment(to: .variable(resolve(name)))
        case .symbol("("):
            pos += 1
            let inner = try sequence()
            try expect(")")
            return inner
        default:
            throw unexpected()
        }
    }

    private mutating func call(_ name: String) throws -> EELNode {
        let line = tokens[pos].line
        var args: [EELNode] = []
        if !accept(")") {
            repeat { args.append(try sequence()) } while accept(",")
            try expect(")")
        }
        func arity(_ n: Int) throws {
            guard args.count == n else { throw EELError("line \(line): \(name) takes \(n) argument\(n == 1 ? "" : "s"), not \(args.count)") }
        }
        switch name {
        case "if", "_if": try arity(3); return .select(args[0], args[1], args[2])
        case "_and": try arity(2); return .and(args[0], args[1])
        case "_or": try arity(2); return .or(args[0], args[1])
        case "_set", "assign":
            try arity(2)
            // NS-EEL2 stores into what the first argument points to: a constant or a temporary just takes the value.
            guard case .read(let target) = args[0] else { return .sequence(args) }
            return .assign(target, op: nil, args[1])
        case "loop": try arity(2); return .loop(args[0], args[1])
        case "while": try arity(1); return .whileLoop(args[0])
        case "exec2": try arity(2); return .sequence(args)
        case "exec3": try arity(3); return .sequence(args)
        case "freembuf": try arity(1); return args[0]
        case "megabuf", "gmegabuf": try arity(1); return try assignment(to: .memory(args[0], global: name == "gmegabuf"))
        default:
            guard let (op, n) = Self.functions[name] else { throw EELError("line \(line): unknown function '\(name)'") }
            try arity(n)
            return .call(op, args)
        }
    }

    /// A read of `target`, or an assignment to it when an assignment operator follows.
    private mutating func assignment(to target: EELTarget) throws -> EELNode {
        guard let symbol = tokens[pos].symbol, let op = Self.assignments[symbol] else { return .read(target) }
        pos += 1
        return .assign(target, op: op, try ternary())
    }

    private func peek(_ symbol: String) -> Bool { tokens[pos].symbol == symbol }

    private mutating func accept(_ symbol: String) -> Bool {
        guard peek(symbol) else { return false }
        pos += 1
        return true
    }

    private mutating func expect(_ symbol: String) throws {
        guard accept(symbol) else { throw EELError("line \(tokens[pos].line): expected '\(symbol)', found \(describe(tokens[pos]))") }
    }

    private func unexpected() -> EELError {
        EELError("line \(tokens[pos].line): unexpected \(describe(tokens[pos]))")
    }

    private func describe(_ token: EELToken) -> String {
        switch token.kind {
        case .number(let n): "number \(n)"
        case .name(let n): "'\(n)'"
        case .symbol(let s): "'\(s)'"
        case .end: "end of code"
        }
    }
}
