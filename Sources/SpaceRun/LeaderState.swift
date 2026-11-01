import Foundation

/// Event-tap policy kept independent of macOS APIs so typing behavior can be tested.
struct LeaderState {
    enum Phase { case idle, pending, active, passthrough }
    struct Decision {
        var consume = false
        var replaySpaceDown = false
        var action: UInt16?
    }
    var phase: Phase = .idle
    var began: Double = 0
    var lastTyping: Double = -.infinity
    var swallowed: Set<UInt16> = []

    mutating func reset() { self = LeaderState() }

    mutating func flush() -> Decision {
        if phase == .pending {
            phase = .passthrough
            return Decision(replaySpaceDown: true)
        }
        return Decision()
    }

    mutating func handle(code: UInt16, down: Bool, repeated: Bool = false,
                         modified: Bool = false, now: Double, enabled: Bool = true,
                         cooldown: Double, delay: Double, bindings: Set<UInt16>) -> Decision {
        if !down, swallowed.remove(code) != nil { return Decision(consume: true) }
        if down, repeated, swallowed.contains(code) { return Decision(consume: true) }
        if code == 49 {
            if !down {
                let old = phase
                phase = .idle
                if old != .active { lastTyping = now }
                return Decision(consume: old == .active, replaySpaceDown: old == .pending)
            }
            if repeated { return Decision(consume: phase == .pending || phase == .active) }
            guard enabled, !modified, now - lastTyping >= cooldown else {
                phase = .passthrough
                return Decision()
            }
            phase = .pending
            began = now
            return Decision(consume: true)
        }
        guard down else { return Decision() }
        if phase == .active {
            swallowed.insert(code)
            return Decision(consume: true, action: !repeated && !modified ? (bindings.contains(code) ? code : nil) : nil)
        }
        if phase == .pending {
            if code == 53 { // Escape cancels without typing a space.
                phase = .active
                swallowed.insert(code)
                return Decision(consume: true)
            }
            if enabled, !modified, !repeated, now - began >= delay, bindings.contains(code) {
                phase = .active
                swallowed.insert(code)
                return Decision(consume: true, action: code)
            }
            lastTyping = now
            return flush()
        }
        lastTyping = now
        return Decision()
    }
}
