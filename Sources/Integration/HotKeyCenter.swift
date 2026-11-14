import Carbon.HIToolbox

/// System-wide shortcuts through Carbon `RegisterEventHotKey`; they work in the background and need no
/// accessibility permission. Registration is exclusive, so a combo that another app holds fails.
@MainActor public final class HotKeyCenter {
    private let handler: (HotKeyAction) -> Void
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotKeyAction] = [:]
    private var eventHandler: EventHandlerRef?

    public init(handler: @escaping (HotKeyAction) -> Void) { self.handler = handler }

    /// Replaces all shortcuts. Returns the actions whose combo is taken by another app.
    @discardableResult
    public func register(_ combos: [HotKeyAction: KeyCombo]) -> Set<HotKeyAction> {
        unregisterAll()
        guard !combos.isEmpty, installHandler() else { return Set(combos.keys) }
        var failed = Set<HotKeyAction>()
        for (n, (action, combo)) in combos.sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(n + 1))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(),
                                             OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = action
            } else {
                failed.insert(action)
            }
        }
        return failed
    }

    public func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    /// Call before the center goes away: the Carbon handler points at it.
    public func stop() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    /// "MSnc"
    private static let signature: OSType = 0x4D53_6E63

    private func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            guard let event, let context, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers events on the main thread.
            MainActor.assumeIsolated { center.fire(id.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        return status == noErr
    }

    private func fire(_ id: UInt32) {
        if let action = actions[id] { handler(action) }
    }
}
