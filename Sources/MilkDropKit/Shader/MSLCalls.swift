/// Calls: constructors, user functions, HLSL intrinsics and texture sampling.
extension MSLGenerator {
    /// One-argument float functions, HLSL name → MSL name.
    private static let unaryFloat: [String: String] = [
        "sin": "sin", "cos": "cos", "tan": "tan", "asin": "asin", "acos": "acos", "atan": "atan", "sinh": "sinh", "cosh": "cosh",
        "tanh": "tanh", "exp": "exp", "exp2": "exp2", "log": "log", "log2": "log2", "log10": "log10", "sqrt": "sqrt",
        "rsqrt": "rsqrt", "floor": "floor", "ceil": "ceil", "round": "round", "trunc": "trunc", "frac": "fract",
        "saturate": "saturate", "ddx": "dfdx", "ddy": "dfdy", "fwidth": "fwidth", "sign": "sign", "abs": "abs",
    ]

    /// Per-component functions of several arguments of one common type, HLSL name → MSL name.
    private static let componentwise: [String: (args: Int, msl: String)] = [
        "pow": (2, "md_pow"), "atan2": (2, "atan2"), "fmod": (2, "fmod"), "step": (2, "step"), "min": (2, "min"), "max": (2, "max"),
        "lerp": (3, "mix"), "clamp": (3, "clamp"), "smoothstep": (3, "smoothstep"),
    ]

    /// MSL functions the generated code calls. HLSL lets a variable share a function's name (`float3 max = max(a, b)`);
    /// MSL does not, so such variables get renamed.
    static let mslFunctions = Set(unaryFloat.values).union(componentwise.values.map(\.msl)).union([
        "dot", "cross", "length", "normalize", "distance", "reflect", "refract", "all", "any", "isnan", "isinf", "isfinite",
        "transpose", "determinant", "modf", "frexp", "ldexp", "pow",
    ])

    func call(_ name: String, _ args: [Expr], _ line: Int) throws -> Value {
        let values = try args.map { try expr($0) }
        do {
            if let type = HType(keyword: name) { return try construct(type, values) }
            if let (decl, msl) = userFunction(name, count: values.count) { return try userCall(decl, msl, values) }
            return try intrinsic(name, values)
        } catch let error as HLSLError where error.line == 0 {
            throw HLSLError("\(name)(): \(error.message)", line: line)
        }
    }

    private func construct(_ type: HType, _ values: [Value]) throws -> Value {
        if values.count == 1 { return try convert(values[0], to: type) }
        switch type {
        case .vector(let k, let n):
            if values.allSatisfy({ !$0.type.isMatrix }), values.map(\.type.size).reduce(0, +) == n {
                let parts = values.map { cast($0, k).code }
                return Value(code: "\(type.msl)(\(parts.joined(separator: ", ")))", type: type)
            }
            let parts = try values.flatMap(components).map { try convert($0, to: .scalar(k)).code }
            guard parts.count >= n else { throw HLSLError("too few values for \(type.msl)") }
            return Value(code: "\(type.msl)(\(parts.prefix(n).joined(separator: ", ")))", type: type)
        case .matrix(_, let r, let c):
            if values.count == r, values.allSatisfy({ $0.type.size == c && c > 1 }) {
                return Value(code: "\(type.msl)(\(values.map { cast($0, .float).code }.joined(separator: ", ")))", type: type)
            }
            let parts = try values.flatMap(components).map { try convert($0, to: .float).code }
            guard parts.count == r * c else { throw HLSLError("wrong number of values for \(type.msl)") }
            return Value(code: "\(type.msl)(\(parts.joined(separator: ", ")))", type: type)
        default:
            throw HLSLError("cannot construct \(type.msl)")
        }
    }

