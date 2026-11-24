/// A translated expression: MSL code plus the HLSL type the checker inferred for it.
struct Value {
    var code: String
    var type: HType
    /// An integer or float literal, so it can change type without a cast.
    var literal = false
    var lvalue = false
    /// Set for `sampler_xxx` names: the texture and sampler expressions to sample with.
    var texture: (texture: String, sampler: String)?
}

/// Type checks the HLSL AST and writes MSL. Globals become members of a per-shader `MDContext` that also holds the
/// uniforms and textures; every user function takes it as its first parameter.
final class MSLGenerator {
    private struct Function {
        var decl: FuncDecl
        var msl: String
    }

    private let allowInternal: Bool
    private var scopes: [[String: (HType, String)]] = []
    private var globals: [String: (HType, String)] = [:]
    private var declaredSamplers: [String] = []
    private var functions: [String: [Function]] = [:]
    private var returnType: HType?
    private var members: [String] = []
    private var globalInits: [String] = []
    private var functionCode: [String] = []
    private var bodyCode = ""
    private(set) var userTextures: [UserTexture] = []
    private(set) var blurLevel = 0

    init(allowInternal: Bool) { self.allowInternal = allowInternal }

    func generate(_ program: [TopLevel]) throws -> String {
        // HLSL lets a shader write to a uniform; such uniforms become context members that start with the uniform value.
        for name in HLSLAssignments.names(program).sorted() {
            guard let uniform = try? lookup(name, line: 0), uniform.texture == nil, !uniform.type.isMatrix else { continue }
            members.append("\(uniform.type.msl) \(mslName(name));")
            globalInits.append("_c.\(mslName(name)) = \(uniform.code);")
            globals[name] = (uniform.type, "_c.\(mslName(name))")
        }
        for item in program {
            switch item {
            case .variable(let decl): try global(decl)
            case .function(let decl): try function(decl)
            case .shaderBody(let body): try shaderBody(body)
            }
        }
        return assemble()
    }

    // MARK: Names

    func mslName(_ name: String) -> String {
        MSLPreamble.reserved.contains(name) || name.hasPrefix("md_") || name == "_c" ? name + "_" : name
    }

    func lookup(_ name: String, line: Int) throws -> Value {
        for scope in scopes.reversed() {
            if let (type, code) = scope[name] { return Value(code: code, type: type, lvalue: true) }
        }
        if let (type, code) = globals[name] { return Value(code: code, type: type, lvalue: true) }
        if let (type, path) = MSLPreamble.uniforms[name] ?? (allowInternal ? MSLPreamble.internalUniforms[name] : nil) {
            let code = "_c.md_u.\(path)"
            return Value(code: type.isMatrix ? "md_rot(\(code))" : code, type: type)
        }
        if let texture = try textureRef(name) { return Value(code: name, type: .texture2D, texture: texture) }
        if name.hasPrefix("texsize_") {
            let base = String(name.dropFirst(8))
            let declared = declaredSamplers.compactMap(Self.parseSampler).first { $0.base == base }
            let index = try userTexture(UserTexture(name: base, wrap: declared?.wrap ?? true, filter: declared?.filter ?? true), anyFlags: true)
            return Value(code: "_c.md_u.texsize_user[\(index)]", type: .vector(.float, 4))
        }
        throw HLSLError("unknown name '\(name)'", line: line)
    }

    // MARK: Textures

    private static func parseSampler(_ name: String) -> (base: String, wrap: Bool, filter: Bool, mode: String?)? {
        guard name.hasPrefix("sampler_") else { return nil }
        var base = String(name.dropFirst(8))
        var mode: String?
        if let p = ["fw_", "fc_", "pw_", "pc_"].first(where: base.hasPrefix) {
            mode = String(p.prefix(2))
            base = String(base.dropFirst(3))
        }
        return (base, mode.map { $0.hasSuffix("w") } ?? true, mode.map { $0.hasPrefix("f") } ?? true, mode)
    }

