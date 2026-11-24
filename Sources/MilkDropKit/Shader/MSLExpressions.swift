/// Expressions: type inference with HLSL's implicit conversions (vector truncation, scalar splat, int ↔ float, bool → number)
/// made explicit for MSL. Every compound expression is emitted in parentheses.
extension MSLGenerator {
    private static let swizzleSets = ["xyzw", "rgba"].map(Array.init)
    static let xyzw = Array("xyzw")

    func expr(_ e: Expr, statement: Bool = false) throws -> Value {
        switch e {
        case .number(let text, _): return number(text)
        case .bool(let b): return Value(code: b ? "true" : "false", type: .scalar(.bool), literal: true)
        case .ident(let name, let line): return try lookup(name, line: line)
        case .call(let name, let args, let line): return try call(name, args, line)
        case .cast(let type, let e): return try convert(try expr(e), to: type)
        case .member(let base, let name): return try member(try expr(base), name)
        case .index(let base, let index): return try subscriptValue(try expr(base), try expr(index))
        case .unary(let op, let e): return try unary(op, try expr(e))
        case .postfix(let op, let e):
            let v = try expr(e)
            guard v.lvalue else { throw HLSLError("'\(op)' needs a variable") }
            return Value(code: statement ? "\(v.code)\(op)" : "(\(v.code)\(op))", type: v.type)
        case .binary(let op, let a, let b): return try binary(op, try expr(a), try expr(b))
        case .assign(let op, let l, let r): return try assign(op, try expr(l), try expr(r), statement: statement)
        case .ternary(let c, let a, let b): return try ternary(try expr(c), try expr(a), try expr(b))
        case .comma(let a, let b):
            let (x, y) = (try expr(a, statement: true), try expr(b, statement: statement))
            return Value(code: statement ? "\(x.code), \(y.code)" : "(\(x.code), \(y.code))", type: y.type)
        case .list: throw HLSLError("unexpected { } list")
        }
    }

    private func number(_ text: String) -> Value {
        let lower = text.lowercased()
        let digits = String(text.reversed().drop { "fFhHlLuU".contains($0) }.reversed())
        if lower.hasPrefix("0x") { return Value(code: digits, type: .scalar(.int), literal: true) }
        if digits.contains(".") || lower.contains("e") || lower.hasSuffix("f") || lower.hasSuffix("h") {
            let code = digits.contains(".") || digits.lowercased().contains("e") ? digits : digits + ".0"
            return Value(code: code, type: .float, literal: true)
        }
        return Value(code: digits, type: .scalar(lower.hasSuffix("u") ? .uint : .int), literal: true)
    }

    // MARK: Conversions

    /// `v` as type `t`, the way HLSL converts on assignment, argument passing and casts.
    func convert(_ v: Value, to t: HType) throws -> Value {
        if v.type == t { return v }
        guard let from = v.type.kind else { throw HLSLError("cannot convert \(v.type.msl) to \(t.msl)") }
        switch t {
        case .scalar(let k):
            if v.type.isMatrix { return cast(Value(code: "\(v.code)[0][0]", type: .scalar(from)), k) }
            return cast(v.type.size == 1 ? v : Value(code: "\(v.code).x", type: .scalar(from)), k)
        case .vector(let k, let n):
            if v.type.isMatrix {
                let parts = try components(v).prefix(n).map { try convert($0, to: .scalar(k)).code }
                guard parts.count == n else { break }
                return Value(code: "\(t.msl)(\(parts.joined(separator: ", ")))", type: t)
            }
            let m = v.type.size
            if m == 1 { return Value(code: "\(t.msl)(\(cast(v, k).code))", type: t) }
            var w = v
            if m > n {
                w = Value(code: "\(v.code).\(String(Self.xyzw.prefix(n)))", type: .vector(from, n), lvalue: v.lvalue)
            } else if m < n {
                w = Value(code: "\(HType.vector(from, n).msl)(\(v.code)\(String(repeating: ", 0", count: n - m)))", type: .vector(from, n))
            }
            return cast(w, k)
        case .matrix(_, let r, let c):
            if v.type.size == 1 {
                let s = cast(v, .float).code
                return Value(code: "\(t.msl)(\(Array(repeating: s, count: r * c).joined(separator: ", ")))", type: t)
            }
            if case .matrix(_, let r0, let c0) = v.type, r0 >= r, c0 >= c {
                let cols = (0..<r).map { c0 == c ? "\(v.code)[\($0)]" : "\(v.code)[\($0)].\(String(Self.xyzw.prefix(c)))" }
                return Value(code: "\(t.msl)(\(cols.joined(separator: ", ")))", type: t)
            }
            if v.type.size == r * c {
                let parts = try components(v).map { try convert($0, to: .float).code }
                return Value(code: "\(t.msl)(\(parts.joined(separator: ", ")))", type: t)
            }
        default:
            break
        }
        throw HLSLError("cannot convert \(v.type.msl) to \(t.msl)")
    }

