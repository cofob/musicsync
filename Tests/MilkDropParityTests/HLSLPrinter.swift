@testable import MilkDropKit

/// Prints a parsed shader back as HLSL with every operation in parentheses. butterchurn's converter loses the
/// second operator of a chain (`a + b + c` comes out as `(a + b) && c`); with parentheses it gets them right.
enum HLSLPrinter {
    /// The shader with full parentheses, or nil when it does not parse.
    static func parenthesized(_ hlsl: String) -> String? {
        guard !hlsl.isEmpty, let program = try? HLSLParser.parse(hlsl) else { return nil }
        return program.map { item -> String in
            switch item {
            case .variable(var d) where d.type == .texture2D || d.type == .texture3D:
                // The converter declares its own samplers, and makes a GLSL uniform only of a `uniform` one.
                d.declarators.removeAll { builtinSamplers.contains($0.name) }
                d.qualifiers.insert("uniform")
                return d.declarators.isEmpty ? "" : decl(d) + ";"
            case .variable(let d): return decl(d) + ";"
            case .function(let f):
                return "\(type(f.returnType)) \(f.name)(\(f.params.map(param).joined(separator: ", ")))"
                    + (f.body.map { " " + block($0) } ?? ";")
            case .shaderBody(let body): return "shader_body " + block(body)
            }
        }.joined(separator: "\n")
    }

    /// Samplers the converter declares itself.
    static let builtinSamplers: Set = ["sampler_main", "sampler_fw_main", "sampler_pw_main", "sampler_fc_main", "sampler_pc_main",
                                       "sampler_noise_lq", "sampler_noise_lq_lite", "sampler_noise_mq", "sampler_noise_hq",
                                       "sampler_noisevol_lq", "sampler_noisevol_hq", "sampler_pw_noise_lq",
                                       "sampler_blur1", "sampler_blur2", "sampler_blur3"]

    static func type(_ t: HType) -> String {
        switch t {
        case .void: "void"
        case .scalar(let k): k.msl
        case .vector(let k, let n): "\(k.msl)\(n)"
        case .matrix(let k, let r, let c): "\(k.msl)\(r)x\(c)"
        case .texture2D: "sampler"
        case .texture3D: "sampler3D"
        case .array(let t, _): type(t)
        }
    }

    static func param(_ p: Param) -> String {
        let size = if case .array(_, let n) = p.type { "[\(n)]" } else { "" }
        return (p.qualifiers.sorted() + [type(p.type), p.name + size]).joined(separator: " ")
    }

    static func decl(_ d: VarDecl) -> String {
        let names = d.declarators.map { v in
            v.name + (v.arraySize.map { "[\(expr($0))]" } ?? "") + (v.initializer.map { " = " + expr($0) } ?? "")
        }
        return (d.qualifiers.sorted() + [type(d.type), names.joined(separator: ", ")]).joined(separator: " ")
    }

    static func block(_ body: [Stmt]) -> String { "{\n" + body.map(stmt).joined(separator: "\n") + "\n}" }

    static func stmt(_ s: Stmt) -> String {
        switch s {
        case .block(let body): block(body)
        case .decl(let d): decl(d) + ";"
        case .expr(let e): top(e) + ";"
        case .ifElse(let c, let a, let b): "if (\(expr(c))) \(stmt(a))" + (b.map { " else " + stmt($0) } ?? "")
        case .forLoop(let i, let c, let step, let body):
            "for (\(i.map(stmt) ?? ";") \(c.map(expr) ?? ""); \(step.map(top) ?? "")) \(stmt(body))"
        case .whileLoop(let c, let body): "while (\(expr(c))) \(stmt(body))"
        case .doWhile(let body, let c): "do \(stmt(body)) while (\(expr(c)));"
        case .ret(let e): "return" + (e.map { " " + expr($0) } ?? "") + ";"
        case .breakLoop: "break;"
        case .continueLoop: "continue;"
        case .discard: "discard;"
        case .empty: ";"
        }
    }

    /// A statement-level expression: assignments and comma lists without the outer parentheses.
    static func top(_ e: Expr) -> String {
        switch e {
        case .assign(let op, let l, let r): "\(expr(l)) \(op) \(expr(r))"
        case .comma(let a, let b): "\(top(a)), \(top(b))"
        default: expr(e)
        }
    }

    static func expr(_ e: Expr) -> String {
        switch e {
        case .number(let text, _): text
        case .bool(let b): b ? "true" : "false"
        case .ident(let name, _): name
        case .call(let name, let args, _): "\(name)(\(args.map(expr).joined(separator: ", ")))"
        case .cast(let t, let x): "((\(type(t)))\(expr(x)))"
        case .member(.number(let n, _), let name): "(\(n)).\(name)"
        case .member(let x, let name): "\(expr(x)).\(name)"
        case .index(let x, let i): "\(expr(x))[\(expr(i))]"
        case .unary(let op, let x): "(\(op)\(expr(x)))"
        case .postfix(let op, let x): "(\(expr(x))\(op))"
        case .binary(let op, let a, let b): "(\(expr(a)) \(op) \(expr(b)))"
        case .assign: "(\(top(e)))"
        case .ternary(let c, let a, let b): "(\(expr(c)) ? \(expr(a)) : \(expr(b)))"
        case .comma: "(\(top(e)))"
        case .list(let items): "{\(items.map(expr).joined(separator: ", "))}"
        }
    }
}