    /// Texture and sampler expressions for `sampler_xxx`, registering user textures and blur use.
    private func textureRef(_ name: String) throws -> (texture: String, sampler: String)? {
        guard let (base, wrap, filter, mode) = Self.parseSampler(name) else { return nil }
        let builtin = base == "noise_lq_lite" ? "noise_lq" : base
        if let t = MSLPreamble.textures.first(where: { $0.name == builtin }) {
            if builtin.hasPrefix("blur") { blurLevel = max(blurLevel, Int(builtin.suffix(1)) ?? 0) }
            return ("_c.md_\(builtin)", mode.map { "md_\($0)" } ?? t.sampler)
        }
        let index = try userTexture(UserTexture(name: base, wrap: wrap, filter: filter), anyFlags: false)
        return ("_c.md_user\(index)", "md_\(filter ? "f" : "p")\(wrap ? "w" : "c")")
    }

    private func userTexture(_ texture: UserTexture, anyFlags: Bool) throws -> Int {
        if let i = userTextures.firstIndex(where: { $0 == texture || (anyFlags && $0.name == texture.name) }) { return i }
        guard userTextures.count < MSLPreamble.maxUserTextures else { throw HLSLError("too many textures") }
        userTextures.append(texture)
        return userTextures.count - 1
    }

    func is3D(_ texture: String) -> Bool { texture.hasPrefix("_c.md_noisevol") }

    // MARK: Declarations

    private func global(_ decl: VarDecl) throws {
        for d in decl.declarators {
            if decl.type == .texture2D || decl.type == .texture3D {
                if d.name.hasPrefix("sampler_") { declaredSamplers.append(d.name) }
                continue
            }
            // Declarations of the built-in uniforms and texture sizes are already in the preamble.
            if MSLPreamble.uniforms[d.name] != nil || d.name.hasPrefix("texsize_") { continue }
            let type = try arrayType(decl.type, d)
            let name = mslName(d.name)
            members.append("\(type.msl) \(name)\(arraySuffix(type));")
            scopes = [[:]]
            if let initial = d.initializer {
                if case .array(let elem, _) = type {
                    for (i, code) in try arrayElements(initial, type, elem).enumerated() { globalInits.append("_c.\(name)[\(i)] = \(code);") }
                } else {
                    globalInits.append("_c.\(name) = \(try initializer(initial, type));")
                }
            }
            scopes = []
            globals[d.name] = (type, "_c.\(name)")
        }
    }

    private func arrayType(_ type: HType, _ d: Declarator) throws -> HType {
        guard let size = d.arraySize else { return type }
        guard case .number(let text, _) = size, var n = Int(text) else { throw HLSLError("array size must be a number", line: d.line) }
        if n == 0, case .list(let items)? = d.initializer { n = items.count }
        return .array(type, n)
    }

    private func arraySuffix(_ type: HType) -> String {
        if case .array(_, let n) = type { "[\(n)]" } else { "" }
    }

    /// Code of an initializer for `type`; `{ ... }` lists may be flat or nested.
    func initializer(_ e: Expr, _ type: HType) throws -> String {
        if case .array(let elem, _) = type { return "{" + (try arrayElements(e, type, elem)).joined(separator: ", ") + "}" }
        guard case .list(let items) = e else { return try convert(try expr(e), to: type).code }
        var scalars = try items.flatMap(flatten)[...]
        return try build(type, from: &scalars)
    }

    private func arrayElements(_ e: Expr, _ type: HType, _ elem: HType) throws -> [String] {
        guard case .list(let items) = e, case .array(_, let n) = type else { throw HLSLError("array needs a { } initializer") }
        if items.count == n { return try items.map { try initializer($0, elem) } }
        var scalars = try items.flatMap(flatten)[...]
        return try (0..<n).map { _ in try build(elem, from: &scalars) }
    }