    /// Changes only the element kind of a scalar or vector.
    func cast(_ v: Value, _ k: ScalarKind) -> Value {
        guard let from = v.type.kind, from != k else { return v }
        if v.literal, v.type == .scalar(.int), k == .float, !v.code.lowercased().hasPrefix("0x") {
            return Value(code: v.code + ".0", type: .float, literal: true)
        }
        let t = v.type.with(k)
        return Value(code: "\(t.msl)(\(v.code))", type: t)
    }

    /// Scalar parts of a value, in HLSL (row-major) order.
    func components(_ v: Value) -> [Value] {
        guard let k = v.type.kind else { return [] }
        switch v.type {
        case .scalar: return [v]
        case .vector(_, let n): return Self.xyzw.prefix(n).map { Value(code: "\(v.code).\($0)", type: .scalar(k)) }
        case .matrix(_, let r, let c): return (0..<r).flatMap { i in (0..<c).map { Value(code: "\(v.code)[\(i)][\($0)]", type: .scalar(k)) } }
        default: return []
        }
    }

    /// HLSL's element kind for an arithmetic result: float wins, then uint, then int (bool counts as int).
    func commonKind(_ values: [Value], keepBool: Bool = false) -> ScalarKind {
        let kinds = values.compactMap(\.type.kind)
        if kinds.contains(.float) { return .float }
        if kinds.contains(.uint) { return .uint }
        if keepBool, kinds.allSatisfy({ $0 == .bool }) { return .bool }
        return .int
    }

    /// Vectors of different sizes truncate to the smallest; scalars splat.
    func commonSize(_ values: [Value]) -> Int {
        values.map(\.type.size).filter { $0 > 1 }.min() ?? 1
    }

    /// An operand for a binary operator of result type `t`: scalars keep their shape (MSL splats them).
    private func operand(_ v: Value, _ t: HType) throws -> Value {
        guard v.type.isNumeric else { throw HLSLError("\(v.type.msl) is not a number") }
        return v.type.size == 1 ? cast(v, t.kind ?? .float) : try convert(v, to: t)
    }

    // MARK: Operators

    private func member(_ v: Value, _ name: String) throws -> Value {
        guard let kind = v.type.kind else { throw HLSLError("'.\(name)' on \(v.type.msl)") }
        if v.type.isMatrix {
            let digits = name.compactMap(\.wholeNumberValue)
            guard name.hasPrefix("_"), digits.count == 2 else { throw HLSLError("unsupported matrix member '\(name)'") }
            let (r, c) = name.hasPrefix("_m") ? (digits[0], digits[1]) : (digits[0] - 1, digits[1] - 1)
            return Value(code: "\(v.code)[\(r)][\(c)]", type: .scalar(kind), lvalue: v.lvalue)
        }
        let chars = Array(name)
        guard let set = Self.swizzleSets.first(where: { s in chars.allSatisfy(s.contains) }), (1...4).contains(chars.count) else {
            throw HLSLError("bad swizzle '.\(name)'")
        }
        let indices = chars.map { set.firstIndex(of: $0)! }
        guard indices.allSatisfy({ $0 < v.type.size }) else { throw HLSLError("swizzle '.\(name)' out of range for \(v.type.msl)") }
        let type = HType.make(kind, indices.count)
        if v.type.size == 1 { return indices.count == 1 ? v : Value(code: "\(type.msl)(\(v.code))", type: type) }
        let lvalue = v.lvalue && Set(indices).count == indices.count
        return Value(code: "\(v.code).\(String(indices.map { Self.xyzw[$0] }))", type: type, lvalue: lvalue)
    }

    private func subscriptValue(_ base: Value, _ index: Value) throws -> Value {
        let i = try convert(index, to: index.type.kind == .uint ? .scalar(.uint) : .scalar(.int)).code
        let type: HType
        switch base.type {
        case .array(let elem, _): type = elem
        case .vector(let k, _): type = .scalar(k)
        case .matrix(let k, _, let c): type = .make(k, c)
        default: throw HLSLError("cannot index \(base.type.msl)")
        }
        return Value(code: "\(base.code)[\(i)]", type: type, lvalue: base.lvalue)
    }

    private func unary(_ op: String, _ v: Value) throws -> Value {
        switch op {
        case "+": return Value(code: v.code, type: v.type, literal: v.literal)
        case "-":
            if v.literal { return Value(code: v.code.hasPrefix("-") ? String(v.code.dropFirst()) : "-" + v.code, type: v.type, literal: true) }
            if v.type.isMatrix { return Value(code: "(\(v.code) * -1.0)", type: v.type) }
            return Value(code: "(-\(v.code))", type: v.type.kind == .bool ? v.type.with(.int) : v.type)
        case "!": return Value(code: "(!\(v.code))", type: .make(.bool, max(v.type.size, 1)))
        case "~": return Value(code: "(~\(v.code))", type: v.type)
        default:
            guard v.lvalue else { throw HLSLError("'\(op)' needs a variable") }
            return Value(code: "(\(op)\(v.code))", type: v.type)
        }
    }

