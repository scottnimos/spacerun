import AppKit
import ApplicationServices
import Darwin

final class Daemon {
    private var config: Configuration
    private var bindings: [UInt16: Binding] = [:]
    private var state = LeaderState()
    private var savedSpace: CGEvent?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var signals: [DispatchSourceSignal] = []
    private var activationObserver: NSObjectProtocol?
    private var disabled = false
    private var frontApp: NSRunningApplication?
    private var previousApp: NSRunningApplication?
    private var boundCodes: Set<UInt16> = []
    private var lockFD: Int32 = -1
    private static let marker: Int64 = 0x535041434552554E

    init(config: Configuration) {
        self.config = config
        apply(config)
    }

    private func apply(_ config: Configuration) {
        self.config = config
        bindings = Dictionary(uniqueKeysWithValues: config.bindings.map { (KeyMap.codes[$0.key]!, $0.value) })
        boundCodes = Set(bindings.keys)
        updateFrontApp()
    }

    private func updateFrontApp() {
        let app = NSWorkspace.shared.frontmostApplication
        if let app, app.processIdentifier != frontApp?.processIdentifier {
            previousApp = frontApp
            frontApp = app
        }
        let bundleID = app?.bundleIdentifier ?? ""
        disabled = config.disabledApps.contains(bundleID)
    }

    func run() throws {
        lockFD = Darwin.open(ConfigFile.url.deletingLastPathComponent().appendingPathComponent("daemon.lock").path,
                             O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure("SpaceRun is already running, or its lock file cannot be opened.")
        }
        defer { if lockFD >= 0 { Darwin.close(lockFD) } }

        guard AXIsProcessTrusted() else {
            throw Failure("Accessibility permission is required. Run 'spacerun permissions', grant access, then start again.")
        }
        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue()
                .handle(proxy: proxy, type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw Failure("Cannot create keyboard event tap. Check Accessibility and Input Monitoring permissions, then restart.")
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw Failure("Cannot create keyboard run-loop source.")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateFrontApp() }
        watchConfig()
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signals.append(source)
        }
        log("Running. Hold Space for \(config.activationDelay)s, then press a bound key. Ctrl-C to stop.")
        CFRunLoopRun()
        watcher?.cancel()
        fileWatcher?.cancel()
        signals.forEach { $0.cancel() }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    private func stop() {
        // If a Space down was withheld, restore a complete tap before shutting down.
        if state.phase == .pending, let down = savedSpace,
           let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) {
            down.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Recover without retaining a stuck leader or swallowed key state.
            if state.phase == .pending, let down = savedSpace {
                down.tapPostEvent(proxy)
            }
            state.reset()
            savedSpace = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if type != .keyDown && type != .keyUp {
            replay(state.flush(), proxy: proxy)
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        if type == .keyDown, code == 49, !repeated { savedSpace = event.copy() }
        let decision = state.handle(code: code, down: type == .keyDown, repeated: repeated,
                                    modified: !event.flags.intersection(flags).isEmpty,
                                    now: ProcessInfo.processInfo.systemUptime, enabled: !disabled,
                                    cooldown: config.typingCooldown, delay: config.activationDelay,
                                    bindings: boundCodes)
        replay(decision, proxy: proxy)
        if let code = decision.action, let binding = bindings[code] {
            DispatchQueue.main.async { [weak self] in self?.launch(binding) }
        }
        if code == 49, type == .keyUp { savedSpace = nil }
        return decision.consume ? nil : Unmanaged.passUnretained(event)
    }

    private func replay(_ decision: LeaderState.Decision, proxy: CGEventTapProxy) {
        if decision.replaySpaceDown, let down = savedSpace {
            down.tapPostEvent(proxy)
            savedSpace = nil
        }
    }

    private func launch(_ binding: Binding) {
        switch binding.kind {
        case .url:
            guard let url = URL(string: binding.target), NSWorkspace.shared.open(url) else {
                log("Could not open URL."); return
            }
        case .app:
            let url = URL(fileURLWithPath: binding.target)
            guard FileManager.default.fileExists(atPath: url.path) else {
                log("App does not exist: \(url.path)"); return
            }
            if binding.behavior != .activate, let id = Bundle(url: url)?.bundleIdentifier,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               app.isActive {
                if binding.behavior == .previous {
                    if let previousApp, !previousApp.isTerminated { previousApp.activate(options: []) }
                    else { app.hide() }
                } else { app.hide() }
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { log("Could not launch app: \(error.localizedDescription)") }
            }
        }
    }

    private func watchConfig() {
        // Watch the directory, so atomic saves that replace config.json also reload.
        let fd = Darwin.open(ConfigFile.url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { log("Cannot watch config; restart after editing."); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in
            self?.reloadConfig()
            self?.watchConfigFile()
        }
        watcher.setCancelHandler { Darwin.close(fd) }
        watcher.resume()
        self.watcher = watcher
        watchConfigFile()
    }

    private func reloadConfig() {
        do {
            apply(try ConfigFile.read())
            log("Configuration reloaded.")
        } catch { log("Config rejected; keeping previous settings: \(error.localizedDescription)") }
    }

    private func watchConfigFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = Darwin.open(ConfigFile.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .rename, .delete], queue: .main)
        watcher.setEventHandler { [weak self] in self?.reloadConfig() }
        watcher.setCancelHandler { Darwin.close(fd) }
        watcher.resume()
        fileWatcher = watcher
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
