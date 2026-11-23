import Foundation

/// Which preset shows and which comes next: on a timer, in random or alphabetical order. The next preset is known in
/// advance (`upcoming`), so its shaders can compile before it shows.
public struct PresetCycler: Sendable {
    public struct Options: Sendable, Equatable {
        /// Change on a timer, every `seconds`.
        public var cycle = true
        public var seconds = 20.0
        /// Seconds two presets mix at a change.
        public var blend = 2.7
        /// Random next preset; else alphabetical.
        public var shuffle = true
        public var builtIn = true
        /// Render scale: 0.5 low, 1 normal, 2 every screen pixel.
        public var quality = 1.0

        public init() {}
    }

    /// A change the renderer must make: show `name`, mixing for `blend` seconds.
    public struct Change: Sendable, Equatable {
        public var name: String
        public var blend: Double
    }

    public var options = Options()
    public private(set) var names: [String] = []
    public private(set) var current: String?
    public private(set) var upcoming: String?
    private var index = -1
    private var changed = 0.0
    private let random: @Sendable () -> Double

    public init(random: @escaping @Sendable () -> Double = { .random(in: 0..<1) }) { self.random = random }

    /// New list of names; the current preset keeps its place if it is still there.
    public mutating func setNames(_ names: [String]) {
        self.names = names
        index = current.flatMap(names.firstIndex) ?? -1
        pickUpcoming()
    }

    public mutating func setOptions(_ options: Options) {
        let order = options.shuffle != self.options.shuffle
        self.options = options
        if order { pickUpcoming() }
    }

    /// `blend` nil: the options' blend time.
    public mutating func select(_ name: String, blend: Double? = nil, now: Double) -> Change? {
        guard let i = names.firstIndex(of: name) else { return nil }
        index = i
        current = name
        changed = now
        pickUpcoming()
        return Change(name: name, blend: blend ?? options.blend)
    }

    public mutating func step(_ by: Int, now: Double) -> Change? {
        guard !names.isEmpty else { return nil }
        return select(names[((index + by) % names.count + names.count) % names.count], now: now)
    }

    /// The upcoming preset in random order (it is compiled already), else any random one.
    public mutating func random(now: Double) -> Change? {
        guard !names.isEmpty else { return nil }
        let name = options.shuffle ? upcoming : nil
        return select(name ?? names[min(Int(random() * Double(names.count)), names.count - 1)], now: now)
    }

    /// The timed change, when it is due.
    public mutating func tick(now: Double) -> Change? {
        guard options.cycle, now - changed > options.seconds else { return nil }
        return options.shuffle ? random(now: now) : step(1, now: now)
    }

    /// A preset that does not load: it leaves the list, and the next one shows if it was current.
    public mutating func drop(_ name: String, now: Double) -> Change? {
        let wasCurrent = name == current, place = index
        if wasCurrent { current = nil }
        setNames(names.filter { $0 != name })
        guard wasCurrent else { return nil }
        index = place - 1  // the next name moved into the dropped one's place
        return options.shuffle ? random(now: now) : step(1, now: now)
    }

    private mutating func pickUpcoming() {
        guard !names.isEmpty else { upcoming = nil; return }
        upcoming = options.shuffle ? names[min(Int(random() * Double(names.count)), names.count - 1)] : names[(index + 1) % names.count]
    }
}
