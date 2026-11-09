import XCTest
import SwiftUI
@testable import SpaceRun

/// Renders the editor windows to PNGs for a visual check. Runs only when SPACERUN_SNAPSHOT_DIR is set.
final class SnapshotTests: XCTestCase {
    func testRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["SPACERUN_SNAPSHOT_DIR"] else { throw XCTSkip("Set SPACERUN_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let config = try ConfigFile.decode(Data(contentsOf: URL(fileURLWithPath: dir + "/config.json")))
        let model = EditorModel(config: config, serviceRunning: false, write: { _ in })
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            render(ShortcutsView(model: model), NSSize(width: 540, height: 600), dark, "\(dir)/shortcuts\(suffix).png")
            render(SettingsView(model: model), NSSize(width: 480, height: 0), dark, "\(dir)/settings\(suffix).png")
            var row = model.rows.first { $0.kind == .app }!
            row.behavior = .toggle
            render(ShortcutEditor(draft: row, isNew: false, model: model, done: { _ in }), NSSize(width: 460, height: 0), dark, "\(dir)/sheet\(suffix).png")
            let conflict = EditorModel.Row(key: model.rows[0].key, kind: .url, target: "example.com", behavior: .activate)
            render(ShortcutEditor(draft: conflict, isNew: true, model: model, done: { _ in }), NSSize(width: 460, height: 0), dark, "\(dir)/sheet-new\(suffix).png")
        }
    }

    private func render(_ view: some View, _ size: NSSize, _ dark: Bool, _ path: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let fitting = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height > 0 ? size.height : fitting.height))
        window.setContentSize(host.frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