    private func userCall(_ decl: FuncDecl, _ msl: String, _ values: [Value]) throws -> Value {
        var parts = ["_c"]
        for (param, value) in zip(decl.params, values) {
            if param.qualifiers.contains("out") || param.qualifiers.contains("inout") {
                guard value.lvalue, value.type == param.type else { throw HLSLError("out argument must be a \(param.type.msl) variable") }
                parts.append(value.code)
            } else {
                parts.append(try convert(value, to: param.type).code)
            }
        }
        return Value(code: "\(msl)(\(parts.joined(separator: ", ")))", type: decl.returnType)
    }

    /// The common type of per-component arguments; `float` forces a float element kind.
    private func common(_ values: [Value], float: Bool = true) throws -> HType {
        if let m = values.first(where: { $0.type.isMatrix }) {
            guard values.allSatisfy({ $0.type == m.type }) else { throw HLSLError("mixed matrix arguments") }
            return m.type
        }
        guard values.allSatisfy(\.type.isNumeric) else { throw HLSLError("arguments must be numbers") }
        return .make(float ? .float : commonKind(values), commonSize(values))
    }

    private func converted(_ values: [Value], float: Bool = true) throws -> ([String], HType) {
        let t = try common(values, float: float)
        return (try values.map { try convert($0, to: t).code }, t)
    }

    private func intrinsic(_ name: String, _ v: [Value]) throws -> Value {
        func need(_ n: Int) throws { if v.count != n { throw HLSLError("expects \(n) arguments") } }
        let float = HType.float
        if let msl = Self.unaryFloat[name], !(name == "atan" && v.count == 2) {
            try need(1)
            let keepInt = name == "abs" && v[0].type.kind == .int
            let t = try common(v, float: !keepInt)
            return Value(code: "\(msl)(\(try convert(v[0], to: t).code))", type: t)
        }
        if let (count, msl) = Self.componentwise[name] {
            try need(count)
            let (args, t) = try converted(v, float: !["min", "max", "clamp"].contains(name))
            return Value(code: "\(msl)(\(args.joined(separator: ", ")))", type: t)
        }
        switch name {
        case "atan":
            try need(2)
            let (args, t) = try converted(v)
            return Value(code: "atan2(\(args.joined(separator: ", ")))", type: t)
        case "tex2D", "tex3D", "tex2Dlod", "tex3Dlod", "tex2Dbias", "tex3Dbias", "tex2Dproj", "tex2Dgrad":
            return try sample(name, v)
        case "mul":
            try need(2)
            return try mul(v[0], v[1])
        case "dot":
            try need(2)
            let (args, t) = try converted(v)
            return Value(code: t.size == 1 ? "(\(args[0]) * \(args[1]))" : "dot(\(args[0]), \(args[1]))", type: float)
        case "cross":
            try need(2)
            let f3 = HType.vector(.float, 3)
            return Value(code: "cross(\(try convert(v[0], to: f3).code), \(try convert(v[1], to: f3).code))", type: f3)
        case "length", "normalize":
            try need(1)
            let (args, t) = try converted(v)
            if name == "length" { return Value(code: t.size == 1 ? "abs(\(args[0]))" : "length(\(args[0]))", type: float) }
            return Value(code: t.size == 1 ? "sign(\(args[0]))" : "normalize(\(args[0]))", type: t)
        case "distance":
            try need(2)
            let (args, t) = try converted(v)
            return Value(code: t.size == 1 ? "abs(\(args[0]) - \(args[1]))" : "distance(\(args[0]), \(args[1]))", type: float)
        case "reflect":
            try need(2)
            let (args, t) = try converted(v)
            return Value(code: "reflect(\(args.joined(separator: ", ")))", type: t)
        case "refract":
            try need(3)
            let (args, t) = try converted(Array(v.prefix(2)))
            return Value(code: "refract(\(args.joined(separator: ", ")), \(try convert(v[2], to: float).code))", type: t)
        case "mad":
            try need(3)
            let (args, t) = try converted(v)
            return Value(code: "(\(args[0]) * \(args[1]) + \(args[2]))", type: t)
        case "radians", "degrees":
            try need(1)
            let (args, t) = try converted(v)
            return Value(code: "(\(args[0]) * \(name == "radians" ? "0.017453292519943295" : "57.29577951308232"))", type: t)
        case "all", "any":
            try need(1)
            let b = HType.make(.bool, max(v[0].type.size, 1))
            let arg = try convert(v[0], to: b).code
            return Value(code: b.size == 1 ? arg : "\(name)(\(arg))", type: .scalar(.bool))
        case "isnan", "isinf", "isfinite":
            try need(1)
            let (args, t) = try converted(v)
            return Value(code: "\(name)(\(args[0]))", type: t.with(.bool))
        case "transpose":
            try need(1)
            guard case .matrix(let k, let r, let c) = v[0].type else { throw HLSLError("expects a matrix") }
            return Value(code: "transpose(\(v[0].code))", type: .matrix(k, rows: c, cols: r))
        case "determinant":
            try need(1)
            return Value(code: "determinant(\(v[0].code))", type: float)
        case "sincos":
            try need(3)
            guard v[1].lvalue, v[2].lvalue else { throw HLSLError("sincos needs variables") }
            let x = try convert(v[0], to: v[1].type).code
            return Value(code: "(\(v[1].code) = sin(\(x)), \(v[2].code) = cos(\(x)))", type: .void)
        case "modf":
            // Integer part (toward zero) to `ip`, signed fraction as the value.
            try need(2)
            guard v[1].lvalue, v[1].type.kind == .float else { throw HLSLError("modf needs a float variable") }
            let x = try convert(v[0], to: v[1].type).code
            return Value(code: "(\(v[1].code) = trunc(\(x)), \(x) - \(v[1].code))", type: v[1].type)
        default:
            throw HLSLError("unknown function")
        }
    }

