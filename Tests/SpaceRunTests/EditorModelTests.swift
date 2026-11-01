import XCTest
@testable import SpaceRun

final class EditorModelTests: XCTestCase {
    func testTracksChangesAndRevert() {
        let model = EditorModel(config: Configuration())
        XCTAssertFalse(model.hasChanges)
        model.activationDelay = 0.35
        XCTAssertTrue(model.hasChanges)
        model.revert()
        XCTAssertFalse(model.hasChanges)
        model.rows[0].target = "/Applications/Other.app"
        XCTAssertTrue(model.hasChanges)
    }

    func testDuplicateOrEmptyShortcutIsRejectedBeforeWriting() {
        let model = EditorModel(config: Configuration())
        model.rows[1].key = model.rows[0].key
        XCTAssertTrue(model.isDuplicate(model.rows[0]))
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.message?.isError, true)

        model.revert()
        model.add()
        XCTAssertFalse(model.isDuplicate(model.rows.last!))
        XCTAssertFalse(model.save()) // New row has no target yet.
    }

    func testURLBindingsDropAppBehavior() {
        let model = EditorModel(config: Configuration(bindings: [:]))
        model.rows = [.init(key: "e", kind: .url, target: " https://example.com ", behavior: .toggle)]
        let binding = model.current.bindings["e"]
        XCTAssertEqual(binding?.target, "https://example.com")
        XCTAssertEqual(binding?.behavior, .activate)
    }
}
