import Foundation
import Darwin

enum Service {
    static let label = "local.spacerun"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    // Per-user install: only the user who installed it.
    static var userExecutable: URL { home.appendingPathComponent(".local/bin/spacerun") }
    static var userPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    // All-users install: one shared binary, started by launchd in every user's login session.
    // Each user still gets their own config, lock, and log under their own home folder.
    static let sharedExecutable = URL(fileURLWithPath: "/usr/local/bin/spacerun")
    static let sharedPlist = URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist")
    static var isShared: Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: userPlist.path) && fm.fileExists(atPath: sharedPlist.path)
    }
    static var executable: URL { isShared ? sharedExecutable : userExecutable }
    static var plist: URL { isShared ? sharedPlist : userPlist }
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

    static func loaded() throws -> Bool {
        try command("/bin/launchctl", ["print", identifier], checked: false).0 == 0
    }

    static func install() throws {
        guard getuid() != 0 else { throw Failure("Run 'install' as yourself, without sudo. To install for every user: sudo spacerun install --all-users") }
        if FileManager.default.fileExists(atPath: sharedPlist.path) {
            throw Failure("SpaceRun is already installed for all users (\(sharedPlist.path)). Just run: \(sharedExecutable.path) start")
        }
        if try loaded() { try stop() }
        let fm = FileManager.default
        for directory in [userExecutable.deletingLastPathComponent(), userPlist.deletingLastPathComponent(), logFile.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try copySelf(to: userExecutable)
        var definition = agentDefinition(executable: userExecutable)
        definition["StandardOutPath"] = logFile.path
        definition["StandardErrorPath"] = logFile.path
        // Only pin a config path when one was explicitly chosen; otherwise use the default in this user's home.
        if let custom = ProcessInfo.processInfo.environment["SPACERUN_CONFIG"] {
            definition["EnvironmentVariables"] = ["SPACERUN_CONFIG": URL(fileURLWithPath: custom).standardizedFileURL.path]
        }
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: userPlist, options: .atomic)
        print("""
        Installed: \(userExecutable.path)
        Config:    \(ConfigFile.url.path)

        Next:
          1. \(userExecutable.path) start   Start SpaceRun (asks for Accessibility access the first time)
          2. \(userExecutable.path) edit    Set up your own shortcuts
        """)
    }

    /// Installs one shared copy that launchd starts for every user at login. Needs sudo.
    static func installShared() throws {
        guard getuid() == 0 else { throw Failure("Installing for all users needs administrator access: sudo spacerun install --all-users") }
        let fm = FileManager.default
        try fm.createDirectory(at: sharedExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copySelf(to: sharedExecutable)
        var definition = agentDefinition(executable: sharedExecutable)
        // launchd cannot expand ~ here, so the service opens its own per-user log (see main.swift).
        definition["EnvironmentVariables"] = ["SPACERUN_SELF_LOG": "1"]
        definition["LimitLoadToSessionType"] = "Aqua"
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: sharedPlist, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: sharedPlist.path)

        // A per-user install with the same label would clash with the shared one.
        let homes = (try? fm.contentsOfDirectory(atPath: "/Users")) ?? []
        let clashes = homes.map { "/Users/\($0)/Library/LaunchAgents/\(label).plist" }.filter { fm.fileExists(atPath: $0) }
        print("""
        Installed for all users: \(sharedExecutable.path)
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

    private static func copySelf(to destination: URL) throws {
        let current = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        guard current != destination.resolvingSymlinksInPath() else { return }
        try Data(contentsOf: current).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", label, destination.path])
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
        let running = try command("/bin/launchctl", ["print", identifier], checked: false).1
            .split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" }
        if !output.isEmpty { print(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if output.contains("Waiting for Accessibility") {
            print("Grant access in the System Settings prompt; SpaceRun starts by itself once enabled. If spacerun is not listed, click +, press Cmd-Shift-G, and enter:\n\(executable.path)")
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

    static func stop() throws {
        if try loaded() { try command("/bin/launchctl", ["bootout", identifier]) }
        print("Stopped. Login startup remains enabled until 'spacerun uninstall'.")
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
        try stop()
        for file in [userPlist, userExecutable] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        print("Uninstalled. Your config and log were kept.")
    }

    static func uninstallShared() throws {
        guard getuid() == 0 else { throw Failure("Needs administrator access: sudo spacerun uninstall --all-users") }
        // Stop it in every login session that is running it.
        let processes = try command("/bin/ps", ["-axo", "uid=,comm="]).1
        let uids = Set(processes.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[1] == sharedExecutable.path ? parts[0] : nil
        })
        for uid in uids { try command("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], checked: false) }
        for file in [sharedPlist, sharedExecutable] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        print("Uninstalled for all users. Each user's config and log were kept.")
    }
}