    /// HLSL `mul(a, b)` with row vectors is `b * a` on the transposed MSL matrices.
    private func mul(_ a: Value, _ b: Value) throws -> Value {
        switch (a.type, b.type) {
        case (.matrix(_, let r, let k), .matrix(_, let k2, let c)):
            guard k == k2 else { throw HLSLError("matrix sizes do not match") }
            return Value(code: "(\(b.code) * \(a.code))", type: .matrix(.float, rows: r, cols: c))
        case (_, .matrix(_, let r, let c)) where a.type.size > 1:
            let av = try convert(a, to: .vector(.float, r))
            return Value(code: "(\(b.code) * \(av.code))", type: .make(.float, c))
        case (.matrix(_, let r, let c), _) where b.type.size > 1:
            let bv = try convert(b, to: .vector(.float, c))
            return Value(code: "(\(bv.code) * \(a.code))", type: .make(.float, r))
        default:
            if a.type.size > 1, b.type.size > 1 {
                let (args, _) = try converted([a, b])
                return Value(code: "dot(\(args[0]), \(args[1]))", type: .float)
            }
            return try binary("*", a, b)
        }
    }

    private func sample(_ name: String, _ v: [Value]) throws -> Value {
        guard v.count >= 2, let (texture, sampler) = v[0].texture else { throw HLSLError("first argument must be a sampler") }
        let dims = is3D(texture) ? 3 : 2
        let coords = "xyz".prefix(dims)
        let f4 = HType.vector(.float, 4)
        let suffix = name.dropFirst(5)
        var args: String
        switch suffix {
        case "lod", "bias":
            let t = try convert(v[1], to: f4).code
            args = "\(t).\(coords), \(suffix == "lod" ? "level" : "bias")(\(t).w)"
        case "proj":
            let t = try convert(v[1], to: f4).code
            args = "\(t).\(coords) / \(t).w"
        case "grad":
            guard v.count == 4 else { throw HLSLError("expects 4 arguments") }
            let t = HType.vector(.float, dims)
            args = "\(try convert(v[1], to: t).code), gradient\(dims)d(\(try convert(v[2], to: t).code), \(try convert(v[3], to: t).code))"
        default:
            args = try convert(v[1], to: .vector(.float, dims)).code
        }
        return Value(code: "\(texture).sample(\(sampler), \(args))", type: f4)
    }
}
