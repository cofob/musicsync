/// Names of the variables a program writes to (assignment, `++`, `--`), found by walking the AST.
enum HLSLAssignments {
    static func names(_ program: [TopLevel]) -> Set<String> {
        var out: Set<String> = []
        for item in program {
            switch item {
            case .variable(let decl): decl.declarators.forEach { $0.initializer.map { visit($0, &out) } }
            case .function(let f): f.body?.forEach { visit($0, &out) }
            case .shaderBody(let body): body.forEach { visit($0, &out) }
            }
        }
        return out
    }

    private static func visit(_ s: Stmt, _ out: inout Set<String>) {
        switch s {
        case .block(let items): items.forEach { visit($0, &out) }
        case .decl(let decl): decl.declarators.forEach { $0.initializer.map { visit($0, &out) } }
        case .expr(let e), .ret(let e?): visit(e, &out)
        case .ifElse(let c, let a, let b):
            visit(c, &out)
            visit(a, &out)
            b.map { visit($0, &out) }
        case .forLoop(let i, let c, let step, let body):
            i.map { visit($0, &out) }
            c.map { visit($0, &out) }
            step.map { visit($0, &out) }
            visit(body, &out)
        case .whileLoop(let c, let body), .doWhile(let body, let c):
            visit(c, &out)
            visit(body, &out)
        default: break
        }
    }

    private static func visit(_ e: Expr, _ out: inout Set<String>) {
        switch e {
        case .assign(_, let l, let r):
            if let name = root(l) { out.insert(name) }
            visit(l, &out)
            visit(r, &out)
        case .unary(let op, let x) where op == "++" || op == "--":
            if let name = root(x) { out.insert(name) }
        case .postfix(_, let x):
            if let name = root(x) { out.insert(name) }
        case .call(_, let args, _), .list(let args): args.forEach { visit($0, &out) }
        case .cast(_, let x), .member(let x, _), .unary(_, let x): visit(x, &out)
        case .index(let a, let b), .binary(_, let a, let b), .comma(let a, let b):
            visit(a, &out)
            visit(b, &out)
        case .ternary(let c, let a, let b):
            visit(c, &out)
            visit(a, &out)
            visit(b, &out)
        case .number, .bool, .ident: break
        }
    }

    private static func root(_ e: Expr) -> String? {
        switch e {
        case .ident(let name, _): name
        case .member(let x, _), .index(let x, _): root(x)
        default: nil
        }
    }
}