    private func flatten(_ e: Expr) throws -> [Value] {
        if case .list(let items) = e { return try items.flatMap(flatten) }
        return components(try expr(e))
    }

    private func build(_ type: HType, from scalars: inout ArraySlice<Value>) throws -> String {
        let count = type.isMatrix ? matrixCount(type) : type.size
        guard count > 0, scalars.count >= count else { throw HLSLError("initializer has too few values") }
        let parts = try scalars.prefix(count).map { try convert($0, to: .scalar(type.kind ?? .float)).code }
        scalars = scalars.dropFirst(count)
        return count == 1 ? parts[0] : "\(type.msl)(\(parts.joined(separator: ", ")))"
    }

    func matrixCount(_ type: HType) -> Int {
        if case .matrix(_, let r, let c) = type { r * c } else { 0 }
    }

    // MARK: Functions

    private func function(_ decl: FuncDecl) throws {
        let msl = "fn_" + decl.name
        functions[decl.name, default: []].append(Function(decl: decl, msl: msl))
        let params = ["thread MDContext& _c"] + decl.params.map { p in
            let ref = p.qualifiers.contains("out") || p.qualifiers.contains("inout")
            return "\(ref ? "thread " : "")\(p.type.msl)\(ref ? "&" : "") \(mslName(p.name))\(arraySuffix(p.type))"
        }
        let header = "\(decl.returnType.msl) \(msl)(\(params.joined(separator: ", ")))"
        guard let body = decl.body else {
            functionCode.append(header + ";")
            return
        }
        scopes = [Dictionary(decl.params.map { ($0.name, ($0.type, mslName($0.name))) }, uniquingKeysWith: { a, _ in a })]
        returnType = decl.returnType
        let code = try body.map { try stmt($0, "    ") }.joined()
        scopes = []
        returnType = nil
        functionCode.append("\(header) {\n\(code)}\n")
    }

