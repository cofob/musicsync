import Foundation
@testable import MilkDropKit
import Testing

/// A fresh scope that runs `code` once.
@discardableResult
private func run(_ code: String, scope: EELScope = EELScope(memory: EELMemory(), globals: EELGlobals(), random: { 0.5 })) throws -> EELScope {
    scope.run(try scope.compile(code))
    return scope
}

/// Value of one expression.
private func value(_ expression: String) throws -> Double {
    try run("result = \(expression);")["result"]
}

@Suite struct EELTests {
    @Test func namesAreCaseInsensitive() throws {
        let scope = try run("Foo = 2; foo = FOO * 3; Bar = 1")
        #expect(scope["fOO"] == 6)
        #expect(scope.slot("foo") == scope.slot("FOO"))
        #expect(scope["bar"] == 1)
    }

    @Test func unknownVariablesReadZero() throws {
        #expect(try value("nothing + 1") == 1)
    }

    @Test func numbers() throws {
        #expect(try value(".5") == 0.5)
        #expect(try value("1e3") == 1000)
        #expect(try value("2.5e-1") == 0.25)
        #expect(try value("3.") == 3)
        #expect(try value("007") == 7)
    }

    @Test func comments() throws {
        let scope = try run("a = 1; // a = 2;\nb = /* a = 3; */ 4;")
        #expect(scope["a"] == 1)
        #expect(scope["b"] == 4)
    }

    @Test func precedence() throws {
        #expect(try value("1 + 2 * 3") == 7)
        #expect(try value("10 - 4 - 3") == 3)
        #expect(try value("8 / 4 / 2") == 1)
        #expect(try value("(1 + 2) * 3") == 9)
        #expect(try value("2 * 3 ^ 2") == 18)
        #expect(try value("-2 ^ 2") == 4)
        #expect(try value("1 + 2 < 4") == 1)
        #expect(try value("1 < 2 && 3 < 2") == 0)
        #expect(try value("1 + 4 & 6") == 4)
    }

    @Test func unary() throws {
        #expect(try value("-(2 + 1)") == -3)
        #expect(try value("+3") == 3)
        #expect(try value("--3") == 3)
        #expect(try value("!0") == 1)
        #expect(try value("!0.5") == 0)
        #expect(try value("!0.000001") == 1)
    }

    @Test func equalityUsesEpsilon() throws {
        #expect(try value("1 == 1.000001") == 1)
        #expect(try value("1 == 1.0001") == 0)
        #expect(try value("1 != 1.000001") == 0)
        #expect(try value("1 != 1.0001") == 1)
        #expect(try value("equal(0.3, 0.1 + 0.2)") == 1)
    }

    @Test func comparisons() throws {
        #expect(try value("2 > 1") == 1)
        #expect(try value("2 < 1") == 0)
        #expect(try value("1 <= 1") == 1)
        #expect(try value("1 >= 2") == 0)
        #expect(try value("above(2, 1)") == 1)
        #expect(try value("below(2, 1)") == 0)
    }

    @Test func power() throws {
        #expect(try value("2 ^ 10") == 1024)
        #expect(try value("pow(2, 0.5)") == 2.0.squareRoot())
        #expect(try value("pow(-1, 0.5)") == 0)
        #expect(try value("pow(0, -1)") == 0)
        #expect(try run("x = 3; x ^= 2")["x"] == 9)
    }

    @Test func bitwise() throws {
        #expect(try value("6 & 3") == 2)
        #expect(try value("6 | 3") == 7)
        #expect(try value("6.9 | 1.5") == 7)
        #expect(try value("-1.5 & 255") == 254)
        #expect(try value("0 & (x * 3 - 2)") == 0)
    }

    @Test func divisionByZero() throws {
        #expect(try value("1 / 0") == 0)
        #expect(try value("7 / 2") == 3.5)
        #expect(try run("x = 5; x /= 0")["x"] == 0)
    }

    @Test func modulo() throws {
        #expect(try value("7 % 3") == 1)
        #expect(try value("7.9 % 3.9") == 1)
        #expect(try value("-7 % 3") == -1)
        #expect(try value("5 % 0") == 0)
        #expect(try value("5 % 0.5") == 0)
        #expect(try run("x = 10; x %= 4")["x"] == 2)
    }

    @Test func sqrtOfAbsoluteValue() throws {
        #expect(try value("sqrt(-9)") == 3)
        #expect(try value("sqrt(16)") == 4)
    }

    @Test func rand() throws {
        let scope = EELScope(memory: EELMemory(), globals: EELGlobals(), random: { 0.75 })
        try run("a = rand(10); b = rand(0.5); c = rand(1); d = rand(4.9)", scope: scope)
        #expect(scope["a"] == 7)
        #expect(scope["b"] == 0)
        #expect(scope["c"] == 0)
        #expect(scope["d"] == 3)
    }

