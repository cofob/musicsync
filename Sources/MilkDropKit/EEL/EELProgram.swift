/// Compiled EEL code. Run it only on the scope that compiled it.
public struct EELProgram: Sendable {
    let code: [EELInstruction]
    /// Highest value stack depth the code needs.
    let stackSize: Int
    /// One more than the highest variable slot the code uses.
    let slotCount: Int

    public var isEmpty: Bool { code.isEmpty }
}

/// A compile error, with the line in the message.
public struct EELError: Error, CustomStringConvertible {
    public let message: String

    init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// Operations of the stack machine. `arg` is a slot, register or jump target; `value` a constant.
enum EELOp: UInt8, Sendable {
    case push, load, loadReg, loadMem, loadGMem, dup
    /// Store the top of the stack and keep it there.
    case store, storeReg, storeMem, storeGMem
    /// Store the top of the stack and pop it.
    case storePop, storeRegPop
    case pop
    case neg, not, truth, sin, cos, tan, asin, acos, atan, exp, log, log10, sqrt, sqr, abs, sign, floor, ceil, invsqrt, rand
    case add, sub, mul, div, mod, pow, bitAnd, bitOr, eq, ne, lt, gt, le, ge, min, max, atan2, sigmoid, band, bor
    /// `add`... with the right operand fused in: the constant `value` (K) or the variable at `arg` (V).
    case addK, subK, mulK, divK, addV, subV, mulV, divV
    case memcpy, memset
    case jump, jumpIfFalse, jumpIfTrue
    /// Short-circuit `&&` / `||`: when the top decides the result, set it to 0 / 1 and jump; else pop it.
    case and, or
    /// Turn the top into a loop count; `loopNext` counts it down or jumps out when it is used up.
    case loopStart, loopNext
    /// Replace the top with 0.
    case zero

    /// How the op changes the stack depth (on the path that does not jump).
    var stackEffect: Int {
        switch self {
        case .push, .load, .loadReg, .dup: 1
        case .storeMem, .storeGMem, .storePop, .storeRegPop, .pop, .jumpIfFalse, .jumpIfTrue, .and, .or: -1
        case .add, .sub, .mul, .div, .mod, .pow, .bitAnd, .bitOr, .eq, .ne, .lt, .gt, .le, .ge, .min, .max, .atan2,
             .sigmoid, .band, .bor: -1
        case .memcpy, .memset: -2
        default: 0
        }
    }
}

struct EELInstruction: Sendable {
    var op: EELOp
    var arg: Int32 = 0
    var value: Double = 0
}

/// Turns a syntax tree into stack machine code.
struct EELCompiler {
    /// Most iterations of one `loop` or `while`, as in MilkDrop.
    static let maxIterations = 1_048_576.0

    private var code: [EELInstruction] = []
    private var depth = 0, maxDepth = 0, slotCount = 0
    /// Last jump target: the instruction there must stay, so no fusing across it.
    private var label = -1

    static func compile(_ node: EELNode) -> EELProgram {
        var compiler = EELCompiler()
        if case .sequence(let items) = node, items.isEmpty { return compiler.program }
        compiler.compile(node)
        compiler.emit(.pop)
        return compiler.program
    }

    private var program: EELProgram { EELProgram(code: code, stackSize: maxDepth, slotCount: slotCount) }

    private mutating func compile(_ node: EELNode) {
        switch node {
        case .number(let n):
            emit(.push, value: n)
        case .read(.variable(let slot)):
            emitSlot(slot, local: .load, reg: .loadReg)
        case .read(.memory(let index, let global)):
            compile(index)
            emit(global ? .loadGMem : .loadMem)
        case .assign(.variable(let slot), let op, let value):
            if op != nil { compile(.read(.variable(slot))) }
            compile(value)
            if let op { emit(op) }
            emitSlot(slot, local: .store, reg: .storeReg)
        case .assign(.memory(let index, let global), let op, let value):
            compile(index)
            if op != nil {
                emit(.dup)
                emit(global ? .loadGMem : .loadMem)
            }
            compile(value)
            if let op { emit(op) }
            emit(global ? .storeGMem : .storeMem)
        case .call(let op, let args):
            args.forEach { compile($0) }
            emit(op)
        case .and(let a, let b):
            shortCircuit(.and, a, b)
        case .or(let a, let b):
            shortCircuit(.or, a, b)
        case .select(let condition, let a, let b):
            compile(condition)
            let otherwise = emitJump(.jumpIfFalse)
            compile(a)
            let end = emitJump(.jump)
            depth -= 1
            place(otherwise)
            compile(b)
            place(end)
        case .sequence(let items):
            guard !items.isEmpty else { return emit(.push) }
            for (i, item) in items.enumerated() {
                compile(item)
                if i < items.count - 1 { emit(.pop) }
            }
        case .loop(let count, let body):
            compile(count)
            emit(.loopStart)
            loop { compiler in
                compiler.compile(body)
                compiler.emit(.pop)
                return .jump
            }
        case .whileLoop(let body):
            emit(.push, value: Self.maxIterations)
            loop { compiler in
                compiler.compile(body)
                return .jumpIfTrue
            }
        }
    }

    private mutating func shortCircuit(_ op: EELOp, _ a: EELNode, _ b: EELNode) {
        compile(a)
        let skip = emitJump(op)
        compile(b)
        emit(.truth)
        place(skip)
    }

    /// Loop around the counter on the top of the stack; `body` emits the code and names the jump back.
    private mutating func loop(_ body: (inout EELCompiler) -> EELOp) {
        let top = code.count
        label = top
        let exit = emitJump(.loopNext)
        let back = body(&self)
        emit(back, arg: top)
        place(exit)
        emit(.zero)
    }

    private mutating func emitSlot(_ slot: Int, local: EELOp, reg: EELOp) {
        if slot >= 0 {
            slotCount = Swift.max(slotCount, slot + 1)
            emit(local, arg: slot)
        } else {
            emit(reg, arg: -1 - slot)
        }
    }

    private mutating func emit(_ op: EELOp, arg: Int = 0, value: Double = 0) {
        depth += op.stackEffect
        maxDepth = Swift.max(maxDepth, depth)
        if op == .pop, label != code.count, let last = code.last, last.op == .store || last.op == .storeReg {
            code[code.count - 1].op = last.op == .store ? .storePop : .storeRegPop
            return
        }
        if let fused = Self.fused[op], label != code.count, let last = code.last, last.op == .push || last.op == .load {
            code[code.count - 1].op = last.op == .push ? fused.k : fused.v
            return
        }
        code.append(EELInstruction(op: op, arg: Int32(arg), value: value))
    }

    private static let fused: [EELOp: (k: EELOp, v: EELOp)] = [
        .add: (.addK, .addV), .sub: (.subK, .subV), .mul: (.mulK, .mulV), .div: (.divK, .divV),
    ]

    private mutating func emitJump(_ op: EELOp) -> Int {
        emit(op)
        return code.count - 1
    }

    private mutating func place(_ jump: Int) {
        code[jump].arg = Int32(code.count)
        label = code.count
    }
}
