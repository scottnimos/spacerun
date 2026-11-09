import XCTest
@testable import SpaceRun

final class EditorModelTests: XCTestCase {
    private var written: [Configuration] = []

    private func model(_ config: Configuration = Configuration()) -> EditorModel {
        written = []
        return EditorModel(config: config, write: { [unowned self] in self.written.append($0) })
    }

    func testEditsSaveImmediately() {
        let model = model()
        var row = model.rows[0]
        row.target = "/Applications/Other.app"
        model.commit(row, undo: nil)
        XCTAssertEqual(written.last?.bindings[row.key]?.target, "/Applications/Other.app")
        XCTAssertEqual(model.rows.count, Configuration().bindings.count)

        model.showMenuBarIcon = false
        XCTAssertEqual(written.last?.showMenuBarIcon, false)
    }

    func testAddKeepsKeyOrderAndDetectsConflicts() {
        let model = model(Configuration(bindings: ["m": Binding(kind: .app, target: "/System/Applications/Music.app")]))
        let new = EditorModel.Row(key: "a", kind: .url, target: "example.com", behavior: .activate)
        XCTAssertNil(model.conflict(key: "a", excluding: new.id))
        model.commit(new, undo: nil)
        XCTAssertEqual(model.rows.map(\.key), ["a", "m"])
        XCTAssertEqual(written.last?.bindings["a"]?.target, "https://example.com")

        let other = EditorModel.Row(key: "m", kind: .app, target: "/x.app", behavior: .activate)
        XCTAssertEqual(model.conflict(key: "m", excluding: other.id)?.key, "m")
        XCTAssertNil(model.conflict(key: "m", excluding: model.rows[1].id)) // A row never conflicts with itself.
    }

    func testDeleteCanBeUndoneAndRedone() {
        let model = model()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let count = model.rows.count
        let id = model.rows[0].id
        undo.beginUndoGrouping(); model.remove([id], undo: undo); undo.endUndoGrouping()
        XCTAssertEqual(model.rows.count, count - 1)
        undo.undo()
        XCTAssertEqual(model.rows.count, count)
        XCTAssertEqual(written.last?.bindings.count, count)
        undo.redo()
        XCTAssertEqual(model.rows.count, count - 1)
    }

    func testURLBindingsDropAppBehavior() {
        let model = model(Configuration(bindings: [:]))
        model.commit(.init(key: "e", kind: .url, target: " https://example.com ", behavior: .toggle), undo: nil)
        let binding = model.current.bindings["e"]
        XCTAssertEqual(binding?.target, "https://example.com")
        XCTAssertEqual(binding?.behavior, .activate)
        XCTAssertFalse(EditorModel.isValidURL("not a url"))
        XCTAssertTrue(EditorModel.isValidURL("github.com"))
    }

    func testOlderConfigWithoutNewSettingsStillLoads() throws {
        let json = #"{"activationDelay":0.3,"typingCooldown":0.2,"disabledApps":[],"bindings":{}}"#
        let config = try ConfigFile.decode(Data(json.utf8))
        XCTAssertTrue(config.showMenuBarIcon)
        XCTAssertEqual(config.activationDelay, 0.3)
    }

    func testKeyNamesRoundTrip() {
        for (name, code) in KeyMap.codes { XCTAssertEqual(KeyMap.name(for: code), name) }
    }
}
