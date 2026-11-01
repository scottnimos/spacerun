import XCTest
@testable import SpaceRun

final class LeaderStateTests: XCTestCase {
    var state = LeaderState()

    @discardableResult
    func event(_ code: UInt16, _ down: Bool = true, at time: Double,
               modified: Bool = false, repeated: Bool = false, enabled: Bool = true,
               help: Bool = false) -> LeaderState.Decision {
        state.handle(code: code, down: down, repeated: repeated, modified: modified, help: help, now: time,
                     enabled: enabled, cooldown: 0.2, delay: 0.2, bindings: [3, 17])
    }

    func testTapSpaceReplaysDownBeforePassingUp() {
        XCTAssertTrue(event(49, at: 1).consume)
        let up = event(49, false, at: 1.05)
        XCTAssertTrue(up.replaySpaceDown)
        XCTAssertFalse(up.consume)
        XCTAssertEqual(state.phase, .idle)
    }

    func testShortcutConsumesSpaceAndKeyIncludingReleaseAfterSpace() {
        event(49, at: 1)
        let action = event(3, at: 1.3)
        XCTAssertTrue(action.consume)
        XCTAssertEqual(action.action, 3)
        XCTAssertTrue(event(49, false, at: 1.4).consume)
        XCTAssertTrue(event(3, at: 1.5, repeated: true).consume)
        XCTAssertTrue(event(3, false, at: 1.6).consume)
        XCTAssertFalse(event(3, at: 1.7).consume)
    }

    func testTypingCooldownLeavesWholeSpacePressAlone() {
        event(0, at: 1)
        XCTAssertFalse(event(49, at: 1.1).consume)
        XCTAssertNil(event(3, at: 1.5).action)
        let up = event(49, false, at: 1.6)
        XCTAssertFalse(up.consume)
        XCTAssertFalse(up.replaySpaceDown)
    }

    func testEarlyBoundKeyIsTypingAndCannotArmLater() {
        event(49, at: 1)
        let early = event(3, at: 1.05)
        XCTAssertTrue(early.replaySpaceDown)
        XCTAssertFalse(early.consume)
        XCTAssertNil(early.action)
        XCTAssertNil(event(17, at: 1.6).action)
        XCTAssertFalse(event(49, false, at: 1.7).consume)
    }

    func testUnknownKeyReplaysSpaceInOrder() {
        event(49, at: 1)
        let unknown = event(0, at: 2)
        XCTAssertTrue(unknown.replaySpaceDown)
        XCTAssertFalse(unknown.consume)
        XCTAssertFalse(event(49, false, at: 2.1).replaySpaceDown)
    }

    func testModifiedSpacePassesThrough() {
        XCTAssertFalse(event(49, at: 1, modified: true).consume)
        XCTAssertNil(event(3, at: 2).action)
        XCTAssertFalse(event(49, false, at: 3).consume)
    }

    func testModifierOrMouseDuringPendingFlushesSpaceOnlyOnce() {
        event(49, at: 1)
        XCTAssertTrue(state.flush().replaySpaceDown)
        XCTAssertFalse(state.flush().replaySpaceDown)
        XCTAssertNil(event(3, at: 2).action)
    }

    func testModifiedShortcutPassesThroughWithSpace() {
        event(49, at: 1)
        let modified = event(3, at: 2, modified: true)
        XCTAssertTrue(modified.replaySpaceDown)
        XCTAssertFalse(modified.consume)
        XCTAssertNil(modified.action)
    }

    func testDisabledAppPassesThroughAndCannotTriggerMidHold() {
        XCTAssertFalse(event(49, at: 1, enabled: false).consume)
        XCTAssertNil(event(3, at: 2, enabled: true).action)
        event(49, false, at: 3)
        event(49, at: 4)
        XCTAssertNil(event(3, at: 5, enabled: false).action)
        XCTAssertEqual(state.phase, .passthrough)
    }

    func testEscapeCancelsWithoutSpace() {
        event(49, at: 1)
        XCTAssertTrue(event(53, at: 2).consume)
        XCTAssertTrue(event(53, false, at: 2.1).consume)
        let up = event(49, false, at: 3)
        XCTAssertTrue(up.consume)
        XCTAssertFalse(up.replaySpaceDown)
    }

    func testAutoRepeatDoesNotLaunchRepeatedly() {
        event(49, at: 1)
        XCTAssertTrue(event(49, at: 1.1, repeated: true).consume)
        XCTAssertEqual(event(3, at: 2).action, 3)
        XCTAssertNil(event(3, at: 2.1, repeated: true).action)
    }

    func testMultipleShortcutsDuringOneHold() {
        event(49, at: 1)
        XCTAssertEqual(event(3, at: 2).action, 3)
        event(3, false, at: 2.1)
        XCTAssertEqual(event(17, at: 2.2).action, 17)
    }

    func testConfigurationRejectsBadKeysAndTargets() throws {
        var config = Configuration()
        config.bindings["space"] = Binding(kind: .url, target: "https://example.com")
        XCTAssertThrowsError(try config.validate())
        config.bindings.removeValue(forKey: "space")
        config.activationDelay = -1
        XCTAssertThrowsError(try config.validate())
        config.activationDelay = 0.2
        config.bindings["a"] = Binding(kind: .url, target: "javascript:alert(1)")
        XCTAssertThrowsError(try config.validate())
        config.bindings["a"] = Binding(kind: .app, target: "relative.app")
        XCTAssertThrowsError(try config.validate())
    }

    func testBehaviorCanBeOmittedInHandwrittenConfig() throws {
        let data = Data(#"{"kind":"app","target":"/Applications/Test.app"}"#.utf8)
        let binding = try JSONDecoder().decode(Binding.self, from: data)
        XCTAssertEqual(binding.behavior, .activate)
    }

    func testHelpKeyShowsOverlayEvenWithShiftAndKeepsHoldActive() {
        event(49, at: 1)
        let help = event(44, at: 1.3, modified: true, help: true)
        XCTAssertTrue(help.consume)
        XCTAssertTrue(help.help)
        XCTAssertNil(help.action)
        XCTAssertFalse(event(44, at: 1.4, modified: true, repeated: true, help: true).help)
        XCTAssertEqual(event(3, at: 1.5).action, 3)
        XCTAssertTrue(event(49, false, at: 1.6).consume)
        XCTAssertTrue(event(44, false, at: 1.7).consume)
    }

    func testEarlyHelpKeyTypesNormally() {
        event(49, at: 1)
        let early = event(44, at: 1.05, modified: true, help: true)
        XCTAssertFalse(early.help)
        XCTAssertTrue(early.replaySpaceDown)
        XCTAssertFalse(early.consume)
    }
}
