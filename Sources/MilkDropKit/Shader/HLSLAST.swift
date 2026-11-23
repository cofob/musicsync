/// Scalar element kind. `half` and `double` read as `float`.
enum ScalarKind: Equatable, Sendable {
    case float, int, uint, bool

    var msl: String {
        switch self {
        case .float: "float"
        case .int: "int"
        case .uint: "uint"
        case .bool: "bool"
        }
    }
}

/// An HLSL type. Matrices keep HLSL rows × columns.
indirect enum HType: Equatable, Sendable {
    case void
    case scalar(ScalarKind)
    case vector(ScalarKind, Int)
    case matrix(ScalarKind, rows: Int, cols: Int)
    case texture2D
    case texture3D
    case array(HType, Int)

    static let float = HType.scalar(.float)

    static func make(_ kind: ScalarKind, _ size: Int) -> HType { size == 1 ? .scalar(kind) : .vector(kind, size) }

    var kind: ScalarKind? {
        switch self {
        case .scalar(let k), .vector(let k, _), .matrix(let k, _, _): k
        default: nil
        }
    }

    /// Vector size: 1 for scalars, 0 for other types.
    var size: Int {
        switch self {
        case .scalar: 1
        case .vector(_, let n): n
        default: 0
        }
    }

    var isNumeric: Bool { size > 0 }
    var isMatrix: Bool { if case .matrix = self { true } else { false } }

    /// Same shape with another element kind.
    func with(_ kind: ScalarKind) -> HType {
        switch self {
        case .scalar: .scalar(kind)
        case .vector(_, let n): .vector(kind, n)
        case .matrix(_, let r, let c): .matrix(kind, rows: r, cols: c)
        default: self
        }
    }

    /// MSL spelling. An HLSL RxC matrix is stored transposed, as the MSL `floatRxC` (R columns of C rows),
    /// so constructors keep their argument order and `mul(a, b)` becomes `b * a`.
    var msl: String {
        switch self {
        case .void: "void"
        case .scalar(let k): k.msl
        case .vector(let k, let n): "\(k.msl)\(n)"
        case .matrix(let k, let r, let c): "\(k == .float ? "float" : k.msl)\(r)x\(c)"
        case .texture2D: "texture2d<float>"
        case .texture3D: "texture3d<float>"
        case .array(let t, _): t.msl
        }
    }

    /// Parses a type keyword such as `float3`, `half2x2`, `int`, `sampler2D`.
    init?(keyword: String) {
        switch keyword {
        case "void": self = .void
        case "sampler", "sampler2D", "texture", "texture2D": self = .texture2D
        case "sampler3D", "texture3D": self = .texture3D
        default:
            let bases: [(String, ScalarKind)] = [("float", .float), ("half", .float), ("double", .float), ("int", .int), ("uint", .uint), ("bool", .bool), ("dword", .uint)]
            guard let (base, kind) = bases.first(where: { keyword.hasPrefix($0.0) }) else { return nil }
            let rest = keyword.dropFirst(base.count)
            if rest.isEmpty { self = .scalar(kind); return }
            let digits = rest.split(separator: "x").compactMap { Int($0) }
            guard digits.allSatisfy({ (1...4).contains($0) }) else { return nil }
            if digits.count == 1, !rest.contains("x") {
                self = .make(kind, digits[0])
            } else if digits.count == 2 {
                self = .matrix(kind, rows: digits[0], cols: digits[1])
            } else {
                return nil
            }
        }
    }
}

indirect enum Expr {
    case number(String, line: Int)
    case bool(Bool)
    case ident(String, line: Int)
    /// A function, intrinsic or constructor call.
    case call(String, [Expr], line: Int)
    case cast(HType, Expr)
    case member(Expr, String)
    case index(Expr, Expr)
    case unary(String, Expr)
    case postfix(String, Expr)
    case binary(String, Expr, Expr)
    case assign(String, Expr, Expr)
    case ternary(Expr, Expr, Expr)
    case comma(Expr, Expr)
    /// `{ a, b, ... }` initializer.
    case list([Expr])
}

struct Declarator {
    var name: String
    var arraySize: Expr?
    var initializer: Expr?
    var line: Int
}

struct VarDecl {
    var qualifiers: Set<String>
    var type: HType
    var declarators: [Declarator]
}

indirect enum Stmt {
    case block([Stmt])
    case decl(VarDecl)
    case expr(Expr)
    case ifElse(Expr, Stmt, Stmt?)
    case forLoop(Stmt?, Expr?, Expr?, Stmt)
    case whileLoop(Expr, Stmt)
    case doWhile(Stmt, Expr)
    case ret(Expr?)
    case breakLoop, continueLoop, discard, empty
}

struct Param {
    var qualifiers: Set<String>
    var type: HType
    var name: String
}

struct FuncDecl {
    var returnType: HType
    var name: String
    var params: [Param]
    var body: [Stmt]?
    var line: Int
}

enum TopLevel {
    case function(FuncDecl)
    case variable(VarDecl)
    case shaderBody([Stmt])
}
