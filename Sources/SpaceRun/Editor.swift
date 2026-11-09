import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The SpaceRun window (a list of shortcuts) and its Settings window. Changes save as soon as they
/// are made and the service reloads them, the way System Settings works, so there is no Save button.
///
/// The windows always run in their own short-lived process (`spacerun edit`), which quits when the
/// last window closes. The background service only launches it (see `EditorLauncher`), so the
/// service never loads SwiftUI and stays small.
final class Editor: NSObject, NSWindowDelegate {
    static let shared = Editor()
    /// Asks the running service to open the window (object: the user's uid; userInfo "pane": "settings").
    static let showRequest = Notification.Name("local.spacerun.show-editor")
    /// Asks an already open window process to come forward (same object and userInfo).
    static let windowRequest = Notification.Name("local.spacerun.editor-window")

    private var model: EditorModel?
    private var shortcutsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var observer: NSObjectProtocol?

    /// Runs the window process until its last window closes.
    static func run(settings: Bool = false) throws {
        let app = NSApplication.shared
        let delegate = StandaloneDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.applicationIconImage = NSImage(data: AppIconData.png)
        app.mainMenu = shared.menu()
        shared.observer = DistributedNotificationCenter.default().addObserver(
            forName: windowRequest, object: "\(getuid())", queue: .main
        ) { note in try? shared.show(settings: note.userInfo?["pane"] as? String == "settings") }
        try shared.show(settings: settings)
        app.run()
    }

    func show(settings: Bool) throws { try settings ? showSettings() : showShortcuts() }

    private func currentModel() throws -> EditorModel {
        if let model { return model }
        let model = EditorModel(config: try ConfigFile.read(), serviceRunning: Service.isRunning)
        self.model = model
        return model
    }

    func showShortcuts() throws {
        let model = try currentModel()
        let window = shortcutsWindow ?? makeWindow(title: "SpaceRun", size: NSSize(width: 540, height: 580),
                                                   resizable: true, content: ShortcutsView(model: model))
        if shortcutsWindow == nil { window.center(); window.setFrameAutosaveName("SpaceRun.Shortcuts") }
        shortcutsWindow = window
        present(window)
    }

    func showSettings() throws {
        let model = try currentModel()
        let window = settingsWindow ?? makeWindow(title: "SpaceRun Settings", size: NSSize(width: 480, height: 520),
                                                  resizable: false, content: SettingsView(model: model))
        if settingsWindow == nil { window.center() }
        settingsWindow = window
        present(window)
    }