    func binary(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        if a.type.isMatrix || b.type.isMatrix { return try matrixBinary(op, a, b) }
        guard a.type.isNumeric, b.type.isNumeric else { throw HLSLError("'\(op)' on \(a.type.msl) and \(b.type.msl)") }
        let size = commonSize([a, b])
        switch op {
        case "<", ">", "<=", ">=", "==", "!=":
            let t = HType.make(commonKind([a, b], keepBool: true), size)
            return Value(code: "(\(try operand(a, t).code) \(op) \(try operand(b, t).code))", type: .make(.bool, size))
        case "&&", "||":
            if size == 1 { return Value(code: "(\(a.code) \(op) \(b.code))", type: .scalar(.bool)) }
            let t = HType.make(.bool, size)
            return Value(code: "(\(try convert(a, to: t).code) \(op) \(try convert(b, to: t).code))", type: t)
        case "&", "|", "^", "<<", ">>":
            let t = HType.make(commonKind([a, b]) == .uint ? .uint : .int, size)
            return Value(code: "(\(try operand(a, t).code) \(op) \(try operand(b, t).code))", type: t)
        default:
            let t = HType.make(commonKind([a, b]), size)
            if op == "%", t.kind == .float {
                return Value(code: "fmod(\(try convert(a, to: t).code), \(try convert(b, to: t).code))", type: t)
            }
            return Value(code: "(\(try operand(a, t).code) \(op) \(try operand(b, t).code))", type: t)
        }
    }

    /// HLSL `*` and `/` on matrices work per component; `mul()` is the matrix product.
    private func matrixBinary(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        let m = a.type.isMatrix ? a : b
        guard ["+", "-", "*", "/"].contains(op) else { throw HLSLError("'\(op)' on a matrix") }
        if a.type.isMatrix, b.type.isMatrix {
            guard a.type == b.type else { throw HLSLError("'\(op)' on \(a.type.msl) and \(b.type.msl)") }
        } else {
            guard (a.type.isMatrix ? b : a).type.size == 1 else { throw HLSLError("'\(op)' on a matrix and a vector") }
            if op == "*" { return Value(code: "(\(cast(a, .float).code) * \(cast(b, .float).code))", type: m.type) }
        }
        let (x, y) = (try convert(a, to: m.type), try convert(b, to: m.type))
        switch op {
        case "*": return Value(code: "md_mul_cw(\(x.code), \(y.code))", type: m.type)
        case "/": return Value(code: "md_div_cw(\(x.code), \(y.code))", type: m.type)
        default: return Value(code: "(\(x.code) \(op) \(y.code))", type: m.type)
        }
    }

    private func assign(_ op: String, _ l: Value, _ r: Value, statement: Bool) throws -> Value {
        guard l.lvalue else { throw HLSLError("cannot assign to '\(l.code)'") }
        var code: String
        let base = String(op.dropLast())
        let sameKind = r.type.kind == l.type.kind || l.type.kind == .float || (r.literal && r.type.kind != .float)
        if op == "=" {
            code = "\(l.code) = \(try convert(r, to: l.type).code)"
        } else if !l.type.isMatrix, !r.type.isMatrix, sameKind, !(base == "%" && l.type.kind == .float), r.type.isNumeric {
            let rv = r.type.size == 1 ? cast(r, l.type.kind ?? .float) : try convert(r, to: l.type)
            code = "\(l.code) \(op) \(rv.code)"
        } else {
            code = "\(l.code) = \(try convert(try binary(base, l, r), to: l.type).code)"
        }
        return Value(code: statement ? code : "(\(code))", type: l.type)
    }

    private func ternary(_ c: Value, _ a: Value, _ b: Value) throws -> Value {
        let t: HType
        if a.type.isMatrix || b.type.isMatrix {
            guard a.type == b.type else { throw HLSLError("?: on \(a.type.msl) and \(b.type.msl)") }
            t = a.type
        } else {
            guard a.type.isNumeric, b.type.isNumeric else { throw HLSLError("?: on \(a.type.msl) and \(b.type.msl)") }
            t = .make(commonKind([a, b], keepBool: true), commonSize([a, b, c]))
        }
        let (x, y) = (try convert(a, to: t), try convert(b, to: t))
        if c.type.size > 1 {
            let cond = try convert(c, to: .make(.bool, t.size))
            return Value(code: "select(\(y.code), \(x.code), \(cond.code))", type: t)
        }
        return Value(code: "(\(c.code) ? \(x.code) : \(y.code))", type: t)
    }
}
