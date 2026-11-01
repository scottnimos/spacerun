import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `spacerun edit`: a small window for editing config.json. Saving writes the file, and a
/// running SpaceRun service picks up the change automatically.
enum Editor {
    static func run() throws {
        let model = EditorModel(config: try ConfigFile.read())
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = menu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "SpaceRun"
        window.minSize = NSSize(width: 640, height: 460)
        let host = NSHostingView(rootView: EditorView(model: model))
        host.sizingOptions = [.minSize] // Keep the window at its own size; the list scrolls.
        window.contentView = host
        let delegate = EditorDelegate(model: model)
        window.delegate = delegate
        app.delegate = delegate
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    private static func menu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        submenu("SpaceRun", [item("Quit SpaceRun", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [item("Close", #selector(NSWindow.performClose(_:)), "w")])
        // Needed so Cmd-C/V/X/A/Z work in text fields.
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a")
        ])
        return main
    }
}

private final class EditorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: EditorModel
    init(model: EditorModel) { self.model = model }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscard() ? .terminateNow : .terminateCancel
    }

    private func confirmDiscard() -> Bool {
        guard model.hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.save()
        case .alertThirdButtonReturn: model.revert(); return true
        default: return false
        }
    }
}

final class EditorModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var kind: Binding.Kind
        var target: String
        var behavior: Binding.Behavior

        static func == (a: Row, b: Row) -> Bool {
            a.key == b.key && a.kind == b.kind && a.target == b.target && a.behavior == b.behavior
        }
    }

    @Published var rows: [Row] = []
    @Published var typingCooldown = 0.2
    @Published var activationDelay = 0.2
    @Published var disabledApps: [String] = []
    @Published var message: (text: String, isError: Bool)?
    private var saved: Configuration
    /// Shown until the user saves their own shortcuts or dismisses it.
    @Published var showWelcome: Bool
    let serviceRunning = (try? Service.loaded()) ?? false
    private var icons: [String: NSImage] = [:]

    static let keys = KeyMap.codes.keys.sorted { a, b in
        // Letters, then digits, then punctuation.
        func rank(_ s: String) -> Int { s.first!.isLetter ? 0 : s.first!.isNumber ? 1 : 2 }
        return (rank(a), a) < (rank(b), b)
    }

    init(config: Configuration) {
        saved = config
        showWelcome = config.bindings == Configuration().bindings
        load(config)
    }

    private func load(_ config: Configuration) {
        rows = config.bindings.sorted { $0.key < $1.key }
            .map { Row(key: $0.key, kind: $0.value.kind, target: $0.value.target, behavior: $0.value.behavior) }
        typingCooldown = config.typingCooldown
        activationDelay = config.activationDelay
        disabledApps = config.disabledApps
    }

    var current: Configuration {
        var config = saved
        config.typingCooldown = typingCooldown
        config.activationDelay = activationDelay
        config.disabledApps = disabledApps
        config.bindings = Dictionary(rows.map { ($0.key, Binding(kind: $0.kind, target: $0.target.trimmingCharacters(in: .whitespaces),
                                                                 behavior: $0.kind == .app ? $0.behavior : .activate)) },
                                     uniquingKeysWith: { first, _ in first })
        return config
    }

    var hasChanges: Bool {
        let a = current, b = saved
        return a.typingCooldown != b.typingCooldown || a.activationDelay != b.activationDelay
            || a.disabledApps != b.disabledApps || rows.count != b.bindings.count
            || a.bindings.contains { key, value in
                guard let old = b.bindings[key] else { return true }
                return old.kind != value.kind || old.target != value.target || old.behavior != value.behavior
            }
    }

    func isDuplicate(_ row: Row) -> Bool { rows.filter { $0.key == row.key }.count > 1 }

    func add() {
        let used = Set(rows.map(\.key))
        rows.append(Row(key: Self.keys.first { !used.contains($0) } ?? "a", kind: .app, target: "", behavior: .activate))
    }

    func remove(_ row: Row) { rows.removeAll { $0.id == row.id } }

    @discardableResult
    func save() -> Bool {
        if let dupe = rows.first(where: isDuplicate) {
            message = ("Space + \(dupe.key.uppercased()) is used more than once.", true); return false
        }
        if let empty = rows.first(where: { $0.target.trimmingCharacters(in: .whitespaces).isEmpty }) {
            message = ("Space + \(empty.key.uppercased()) needs an app or URL.", true); return false
        }
        do {
            let config = current
            try ConfigFile.write(config)
            saved = config
            showWelcome = false
            message = (serviceRunning ? "Saved. SpaceRun reloads it automatically."
                                      : "Saved. Run 'spacerun start' to use your shortcuts.", false)
            return true
        } catch {
            message = (error.localizedDescription, true)
            return false
        }
    }

    func revert() {
        load(saved)
        message = nil
    }

    func icon(_ row: Row) -> NSImage {
        let cacheKey = "\(row.kind.rawValue):\(row.target)"
        if let icon = icons[cacheKey] { return icon }
        let icon = Display.icon(Binding(kind: row.kind, target: row.target))
        icons[cacheKey] = icon
        return icon
    }

    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showWelcome { welcome }
            if !model.serviceRunning {
                Label("SpaceRun isn’t running, so shortcuts won’t work yet. Start it with “spacerun start” in Terminal.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            HStack {
                Text("Shortcuts").font(.headline)
                Text("Hold Space, then press the key. Space + ? shows them all.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { model.add() } label: { Label("Add", systemImage: "plus") }
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 8)

            List {
                ForEach($model.rows) { $row in
                    BindingRow(row: $row, model: model)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)

            Divider()
            settings.padding(16)
            Divider()

            HStack {
                if let message = model.message {
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.isError ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Revert") { model.revert() }.disabled(!model.hasChanges)
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasChanges)
            }
            .padding(16)
        }
    }

    private var welcome: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 24)).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to SpaceRun").font(.headline)
                Text("Hold **Space**, then press a key to open an app or website. Hold Space and press **?** to see all your shortcuts.")
                Text("The shortcuts below are examples. Change them, delete them, or click **Add**, then **Save**. Choose an app with **Choose…**, or switch a row to **URL** for a website.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.showWelcome = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
        .padding([.horizontal, .top], 16)
    }

    private var settings: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Timing").font(.headline)
                delay("Hold Space for", $model.activationDelay,
                      help: "How long Space must be held before a shortcut key counts.")
                delay("Typing cooldown", $model.typingCooldown,
                      help: "Space acts normally if you typed within this time.")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ignore in apps").font(.headline)
                    Spacer()
                    Button {
                        guard let url = EditorModel.chooseApp(), let id = Bundle(url: url)?.bundleIdentifier,
                              !model.disabledApps.contains(id) else { return }
                        model.disabledApps.append(id)
                    } label: { Image(systemName: "plus") }
                    .help("Choose an app where Space should never trigger shortcuts")
                }
                if model.disabledApps.isEmpty {
                    Text("None. Shortcuts work everywhere.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.disabledApps, id: \.self) { id in
                    HStack {
                        Text(id).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Button { model.disabledApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func delay(_ title: String, _ value: SwiftUI.Binding<Double>, help: String) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05).frame(width: 160)
            Text("\(Int((value.wrappedValue * 1000).rounded())) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
        }
        .help(help)
    }
}

struct BindingRow: View {
    @SwiftUI.Binding var row: EditorModel.Row
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("Key", selection: $row.key) {
                ForEach(EditorModel.keys, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            .labelsHidden()
            .frame(width: 64)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: model.isDuplicate(row) ? 1.5 : 0))
            .help(model.isDuplicate(row) ? "This key is used more than once" : "Shortcut key")

            Picker("Type", selection: $row.kind) {
                Text("App").tag(Binding.Kind.app)
                Text("URL").tag(Binding.Kind.url)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
            .onChange(of: row.kind) { _ in row.target = "" } // An app path is not a URL, and vice versa.

            Image(nsImage: model.icon(row)).resizable().frame(width: 22, height: 22)

            switch row.kind {
            case .app:
                Text(row.target.isEmpty ? "No app chosen" : Display.title(Binding(kind: .app, target: row.target)))
                    .foregroundStyle(row.target.isEmpty ? .secondary : .primary)
                    .help(row.target)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") {
                    if let url = EditorModel.chooseApp() { row.target = url.path }
                }
                Picker("When already in front", selection: $row.behavior) {
                    Text("Just open").tag(Binding.Behavior.activate)
                    Text("Hide").tag(Binding.Behavior.toggle)
                    Text("Go back").tag(Binding.Behavior.previous)
                }
                .labelsHidden()
                .frame(width: 104)
                .help("What happens if the app is already frontmost: stay, hide it, or return to the previous app")
            case .url:
                TextField("https://example.com", text: $row.target)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            Button { model.remove(row) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
        }
        .padding(.vertical, 2)
    }
}
