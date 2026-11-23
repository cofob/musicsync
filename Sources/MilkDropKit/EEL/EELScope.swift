import Foundation

/// One variable namespace (MilkDrop: the main preset, each custom wave, each custom shape has its own).
public final class EELScope {
    private let memory: EELMemory
    private let globals: EELGlobals
    private let random: () -> Double
    private var slots: [String: Int] = [:]
    private var vars: UnsafeMutablePointer<Double>
    private var count = 0, capacity = 64
    private var stack: UnsafeMutablePointer<Double>
    private var stackCapacity = 64

    public init(memory: EELMemory, globals: EELGlobals, random: @escaping () -> Double = { .random(in: 0..<1) }) {
        self.memory = memory
        self.globals = globals
        self.random = random
        vars = .allocate(capacity: capacity)
        stack = .allocate(capacity: stackCapacity)
    }

    deinit {
        vars.deallocate()
        stack.deallocate()
    }

    /// Slot of a variable; names are case-insensitive. Creates the slot if new. regNN names go to the globals
    /// and get negative slots.
    public func slot(_ name: String) -> Int {
        let name = name.lowercased()
        if let slot = slots[name] { return slot }
        if name.count == 5, name.hasPrefix("reg"), let n = Int(name.dropFirst(3)), n >= 0 { return -1 - n }
        if count == capacity {
            let bigger = UnsafeMutablePointer<Double>.allocate(capacity: capacity * 2)
            bigger.moveInitialize(from: vars, count: count)
            vars.deallocate()
            vars = bigger
            capacity *= 2
        }
        vars[count] = 0
        slots[name] = count
        count += 1
        return count - 1
    }

    public subscript(slot: Int) -> Double {
        get { slot >= 0 ? vars[slot] : globals.regs[-1 - slot] }
        set {
            if slot >= 0 { vars[slot] = newValue } else { globals.regs[-1 - slot] = newValue }
        }
    }

    public subscript(name: String) -> Double {
        get { self[slot(name)] }
        set { self[slot(name)] = newValue }
    }

    /// Whole statements text; `;` separated, `//` and `/* */` comments allowed. Throws EELError with a message.
    public func compile(_ source: String) throws -> EELProgram {
        var parser = try EELParser(source, resolve: slot)
        return EELCompiler.compile(try parser.parseProgram())
    }

    /// Joins the code lines of one .milk block (`per_frame_1`, `per_frame_2`...) as MilkDrop and butterchurn do:
    /// drops each line's `//` comment, trims it, and joins with no separator, since old editors wrapped long lines
    /// in the middle of names.
    public static func joinCodeLines(_ lines: [String]) -> String {
        lines.map { line in
            let code = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line[...]
            return code.trimmingCharacters(in: .whitespaces)
        }.joined()
    }

    /// Copy of all variable values (regNN not included).
    public func snapshot() -> [Double] { Array(UnsafeBufferPointer(start: vars, count: count)) }

    /// Puts back the values of a `snapshot()`.
    public func restore(_ values: [Double]) {
        values.withUnsafeBufferPointer {
            if let base = $0.baseAddress { vars.update(from: base, count: min($0.count, count)) }
        }
    }

    public func run(_ program: EELProgram) {
        guard !program.isEmpty else { return }
        precondition(program.slotCount <= count, "EELProgram run on a scope that did not compile it")
        if stackCapacity < program.stackSize {
            stack.deallocate()
            stackCapacity = program.stackSize
            stack = .allocate(capacity: stackCapacity)
        }
        program.code.withUnsafeBufferPointer { execute($0.baseAddress!, $0.count) }
    }