    private func makeWindow(title: String, size: NSSize, resizable: Bool, content: some View) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: content)
        if resizable { window.minSize = NSSize(width: 440, height: 360); host.sizingOptions = [.minSize] }
        else { host.sizingOptions = [.preferredContentSize] }
        window.contentView = host
        return window
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === shortcutsWindow { shortcutsWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
        if shortcutsWindow == nil, settingsWindow == nil { model?.flush() } // The app quits next.
    }

    @objc func openSettings(_ sender: Any?) { try? showSettings() }
    @objc func newShortcut(_ sender: Any?) { try? showShortcuts(); model?.addRequested = true }

    private func menu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            return item
        }
        submenu("SpaceRun", [
            item("Settings…", #selector(openSettings(_:)), ",", target: self),
            .separator(),
            item("Hide SpaceRun", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            // Quits this window only; the background service keeps your shortcuts working.
            item("Quit SpaceRun", #selector(NSApplication.terminate(_:)), "q")
        ])
        submenu("File", [
            item("New Shortcut", #selector(newShortcut(_:)), "n", target: self),
            item("Close", #selector(NSWindow.performClose(_:)), "w")
        ])
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

/// Used by the background service: starts the window process, or brings an open one forward.
enum EditorLauncher {
    private static var child: Process?

    static func open(settings: Bool = false) {
        if let child, child.isRunning {
            DistributedNotificationCenter.default().postNotificationName(
                Editor.windowRequest, object: "\(getuid())", userInfo: settings ? ["pane": "settings"] : nil,
                deliverImmediately: true)
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["edit", "--window"] + (settings ? ["--settings"] : [])
        process.terminationHandler = { _ in DispatchQueue.main.async { child = nil } }
        do {
            try process.run()
            child = process
        } catch {
            log("Could not open the SpaceRun window: \(error.localizedDescription)")
        }
    }
}

private final class StandaloneDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Model

final class EditorModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id = UUID()
        var key: String
        var kind: Binding.Kind
        var target: String
        var behavior: Binding.Behavior

        var binding: Binding { Binding(kind: kind, target: target, behavior: kind == .app ? behavior : .activate) }
    }

    @Published private(set) var rows: [Row] = []
    @Published var typingCooldown: Double { didSet { scheduleSave() } }
    @Published var activationDelay: Double { didSet { scheduleSave() } }
    @Published var disabledApps: [String] { didSet { save() } }
    @Published var showMenuBarIcon: Bool { didSet { save() } }
    @Published var serviceRunning: Bool
    @Published var starting = false
    @Published var error: String?
    /// Set by File > New Shortcut; the window opens the new-shortcut sheet.
    @Published var addRequested = false

    private var base: Configuration
    private let write: (Configuration) throws -> Void
    private var pendingSave: DispatchWorkItem?
    private var icons: [String: NSImage] = [:]

    /// Letters, then digits, then punctuation.
    static let keys = KeyMap.codes.keys.sorted { a, b in
        func rank(_ s: String) -> Int { s.first!.isLetter ? 0 : s.first!.isNumber ? 1 : 2 }
        return (rank(a), a) < (rank(b), b)
    }

    init(config: Configuration, serviceRunning: Bool = true, write: @escaping (Configuration) throws -> Void = ConfigFile.write) {
        base = config
        self.write = write
        self.serviceRunning = serviceRunning
        typingCooldown = config.typingCooldown
        activationDelay = config.activationDelay
        disabledApps = config.disabledApps
        showMenuBarIcon = config.showMenuBarIcon
        rows = Self.sorted(config.bindings.map { Row(key: $0.key, kind: $0.value.kind, target: $0.value.target, behavior: $0.value.behavior) })
    }

    private static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { (keys.firstIndex(of: $0.key) ?? .max) < (keys.firstIndex(of: $1.key) ?? .max) }
    }

    var current: Configuration {
        var config = base
        config.typingCooldown = typingCooldown
        config.activationDelay = activationDelay
        config.disabledApps = disabledApps
        config.showMenuBarIcon = showMenuBarIcon
        config.bindings = Dictionary(rows.map { ($0.key, $0.binding) }, uniquingKeysWith: { first, _ in first })
        return config
    }

    /// True while the config still has only the built-in example shortcuts.
    var isStarter: Bool { current.bindings == Configuration().bindings }

    /// The other shortcut already using `key`, if any.
    func conflict(key: String, excluding id: Row.ID) -> Row? { rows.first { $0.key == key && $0.id != id } }

    func row(_ id: Row.ID) -> Row? { rows.first { $0.id == id } }

    /// Adds a new shortcut or replaces the one with the same id.
    func commit(_ row: Row, undo: UndoManager?) {
        var row = row
        row.target = row.target.trimmingCharacters(in: .whitespaces)
        if row.kind == .url { row.target = Self.normalizedURL(row.target) }
        let isNew = self.row(row.id) == nil
        change(isNew ? "Add Shortcut" : "Edit Shortcut", undo: undo) { rows in
            rows.removeAll { $0.id == row.id }
            rows.append(row)
        }
    }

    func remove(_ ids: Set<Row.ID>, undo: UndoManager?) {
        guard !ids.isEmpty else { return }
        change(ids.count == 1 ? "Delete Shortcut" : "Delete Shortcuts", undo: undo) { $0.removeAll { ids.contains($0.id) } }
    }

    /// Every change is undoable (Edit > Undo), and undoing registers the redo.
    private func change(_ name: String, undo: UndoManager?, _ mutate: (inout [Row]) -> Void) {
        var after = rows
        mutate(&after)
        setRows(Self.sorted(after), previous: rows, name: name, undo: undo)
    }

    private func setRows(_ new: [Row], previous: [Row], name: String, undo: UndoManager?) {
        rows = new
        save()
        undo?.registerUndo(withTarget: self) { model in
            model.setRows(previous, previous: new, name: name, undo: undo)
        }
        undo?.setActionName(name)
    }

    /// Accepts "github.com" as well as "https://github.com".
    static func normalizedURL(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("://") else { return text }
        return "https://" + text
    }

    static func isValidURL(_ text: String) -> Bool {
        guard let url = URL(string: normalizedURL(text)) else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work) // Sliders change continuously.
    }

    /// Writes any slider change still waiting to be saved.
    func flush() {
        guard pendingSave != nil else { return }
        save()
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try write(current)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startService() {
        starting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = (try? Service.start()) == nil
            DispatchQueue.main.async {
                self.starting = false
                self.serviceRunning = Service.isRunning
                if failed, !self.serviceRunning {
                    self.error = "SpaceRun couldn’t start. Run “spacerun start” in Terminal to see why."
                }
            }
        }
    }

    func icon(_ binding: Binding) -> NSImage {
        let cacheKey = "\(binding.kind.rawValue):\(binding.target)"
        if let icon = icons[cacheKey] { return icon }
        let icon = Display.icon(binding)
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

    static func appURL(bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
}

// MARK: - Shortcuts window

struct ShortcutsView: View {
    @ObservedObject var model: EditorModel
    @State private var selection: Set<EditorModel.Row.ID> = []
    @State private var editing: EditorModel.Row?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            if !model.serviceRunning { notRunning }
            if model.rows.isEmpty {
                empty
            } else {
                List(selection: $selection) {
                    ForEach(model.rows) { row in ShortcutRow(row: row, model: model) }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: EditorModel.Row.ID.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Divider()
                    }
                    if !ids.isEmpty {
                        Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Shortcuts") { delete(ids) }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { edit(id) }
                }
                .onDeleteCommand { delete(selection) }
            }
            Divider()
            footer
        }
        .sheet(item: $editing) { row in
            ShortcutEditor(draft: row, isNew: model.row(row.id) == nil, model: model) { result in
                switch result {
                case .save(let row): model.commit(row, undo: undoManager); selection = [row.id]
                case .delete: delete([row.id])
                case .cancel: break
                }
                editing = nil
            }
        }
        .onChange(of: model.addRequested) { requested in
            guard requested else { return }
            model.addRequested = false
            add()
        }
        .alert("Couldn’t save shortcuts",
               isPresented: SwiftUI.Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private func add() { editing = EditorModel.Row(key: "", kind: .app, target: "", behavior: .activate) }
    private func edit(_ id: EditorModel.Row.ID) { editing = model.row(id) }
    private func delete(_ ids: Set<EditorModel.Row.ID>) {
        model.remove(ids, undo: undoManager)
        selection.subtract(ids)
    }

    private var notRunning: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.title3)
            Text("SpaceRun isn’t running, so shortcuts are off.")
            Spacer()
            Button(model.starting ? "Starting…" : "Start SpaceRun") { model.startService() }
                .disabled(model.starting)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "space").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text("No Shortcuts").font(.title3.weight(.semibold))
            Text("Add one to open an app or website by holding Space and pressing a key.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add Shortcut…") { add() }.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                .help("Add Shortcut")
                .accessibilityLabel("Add Shortcut")
            Button { delete(selection) } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                .help("Delete Shortcut")
                .accessibilityLabel("Delete Shortcut")
                .disabled(selection.isEmpty)
            Text(model.isStarter
                 ? "These are examples. Double-click one to change it."
                 : "Hold Space, then press a key. Space + ? shows them all.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 10)
            Spacer()
            Button { try? Editor.shared.showSettings() } label: { Image(systemName: "gearshape").frame(width: 24, height: 20) }
                .help("Settings")
                .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// A key drawn like a physical keycap: the one thing SpaceRun is about.
struct KeyCap: View {
    let label: String
    var wide = false

    var body: some View {
        Text(label.count == 1 ? label.uppercased() : label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: wide ? 52 : 24, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .accessibilityLabel(label.count == 1 ? "Space plus \(label.uppercased())" : label)
    }
}

struct ShortcutRow: View {
    let row: EditorModel.Row
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            KeyCap(label: row.key)
            Image(nsImage: model.icon(row.binding)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(Display.title(row.binding)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(missing ? .orange : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(row.target)
    }

    private var missing: Bool { row.kind == .app && !FileManager.default.fileExists(atPath: row.target) }

    private var subtitle: String? {
        if missing { return "App not found" }
        switch (row.kind, row.behavior) {
        case (.url, _):
            // The title is the site; add the page only when there is one.
            guard let url = URL(string: row.target) else { return "Website" }
            var page = url.path + (url.query.map { "?" + $0 } ?? "") + (url.fragment.map { "#" + $0 } ?? "")
            if page.hasSuffix("/") { page.removeLast() }
            return page.isEmpty ? "Website" : "Website · " + page
        case (.app, .activate): return nil
        case (.app, .toggle): return "Hides when already in front"
        case (.app, .previous): return "Goes back when already in front"
        }
    }
}

// MARK: - Add/edit sheet

struct ShortcutEditor: View {
    enum Result { case save(EditorModel.Row), delete, cancel }

    @State var draft: EditorModel.Row
    let isNew: Bool
    @ObservedObject var model: EditorModel
    let done: (Result) -> Void
    @State private var recording = false

    private var conflict: EditorModel.Row? { draft.key.isEmpty ? nil : model.conflict(key: draft.key, excluding: draft.id) }
    private var targetValid: Bool {
        switch draft.kind {
        case .app: return !draft.target.isEmpty
        case .url: return EditorModel.isValidURL(draft.target)
        }
    }
    private var canSave: Bool { !draft.key.isEmpty && conflict == nil && targetValid && !recording }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Shortcut") { KeyRecorder(key: $draft.key, recording: $recording) }
                    Picker("Opens", selection: $draft.kind) {
                        Text("App").tag(Binding.Kind.app)
                        Text("Website").tag(Binding.Kind.url)
                    }
                    .pickerStyle(.segmented)
                    switch draft.kind {
                    case .app:
                        LabeledContent("App") {
                            HStack(spacing: 8) {
                                if draft.target.isEmpty {
                                    Text("None").foregroundStyle(.secondary)
                                } else {
                                    Image(nsImage: model.icon(draft.binding)).resizable().frame(width: 18, height: 18)
                                    Text(Display.title(draft.binding)).lineLimit(1)
                                }
                                Button("Choose…") { if let url = EditorModel.chooseApp() { draft.target = url.path } }
                            }
                        }
                        Picker("If already in front", selection: $draft.behavior) {
                            Text("Keep it in front").tag(Binding.Behavior.activate)
                            Text("Hide it").tag(Binding.Behavior.toggle)
                            Text("Go back to previous app").tag(Binding.Behavior.previous)
                        }
                    case .url:
                        TextField("Address", text: $draft.target, prompt: Text("example.com"))
                    }
                } footer: {
                    if let conflict {
                        Text("Space + \(conflict.key.uppercased()) already opens \(Display.title(conflict.binding)).")
                            .foregroundStyle(.red)
                    } else if draft.kind == .url, !draft.target.isEmpty, !targetValid {
                        Text("Enter a web address, like example.com.").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: draft.kind) { _ in draft.target = "" } // An app is not a web address, and vice versa.

            HStack {
                if !isNew {
                    Button("Delete Shortcut", role: .destructive) { done(.delete) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { done(.cancel) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") { done(.save(draft)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear { if isNew { recording = true } }
    }
}

/// Click, then type a key. Keys are stored by physical position, matching how the service reads them.
struct KeyRecorder: View {
    @SwiftUI.Binding var key: String
    @SwiftUI.Binding var recording: Bool
    @State private var monitor: Any?

    var body: some View {
        Button { recording.toggle() } label: {
            HStack(spacing: 5) {
                KeyCap(label: "Space", wide: true)
                Text("+").foregroundStyle(.secondary)
                if recording {
                    Text("Type a key").foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                } else if key.isEmpty {
                    Text("Click to set").foregroundStyle(.secondary)
                } else {
                    KeyCap(label: key)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Type the key to use with Space. Escape cancels." : "Click to change the key")
        .accessibilityLabel(key.isEmpty ? "Shortcut key, not set" : "Shortcut Space plus \(key.uppercased())")
        .onChange(of: recording) { isRecording in isRecording ? start() : stop() }
        .onAppear { if recording { start() } }
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Escape stops recording, not the sheet.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty, let name = KeyMap.name(for: event.keyCode) else { NSSound.beep(); return nil }
            key = name
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Form {
            Section {
                Toggle("Show SpaceRun in the menu bar", isOn: $model.showMenuBarIcon)
            } footer: {
                Text("When it’s hidden, open SpaceRun from Applications to change your shortcuts.")
                    .foregroundStyle(.secondary)
            }
            Section("Timing") {
                delay("Hold Space for", "How long to hold Space before a key counts as a shortcut.", $model.activationDelay)
                delay("Typing cooldown", "Space types normally if you typed within this time.", $model.typingCooldown)
            }
            Section {
                if model.disabledApps.isEmpty {
                    Text("None. Shortcuts work in every app.").foregroundStyle(.secondary)
                }
                ForEach(model.disabledApps, id: \.self) { id in
                    IgnoredAppRow(bundleID: id) { model.disabledApps.removeAll { $0 == id } }
                }
            } header: {
                Text("Ignore Space in these apps")
            } footer: {
                HStack {
                    Text("Useful for games, or apps where you hold Space.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add App…") {
                        guard let url = EditorModel.chooseApp(), let id = Bundle(url: url)?.bundleIdentifier,
                              !model.disabledApps.contains(id) else { return }
                        model.disabledApps.append(id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func delay(_ title: String, _ detail: String, _ value: SwiftUI.Binding<Double>) -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: 0...1, step: 0.05).labelsHidden().frame(width: 150)
                Text("\(Int((value.wrappedValue * 1000).rounded())) ms").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

private struct IgnoredAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let url = EditorModel.appURL(bundleID: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
            Text(url.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
                .accessibilityLabel("Remove \(url?.deletingPathExtension().lastPathComponent ?? bundleID)")
        }
    }
}
