import Foundation
import Darwin
import ImageIO

enum Service {
    static let label = "local.spacerun"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    // Per-user install: only the user who installed it.
    static var userApp: URL { home.appendingPathComponent("Applications/SpaceRun.app") }
    static var userExecutable: URL { home.appendingPathComponent(".local/bin/spacerun") }
    static var userPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    // All-users install: one shared app, started by launchd in every user's login session.
    // Each user still gets their own config, lock, and log under their own home folder.
    static let sharedApp = URL(fileURLWithPath: "/Applications/SpaceRun.app")
    static let sharedExecutable = URL(fileURLWithPath: "/usr/local/bin/spacerun")
    static let sharedPlist = URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist")
    static var isShared: Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: userPlist.path) && fm.fileExists(atPath: sharedPlist.path)
    }
    /// The command-line link (`spacerun`), pointing into the app.
    static var executable: URL { isShared ? sharedExecutable : userExecutable }
    static var app: URL { isShared ? sharedApp : userApp }
    static var plist: URL { isShared ? sharedPlist : userPlist }
    static func binary(in app: URL) -> URL { app.appendingPathComponent("Contents/MacOS/spacerun") }
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static var logFile: URL { home.appendingPathComponent("Library/Logs/SpaceRun.log") }
    static var domain: String { "gui/\(getuid())" }
    static var identifier: String { "\(domain)/\(label)" }

    @discardableResult
    static func command(_ executable: String, _ arguments: [String], checked: Bool = true) throws -> (Int32, String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        if checked, task.terminationStatus != 0 { throw Failure(output.isEmpty ? "Command failed: \(executable)" : output) }
        return (task.terminationStatus, output)
    }

    /// True when the background service is loaded and its process is running.
    static var isRunning: Bool {
        ((try? command("/bin/launchctl", ["print", identifier], checked: false).1) ?? "")
            .split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" }
    }

    static func loaded() throws -> Bool {
        try command("/bin/launchctl", ["print", identifier], checked: false).0 == 0
    }

    static func install() throws {
        guard getuid() != 0 else { throw Failure("Run 'install' as yourself, without sudo. To install for every user: sudo spacerun install --all-users") }
        if FileManager.default.fileExists(atPath: sharedPlist.path) {
            throw Failure("SpaceRun is already installed for all users (\(sharedPlist.path)). Just run: \(sharedExecutable.path) start")
        }
        if try loaded() { try stop(quietly: true) }
        let fm = FileManager.default
        for directory in [userPlist.deletingLastPathComponent(), logFile.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try installApp(at: userApp, link: userExecutable)
        var definition = agentDefinition(executable: binary(in: userApp))
        definition["StandardOutPath"] = logFile.path
        definition["StandardErrorPath"] = logFile.path
        // Only pin a config path when one was explicitly chosen; otherwise use the default in this user's home.
        if let custom = ProcessInfo.processInfo.environment["SPACERUN_CONFIG"] {
            definition["EnvironmentVariables"] = ["SPACERUN_CONFIG": URL(fileURLWithPath: custom).standardizedFileURL.path]
        }
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: userPlist, options: .atomic)
        let pathNote = addToPath()
        print("""
        Installed: \(userApp.path)
        Command:   \(userExecutable.path)
        Config:    \(ConfigFile.url.path)

        Next:
          1. \(userExecutable.path) start   Start SpaceRun (asks for Accessibility access the first time)
          2. \(userExecutable.path) edit    Set up your own shortcuts
        """)
        if let pathNote { print("\n" + pathNote) }
    }

    // MARK: Shell PATH (per-user install only; /usr/local/bin is already on everyone's PATH)

    private static let pathMarker = "# added by spacerun install"
    private static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\" \(pathMarker)"

    /// The startup file of the user's login shell, if it is one we know how to edit.
    private static var shellProfile: URL? {
        switch URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent {
        case "zsh": return home.appendingPathComponent(".zshrc")
        case "bash": return home.appendingPathComponent(".bash_profile")
        default: return nil
        }
    }

    /// Lets the user type just `spacerun`. Returns a note to print, or nil if nothing was needed.
    private static func addToPath() -> String? {
        let directory = userExecutable.deletingLastPathComponent().path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if path.contains(directory) || path.contains(directory + "/") { return nil }
        guard let profile = shellProfile else {
            return "To type just 'spacerun', add \(directory) to your shell's PATH."
        }
        let existing = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        if existing.contains(pathMarker) { return "Open a new terminal window to type just 'spacerun'." }
        // Append (rather than rewrite) so a symlinked dotfile stays a symlink.
        let text = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + pathLine + "\n"
        if !FileManager.default.fileExists(atPath: profile.path) { FileManager.default.createFile(atPath: profile.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: profile) else {
            return "Could not update \(profile.path). To type just 'spacerun', add \(directory) to your PATH."
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data(text.utf8))
        return "Added \(directory) to your PATH in \(profile.path). Open a new terminal window to type just 'spacerun'."
    }

    /// Removes only the line 'install' added.
    private static func removeFromPath() {
        guard let profile = shellProfile?.resolvingSymlinksInPath(),
              let text = try? String(contentsOf: profile, encoding: .utf8), text.contains(pathMarker) else { return }
        let kept = text.components(separatedBy: "\n").filter { !$0.hasSuffix(pathMarker) }.joined(separator: "\n")
        do {
            try kept.write(to: profile, atomically: true, encoding: .utf8)
            print("Removed SpaceRun's PATH line from \(profile.path).")
        } catch {
            log("Could not update \(profile.path): \(error.localizedDescription)")
        }
    }

    /// Installs one shared copy that launchd starts for every user at login. Needs sudo.
    static func installShared() throws {
        guard getuid() == 0 else { throw Failure("Installing for all users needs administrator access: sudo spacerun install --all-users") }
        let fm = FileManager.default
        try installApp(at: sharedApp, link: sharedExecutable)
        var definition = agentDefinition(executable: binary(in: sharedApp))
        // launchd cannot expand ~ here, so the service opens its own per-user log (see main.swift).
        definition["EnvironmentVariables"] = ["SPACERUN_SELF_LOG": "1"]
        definition["LimitLoadToSessionType"] = "Aqua"
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: sharedPlist, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: sharedPlist.path)

        // A per-user install with the same label would clash with the shared one.
        let homes = (try? fm.contentsOfDirectory(atPath: "/Users")) ?? []
        let clashes = homes.map { "/Users/\($0)/Library/LaunchAgents/\(label).plist" }.filter { fm.fileExists(atPath: $0) }
        print("""
        Installed for all users: \(sharedApp.path)
        Command: \(sharedExecutable.path)
        Each user gets their own shortcuts in ~/.config/spacerun/config.json, created on first start.

        Next, for each user (as that user, without sudo):
          1. \(sharedExecutable.path) start   Or just log out and back in
          2. \(sharedExecutable.path) edit    Set up their own shortcuts
        Allowing Accessibility in System Settings needs an administrator password for standard users.
        """)
        if !clashes.isEmpty {
            print("\nThese users still have a per-user install, which takes priority. Have each run '~/.local/bin/spacerun uninstall':")
            clashes.forEach { print("  \($0)") }
        }
    }

    /// Builds SpaceRun.app around this executable and links `spacerun` to it. Being an app gives
    /// SpaceRun a name and icon in Privacy & Security, and a bundle ID that 'uninstall' can use to
    /// remove its permission entries again.
    private static func installApp(at app: URL, link: URL) throws {
        let fm = FileManager.default
        // Read first: we may be running from the app we are about to replace.
        let current = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let executableData = try Data(contentsOf: current)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": label,
            "CFBundleName": "SpaceRun",
            "CFBundleDisplayName": "SpaceRun",
            "CFBundleExecutable": "spacerun",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": true, // No Dock icon for the background service.
            "NSHighResolutionCapable": true
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try writeIcon(to: resources.appendingPathComponent("AppIcon.icns"))
        let binary = binary(in: app)
        try executableData.write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", label, app.path])
        try command(lsregister, ["-f", app.path], checked: false)

        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? link.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: binary)
    }

    private static func writeIcon(to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(AppIconData.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.apple.icns" as CFString, 5, nil)
        else { throw Failure("Could not create the app icon.") }
        for size in [16, 32, 128, 256, 512] {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            if let scaled = context.makeImage() { CGImageDestinationAddImage(destination, scaled, nil) }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure("Could not write the app icon.") }
    }

    /// Removes SpaceRun's entries from Privacy & Security, so uninstalling leaves nothing behind.
    /// Must run while the app is still registered, because tccutil looks it up by bundle ID.
    private static func resetPermissions(asUser user: String? = nil) {
        for service in ["Accessibility", "ListenEvent"] {
            let result = user.map { try? command("/usr/bin/sudo", ["-u", $0, "/usr/bin/tccutil", "reset", service, label], checked: false) }
                ?? (try? command("/usr/bin/tccutil", ["reset", service, label], checked: false))
            if let result, result.0 != 0 {
                log("Could not remove the \(service == "ListenEvent" ? "Input Monitoring" : service) entry: \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    private static func removeApp(_ app: URL, link: URL) throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        if fm.fileExists(atPath: app.path) {
            try command(lsregister, ["-u", app.path], checked: false)
            try fm.removeItem(at: app)
        }
    }

    private static func agentDefinition(executable: URL) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executable.path, "run"], "RunAtLoad": true, "ProcessType": "Interactive"]
    }

    static func start() throws {
        guard getuid() != 0 else { throw Failure("Run 'start' as the user who wants SpaceRun, without sudo.") }
        guard FileManager.default.fileExists(atPath: plist.path) else { throw Failure("Run 'spacerun install' first.") }
        let logStart = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? UInt64) ?? 0
        if try loaded() {
            try command("/bin/launchctl", ["kickstart", "-k", identifier])
        } else {
            try command("/bin/launchctl", ["bootstrap", domain, plist.path])
        }
        // Give the service a moment, then report what it actually did rather than just "requested".
        var output = ""
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            output = newLog(since: logStart)
            if output.contains("Running.") || output.contains("Waiting for Accessibility") || output.contains("Error:") { break }
        }
        let running = isRunning
        if !output.isEmpty { print(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if output.contains("Waiting for Accessibility") {
            print("Grant access in the System Settings prompt; SpaceRun starts by itself once enabled. If SpaceRun is not listed, click + and choose:\n\(app.path)")
        } else if !running {
            throw Failure("SpaceRun is not running. See \(logFile.path)")
        }
        if ConfigFile.isStarter {
            print("\nYou have the example shortcuts. Run '\(executable.path) edit' to set up your own.\nHold Space and press ? to see them all.")
        }
    }

    private static func newLog(since offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: offset <= size ? offset : 0) // Log was truncated: read it all.
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    static func stop(quietly: Bool = false) throws {
        if try loaded() { try command("/bin/launchctl", ["bootout", identifier]) }
        if !quietly { print("Stopped. Login startup remains enabled until 'spacerun uninstall'.") }
    }

    static func status() throws {
        let (code, output) = try command("/bin/launchctl", ["print", identifier], checked: false)
        if code != 0 { print("Background service is not loaded."); return }
        for line in output.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("state =") || value.hasPrefix("pid =") || value.hasPrefix("last exit code =") {
                print(value)
            }
        }
        print("Log: \(logFile.path)")
    }

    static func uninstall() throws {
        if isShared { throw Failure("SpaceRun is installed for all users. Remove it with: sudo \(sharedExecutable.path) uninstall --all-users") }
        try stop(quietly: true)
        resetPermissions()
        if FileManager.default.fileExists(atPath: userPlist.path) { try FileManager.default.removeItem(at: userPlist) }
        try removeApp(userApp, link: userExecutable)
        removeFromPath()
        print("Uninstalled, and removed SpaceRun from Privacy & Security. Your config and log were kept.")
    }

    static func uninstallShared() throws {
        guard getuid() == 0 else { throw Failure("Needs administrator access: sudo spacerun uninstall --all-users") }
        // Stop it in every login session that is running it.
        let processes = try command("/bin/ps", ["-axo", "uid=,comm="]).1
        let uids = Set(processes.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[1] == binary(in: sharedApp).path ? parts[0] : nil
        })
        for uid in uids { try command("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], checked: false) }
        // Accessibility is stored once for the whole Mac; Input Monitoring is stored per user.
        resetPermissions()
        let fm = FileManager.default
        for user in (try? fm.contentsOfDirectory(atPath: "/Users")) ?? [] where user != "Shared" && !user.hasPrefix(".") {
            if fm.fileExists(atPath: "/Users/\(user)/.config/spacerun") { resetPermissions(asUser: user) }
        }
        if fm.fileExists(atPath: sharedPlist.path) { try fm.removeItem(at: sharedPlist) }
        try removeApp(sharedApp, link: sharedExecutable)
        print("Uninstalled for all users, and removed SpaceRun from Privacy & Security. Each user's config and log were kept.")
    }
}