    @Test func sigmoid() throws {
        #expect(try value("sigmoid(0, 1)") == 0.5)
        #expect(abs(try value("sigmoid(2, 3)") - 1 / (1 + exp(-6))) < 1e-12)
    }

    @Test func ternary() throws {
        #expect(try value("1 ? 2 : 3") == 2)
        #expect(try value("0 ? 2 : 3") == 3)
        #expect(try value("0.000001 ? 2 : 3") == 3)
        #expect(try value("0 ? 2") == 0)
        #expect(try value("1 ? 0 ? 4 : 5 : 6") == 5)
        #expect(try value("2 * (1 ? 3 : 4) + 2 * (0 ? 3 : 4)") == 14)
        #expect(try run("a = 3; b = 4; x = 2 * (1 ? a : b); y = 2 - (0 ? a : b)")["x"] == 6)
        #expect(try run("a = 3; b = 4; y = 2 - (0 ? a : b)")["y"] == -2)
        let scope = try run("c = 1; c ? a = 1 : b = 2")
        #expect(scope["a"] == 1)
        #expect(scope["b"] == 0)
    }

    @Test func ifIsLazy() throws {
        let scope = try run("x = if(1, a = 2, b = 3); y = if(0, c = 4, d = 5)")
        #expect(scope["x"] == 2 && scope["y"] == 5)
        #expect(scope["a"] == 2 && scope["b"] == 0 && scope["c"] == 0 && scope["d"] == 5)
        #expect(try run("x = IF(below(1, 2), 7, 8)")["x"] == 7)
    }

    @Test func ifArgumentsCanBeStatementLists() throws {
        let scope = try run("x = if(1, a = 1; b = 2; b + 1, 0);")
        #expect(scope["a"] == 1 && scope["b"] == 2 && scope["x"] == 3)
    }

    @Test func logicShortCircuits() throws {
        let scope = try run("x = 0 && (a = 1); y = 1 || (b = 1); z = 2 && 3; w = 0 || 0.5")
        #expect(scope["a"] == 0 && scope["b"] == 0)
        #expect(scope["x"] == 0 && scope["y"] == 1 && scope["z"] == 1 && scope["w"] == 1)
    }

    @Test func loop() throws {
        #expect(try run("n = 0; loop(5, n += 2)")["n"] == 10)
        #expect(try run("n = 0; loop(2.9, n += 1)")["n"] == 2)
        #expect(try run("n = 0; loop(-3, n += 1)")["n"] == 0)
        #expect(try run("n = 0; loop(3, loop(4, n += 1))")["n"] == 12)
        #expect(try run("n = 0; i = 0; loop(3, i += 1; n += i)")["n"] == 6)
    }

    @Test func whileRunsUntilFalse() throws {
        #expect(try run("i = 0; while(i += 1; i < 10)")["i"] == 10)
        #expect(try run("i = 0; while(exec2(i += 1, i < 3))")["i"] == 3)
        #expect(try run("i = 0; while(i = i + 1)")["i"] == 1_048_576)
    }

    @Test func exec() throws {
        #expect(try value("exec2(a = 1, a + 1)") == 2)
        #expect(try value("exec3(a = 1, b = a + 1, a + b)") == 3)
    }

    @Test func megabuf() throws {
        let memory = EELMemory()
        let globals = EELGlobals()
        let a = EELScope(memory: memory, globals: globals)
        let b = EELScope(memory: memory, globals: globals)
        try run("megabuf(10) = 5; megabuf(10.7) += 1; megabuf(8388607) = 2; megabuf(8388608) = 3; megabuf(-1) = 4", scope: a)
        try run("x = megabuf(10); y = megabuf(8388607); z = megabuf(8388608); w = megabuf(-1); u = megabuf(123456)", scope: b)
        #expect(b["x"] == 6 && b["y"] == 2 && b["z"] == 0 && b["w"] == 0 && b["u"] == 0)
        let other = EELScope(memory: EELMemory(), globals: globals)
        #expect(try run("x = megabuf(10)", scope: other)["x"] == 0)
    }

    @Test func gmegabufAndRegsAreGlobal() throws {
        let globals = EELGlobals()
        let a = EELScope(memory: EELMemory(), globals: globals)
        let b = EELScope(memory: EELMemory(), globals: globals)
        try run("gmegabuf(3) = 7; reg05 = 9; REG99 += 1", scope: a)
        try run("x = gmegabuf(3); y = reg05; z = reg99", scope: b)
        #expect(b["x"] == 7 && b["y"] == 9 && b["z"] == 1)
        #expect(a.slot("reg05") < 0 && b["reg05"] == 9)
        #expect(!a.snapshot().contains(9))
    }

