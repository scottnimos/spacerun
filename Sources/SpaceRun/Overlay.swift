import AppKit
import SwiftUI

/// Names and icons shared by the overlay and the editor.
enum Display {
    static func title(_ binding: Binding) -> String {
        switch binding.kind {
        case .app:
            return URL(fileURLWithPath: binding.target).deletingPathExtension().lastPathComponent
        case .url:
            guard let host = URL(string: binding.target)?.host else { return binding.target }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    static func detail(_ binding: Binding) -> String {
        switch (binding.kind, binding.behavior) {
        case (.url, _): return "Web"
        case (.app, .activate): return ""
        case (.app, .toggle): return "Toggle"
        case (.app, .previous): return "Toggle back"
        }
    }

    static func icon(_ binding: Binding) -> NSImage {
        switch binding.kind {
        case .app:
            if FileManager.default.fileExists(atPath: binding.target) {
                return NSWorkspace.shared.icon(forFile: binding.target)
            }
            return NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil) ?? NSImage()
        case .url:
            // Show the default browser's icon, as that is what opens the link.
            if let url = URL(string: binding.target), let browser = NSWorkspace.shared.urlForApplication(toOpen: url) {
                return NSWorkspace.shared.icon(forFile: browser.path)
            }
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

/// Cheat sheet shown while Space is held after pressing ?. Built lazily on first use, so the
/// daemon pays nothing for it until then; rebuilt only after the config changes.
final class Overlay {
    private var panel: NSPanel?
    private var config: Configuration
    private var stale = true

    init(config: Configuration) { self.config = config }

    func update(_ config: Configuration) {
        self.config = config
        stale = true
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if stale {
            let items = config.bindings.sorted { $0.key < $1.key }
                .map { Item(key: $0.key, title: Display.title($0.value), detail: Display.detail($0.value),
                            icon: Display.icon($0.value)) }
            let host = NSHostingView(rootView: OverlayView(items: items))
            let size = host.fittingSize
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active // The daemon is never the active app; keep the blur on.
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.masksToBounds = true
            host.frame = effect.bounds
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)
            panel.contentView = effect
            panel.setContentSize(size)
            stale = false
        }
        // Centre on the screen that has the mouse pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    struct Item: Identifiable {
        let key, title, detail: String
        let icon: NSImage
        var id: String { key }
    }
}

struct OverlayView: View {
    let items: [Overlay.Item]

    private var columns: Int { min(4, max(1, Int(Double(items.count).squareRoot().rounded(.up)))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("SpaceRun").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 24)
                Text("Hold Space, then press a key").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("No shortcuts yet. Run “spacerun edit” to add some.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(items[start..<min(start + columns, items.count)]) { cell($0) }
                        }
                    }
                }
            }
        }
        .padding(22)
        .fixedSize()
    }

    private func cell(_ item: Overlay.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.key.uppercased())
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(width: 190, alignment: .leading)
    }
}