    private func execute(_ code: UnsafePointer<EELInstruction>, _ end: Int) {
        let v = vars, s = stack, r = globals.regs, mem = memory, gmem = globals.gmegabuf
        var pc = 0, sp = -1
        while pc < end {
            let i = code[pc]
            pc += 1
            switch i.op {
            case .push: sp += 1; s[sp] = i.value
            case .load: sp += 1; s[sp] = v[Int(i.arg)]
            case .loadReg: sp += 1; s[sp] = r[Int(i.arg)]
            case .loadMem: s[sp] = mem[s[sp]]
            case .loadGMem: s[sp] = gmem[s[sp]]
            case .dup: sp += 1; s[sp] = s[sp - 1]
            case .store: v[Int(i.arg)] = s[sp]
            case .storeReg: r[Int(i.arg)] = s[sp]
            case .storeMem: sp -= 1; mem[s[sp]] = s[sp + 1]; s[sp] = s[sp + 1]
            case .storeGMem: sp -= 1; gmem[s[sp]] = s[sp + 1]; s[sp] = s[sp + 1]
            case .storePop: v[Int(i.arg)] = s[sp]; sp -= 1
            case .storeRegPop: r[Int(i.arg)] = s[sp]; sp -= 1
            case .pop: sp -= 1
            case .neg: s[sp] = -s[sp]
            case .not: s[sp] = EELMath.bool(!EELMath.isTrue(s[sp]))
            case .truth: s[sp] = EELMath.bool(EELMath.isTrue(s[sp]))
            case .sin: s[sp] = Foundation.sin(s[sp])
            case .cos: s[sp] = Foundation.cos(s[sp])
            case .tan: s[sp] = Foundation.tan(s[sp])
            case .asin: s[sp] = Foundation.asin(s[sp])
            case .acos: s[sp] = Foundation.acos(s[sp])
            case .atan: s[sp] = Foundation.atan(s[sp])
            case .exp: s[sp] = Foundation.exp(s[sp])
            case .log: s[sp] = Foundation.log(s[sp])
            case .log10: s[sp] = Foundation.log10(s[sp])
            case .sqrt: s[sp] = Foundation.sqrt(Swift.abs(s[sp]))
            case .sqr: s[sp] *= s[sp]
            case .abs: s[sp] = Swift.abs(s[sp])
            case .sign: s[sp] = EELMath.sign(s[sp])
            case .floor: s[sp].round(.down)
            case .ceil: s[sp].round(.up)
            case .invsqrt: s[sp] = 1 / Foundation.sqrt(Swift.abs(s[sp]))
            case .rand: s[sp] = EELMath.rand(s[sp], random)
            case .add: sp -= 1; s[sp] += s[sp + 1]
            case .sub: sp -= 1; s[sp] -= s[sp + 1]
            case .mul: sp -= 1; s[sp] *= s[sp + 1]
            case .div: sp -= 1; s[sp] = EELMath.div(s[sp], s[sp + 1])
            case .mod: sp -= 1; s[sp] = EELMath.mod(s[sp], s[sp + 1])
            case .pow: sp -= 1; s[sp] = EELMath.pow(s[sp], s[sp + 1])
            case .bitAnd: sp -= 1; s[sp] = Double(EELMath.int32(s[sp]) & EELMath.int32(s[sp + 1]))
            case .bitOr: sp -= 1; s[sp] = Double(EELMath.int32(s[sp]) | EELMath.int32(s[sp + 1]))
            case .eq: sp -= 1; s[sp] = EELMath.bool(Swift.abs(s[sp] - s[sp + 1]) < EELMath.epsilon)
            case .ne: sp -= 1; s[sp] = EELMath.bool(Swift.abs(s[sp] - s[sp + 1]) >= EELMath.epsilon)
            case .lt: sp -= 1; s[sp] = EELMath.bool(s[sp] < s[sp + 1])
            case .gt: sp -= 1; s[sp] = EELMath.bool(s[sp] > s[sp + 1])
            case .le: sp -= 1; s[sp] = EELMath.bool(s[sp] <= s[sp + 1])
            case .ge: sp -= 1; s[sp] = EELMath.bool(s[sp] >= s[sp + 1])
            case .min: sp -= 1; s[sp] = Swift.min(s[sp], s[sp + 1])
            case .max: sp -= 1; s[sp] = Swift.max(s[sp], s[sp + 1])
            case .atan2: sp -= 1; s[sp] = Foundation.atan2(s[sp], s[sp + 1])
            case .sigmoid: sp -= 1; s[sp] = EELMath.sigmoid(s[sp], s[sp + 1])
            case .band: sp -= 1; s[sp] = EELMath.bool(EELMath.isTrue(s[sp]) && EELMath.isTrue(s[sp + 1]))
            case .bor: sp -= 1; s[sp] = EELMath.bool(EELMath.isTrue(s[sp]) || EELMath.isTrue(s[sp + 1]))
            case .addK: s[sp] += i.value
            case .subK: s[sp] -= i.value
            case .mulK: s[sp] *= i.value
            case .divK: s[sp] = EELMath.div(s[sp], i.value)
            case .addV: s[sp] += v[Int(i.arg)]
            case .subV: s[sp] -= v[Int(i.arg)]
            case .mulV: s[sp] *= v[Int(i.arg)]
            case .divV: s[sp] = EELMath.div(s[sp], v[Int(i.arg)])
            case .memcpy: sp -= 2; s[sp] = mem.copy(to: s[sp], from: s[sp + 1], count: s[sp + 2])
            case .memset: sp -= 2; s[sp] = mem.fill(s[sp], value: s[sp + 1], count: s[sp + 2])
            case .jump: pc = Int(i.arg)
            case .jumpIfFalse: if !EELMath.isTrue(s[sp]) { pc = Int(i.arg) }; sp -= 1
            case .jumpIfTrue: if EELMath.isTrue(s[sp]) { pc = Int(i.arg) }; sp -= 1
            case .and: if EELMath.isTrue(s[sp]) { sp -= 1 } else { s[sp] = 0; pc = Int(i.arg) }
            case .or: if EELMath.isTrue(s[sp]) { s[sp] = 1; pc = Int(i.arg) } else { sp -= 1 }
            case .loopStart: s[sp] = s[sp] >= 1 ? Swift.min(s[sp].rounded(.down), EELCompiler.maxIterations) : 0
            case .loopNext: if s[sp] >= 1 { s[sp] -= 1 } else { pc = Int(i.arg) }
            case .zero: s[sp] = 0
            }
        }
    }
}