    @Test func memcpyAndMemset() throws {
        let scope = try run("memset(0, 2, 4); megabuf(1) = 3; memcpy(1, 0, 3); x = megabuf(0) + megabuf(1) * 10 + megabuf(2) * 100 + megabuf(3) * 1000")
        #expect(scope["x"] == 2 + 20 + 300 + 2000)
        #expect(try value("freembuf(4)") == 4)
    }

    @Test func assignmentOperators() throws {
        let scope = try run("a = 1; a += 2; b = 10; b -= 4; c = 3; c *= 4; d = 9; d /= 3; e = f = 2")
        #expect(scope["a"] == 3 && scope["b"] == 6 && scope["c"] == 12 && scope["d"] == 3)
        #expect(scope["e"] == 2 && scope["f"] == 2)
        #expect(try value("2 * (y = 3) + y") == 9)
    }

    @Test func functions() throws {
        #expect(try value("int(-1.5)") == -2)
        #expect(try value("floor(1.7) + ceil(1.2)") == 3)
        #expect(try value("abs(-2) + sign(-3) + sign(0) + sign(4)") == 2)
        #expect(try value("min(2, 3) + max(2, 3)") == 5)
        #expect(try value("sqr(3)") == 9)
        #expect(try value("invsqrt(4)") == 0.5)
        #expect(try value("bnot(0) + bnot(2)") == 1)
        #expect(try value("band(1, 2) + band(1, 0) + bor(0, 0) + bor(0, 3)") == 2)
        #expect(try value("atan2(1, 1)") == atan2(1.0, 1.0))
        #expect(try value("log10(1000)") == 3)
        #expect(abs(try value("log(exp(2))") - 2) < 1e-12)
        #expect(try value("sin(0) + cos(0) + tan(0) + asin(0) + acos(1) + atan(0)") == 1)
    }

    @Test func internalOperatorNames() throws {
        #expect(try value("_aboeq(2, 2) + _beleq(3, 2) + _above(3, 2) + _below(3, 2)") == 2)
        #expect(try value("_equal(1, 1) + _noteq(1, 1) + _not(0) + _and(1, 2) + _or(0, 0)") == 3)
        #expect(try value("_if(0, 1, 2) + _mod(7, 4)") == 5)
        let scope = try run("_set(a, 2); assign(megabuf(3), a + 1); c = megabuf(3); b = assign(5, 4)")
        #expect(scope["a"] == 2 && scope["c"] == 3 && scope["b"] == 4)
    }

    @Test func loneDotIsZero() throws {
        #expect(try value(".-.4") == -0.4)
        #expect(try value("1 + . + 2") == 3)
    }

    @Test func errors() {
        for bad in ["x = (1 + 2", "x = foo(1)", "x = sin(1, 2)", "x = 1 +", "x = 1 $ 2", "if(1, 2)", "x = 1 y = 2"] {
            let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
            #expect(throws: EELError.self, "\(bad)") { try scope.compile(bad) }
        }
        let error = #expect(throws: EELError.self) { try EELScope(memory: EELMemory(), globals: EELGlobals()).compile("a = 1;\nb = (2") }
        #expect(error?.description.contains("line 2") == true)
    }

    @Test func emptyPrograms() throws {
        let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
        #expect(try scope.compile("").isEmpty)
        #expect(try scope.compile(" ;; // nothing\n").isEmpty)
        #expect(try !scope.compile("x = 1").isEmpty)
    }

    @Test func snapshotAndRestore() throws {
        let scope = try run("a = 1; b = 2")
        let saved = scope.snapshot()
        try run("a = 5; b = 6", scope: scope)
        scope.restore(saved)
        #expect(scope["a"] == 1 && scope["b"] == 2)
    }

    @Test func slotsAndSubscripts() throws {
        let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
        let x = scope.slot("x")
        scope[x] = 4
        let program = try scope.compile("y = x * 2")
        for i in 0..<100 { scope["v\(i)"] = Double(i) }
        scope.run(program)
        #expect(scope["y"] == 8 && scope["v99"] == 99)
    }
}

@Suite struct EELCodeLinesTests {
    @Test func joinsLikeMilkDrop() throws {
        let source = EELScope.joinCodeLines(["k = is_  // wrapped", "  beat * 2;", "// only a comment", "x = 1;"])
        #expect(source == "k = is_beat * 2;x = 1;")
        let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
        scope["is_beat"] = 3
        try run(source, scope: scope)
        #expect(scope["k"] == 6)
    }
}