    private func shaderBody(_ body: [Stmt]) throws {
        let inputs: [(String, HType)] = [("uv", .vector(.float, 2)), ("uv_orig", .vector(.float, 2)), ("rad", .float), ("ang", .float),
                                         ("hue_shader", .vector(.float, 3)), ("ret", .vector(.float, 3))]
        scopes = [Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, ($0.1, $0.0)) })]
        bodyCode = try body.map { try stmt($0, "    ") }.joined()
        scopes = []
    }

    // MARK: Statements

    private func stmt(_ s: Stmt, _ indent: String) throws -> String {
        switch s {
        case .block(let items):
            scopes.append([:])
            defer { scopes.removeLast() }
            return "\(indent){\n" + (try items.map { try stmt($0, indent + "    ") }.joined()) + "\(indent)}\n"
        case .decl, .expr:
            return indent + (try inline(s)) + ";\n"
        case .ifElse(let cond, let then, let other):
            var code = "\(indent)if (\(try expr(cond).code))\n" + (try nested(then, indent))
            if let other { code += "\(indent)else\n" + (try nested(other, indent)) }
            return code
        case .forLoop(let initial, let cond, let step, let body):
            scopes.append([:])
            defer { scopes.removeLast() }
            let parts = [try initial.map(inline) ?? "", try cond.map { try expr($0).code } ?? "", try step.map { try expr($0, statement: true).code } ?? ""]
            return "\(indent)for (\(parts.joined(separator: "; ")))\n" + (try nested(body, indent))
        case .whileLoop(let cond, let body):
            return "\(indent)while (\(try expr(cond).code))\n" + (try nested(body, indent))
        case .doWhile(let body, let cond):
            return "\(indent)do\n" + (try nested(body, indent)) + "\(indent)while (\(try expr(cond).code));\n"
        case .ret(let value):
            guard let returnType else { return "\(indent)return float4(ret, md_in.color.a);\n" }
            guard let value else { return "\(indent)return;\n" }
            return "\(indent)return \(try convert(try expr(value), to: returnType).code);\n"
        case .breakLoop: return "\(indent)break;\n"
        case .continueLoop: return "\(indent)continue;\n"
        case .discard: return "\(indent)discard_fragment();\n"
        case .empty: return ""
        }
    }

    /// A statement in its own scope, always in braces.
    private func nested(_ s: Stmt, _ indent: String) throws -> String {
        if case .block = s { return try stmt(s, indent) }
        return try stmt(.block([s]), indent)
    }

    /// A declaration or expression statement without the `;`.
    private func inline(_ s: Stmt) throws -> String {
        switch s {
        case .expr(let e): return try expr(e, statement: true).code
        case .decl(let decl):
            var parts: [String] = []
            for d in decl.declarators {
                let type = try arrayType(decl.type, d)
                let name = mslName(d.name)
                let initial = try d.initializer.map { try initializer($0, type) } ?? zero(type)
                parts.append("\(name)\(arraySuffix(type)) = \(initial)")
                scopes[scopes.count - 1][d.name] = (type, name)
            }
            return "\(decl.qualifiers.contains("const") ? "const " : "")\(decl.type.msl) " + parts.joined(separator: ", ")
        default: throw HLSLError("unexpected statement")
        }
    }

    private func zero(_ type: HType) -> String {
        if case .array = type { return "{}" }
        return "\(type.msl)(0)"
    }

    // MARK: Output

    private func assemble() -> String {
        let builtinTextures = MSLPreamble.textures.map { "texture\($0.is3D ? "3d" : "2d")<float> md_\($0.name);" }
        let userTextureMembers = userTextures.indices.map { "texture2d<float> md_user\($0);" }
        let contextMembers = ["constant ShaderUniforms& md_u;", "sampler md_smain;"] + builtinTextures + userTextureMembers + members
        let textureParams = MSLPreamble.textures.enumerated().map { i, t in "texture\(t.is3D ? "3d" : "2d")<float> md_\(t.name) [[texture(\(i))]]" }
            + userTextures.indices.map { "texture2d<float> md_user\($0) [[texture(\(MSLPreamble.textures.count + $0))]]" }
        let params = ["MDVaryings md_in [[stage_in]]", "constant ShaderUniforms& md_u [[buffer(1)]]"] + textureParams + ["sampler md_smain [[sampler(0)]]"]
        let contextValues = ["md_u", "md_smain"] + MSLPreamble.textures.map { "md_\($0.name)" } + userTextures.indices.map { "md_user\($0)" }
        let lines = [
            "MDContext _c = {\(contextValues.joined(separator: ", "))};",
        ] + globalInits + [
            "float2 uv = md_in.uv;",
            "float2 uv_orig = md_in.uv_orig;",
            // Per pixel, as butterchurn: from the vertices, ang would smear across the atan2 seam (center to top).
            "float rad = length(uv_orig - 0.5);",
            "float ang = atan2(uv_orig.x - 0.5, uv_orig.y - 0.5);",
            "float3 hue_shader = md_in.color.rgb;",
            "float3 ret = float3(0);",
        ]
        return MSLPreamble.source
            + "struct MDContext {\n" + contextMembers.map { "    \($0)\n" }.joined() + "};\n\n"
            + functionCode.joined(separator: "\n") + "\n"
            + "fragment float4 md_fragment(\(params.joined(separator: ",\n    "))) {\n"
            + lines.map { "    \($0)\n" }.joined()
            + bodyCode
            + "    return float4(ret, md_in.color.a);\n}\n"
    }

    // MARK: Function lookup

    /// The user function `name` that takes `count` arguments.
    func userFunction(_ name: String, count: Int) -> (FuncDecl, String)? {
        guard let f = functions[name]?.last(where: { $0.decl.params.count == count }) else { return nil }
        return (f.decl, f.msl)
    }
}
