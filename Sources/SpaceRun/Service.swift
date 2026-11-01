import Foundation
import Darwin

enum Service {
    static let label = "local.spacerun"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var executable: URL { home.appendingPathComponent(".local/bin/spacerun") }
    static var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
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
        if try loaded() { try stop() }
        let fm = FileManager.default
        for directory in [executable.deletingLastPathComponent(), plist.deletingLastPathComponent(), logFile.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let current = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        if current != executable.resolvingSymlinksInPath() {
            try Data(contentsOf: current).write(to: executable, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", label, executable.path])
        }
        let definition: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "run"],
            "EnvironmentVariables": ["SPACERUN_CONFIG": ConfigFile.url.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        print("Installed: \(executable.path)\nConfig: \(ConfigFile.url.path)\nNext: \(executable.path) start  (asks for Accessibility access on first run)")
    }

    static func start() throws {
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
        try stop()
        for file in [plist, executable] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        print("Uninstalled. Your config and log were kept.")
    }
}
