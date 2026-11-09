import AppKit
import ApplicationServices

let help = """
SpaceRun — hold Space, press a key, launch an app or URL.

Getting started: spacerun install, then spacerun start, then spacerun edit.

  spacerun init                    Create a starter config
  spacerun edit [--settings]       Open the SpaceRun window (or its Settings)
  spacerun run                     Run in foreground; Ctrl-C stops
  spacerun bind KEY app /path/App.app [--toggle|--previous]
  spacerun bind KEY url https://example.com
  spacerun unbind KEY
  spacerun config                  Print config path
  spacerun check                   Validate config and app paths
  spacerun install                 Install binary and login-startup definition for you
  sudo spacerun install --all-users
                                   Install once for every user on this Mac (own config each)
  spacerun permissions             Request Accessibility access / open settings
  spacerun start                   Start/restart background service
  spacerun stop                    Stop background service for this login
  spacerun status                  Show background service state
  spacerun uninstall [--all-users] Remove service and binary; keep config

Settings: ~/.config/spacerun/config.json (reloaded automatically).
Hold Space and press ? to see all shortcuts.
Shortcuts use physical US/ANSI key positions. No updater or telemetry.
"""

/// With the service running, ask it to open the window, so there is only ever one. Otherwise (or
/// for a custom SPACERUN_CONFIG, which is not the service's) open it here. `--window` is how the
/// service starts the window process.
func edit(_ args: [String]) throws {
    let settings = args.contains("--settings")
    if !args.contains("--window"), Service.isRunning, !ConfigFile.isCustom {
        DistributedNotificationCenter.default().postNotificationName(
            Editor.showRequest, object: "\(getuid())", userInfo: settings ? ["pane": "settings"] : nil,
            deliverImmediately: true)
    } else {
        try Editor.run(settings: settings)
    }
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        // Opened from Finder (no terminal): show the editor rather than help nobody can see.
        if isatty(STDIN_FILENO) == 0 { try ConfigFile.initialize(); try edit([]) } else { print(help) }
        return
    }
    if ["help", "--help", "-h"].contains(command) { print(help); return }
    let known = ["init", "edit", "run", "bind", "unbind", "config", "check", "install", "permissions", "start", "stop", "status", "uninstall"]
    guard known.contains(command) else { throw Failure("Unknown command '\(command)'. Use --help.") }
    let allUsers = args.dropFirst().contains("--all-users")
    let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") })
    if command == "edit", !flags.isSubset(of: ["--window", "--settings"]) { throw Failure("Usage: spacerun edit [--settings]") }
    if allUsers, !["install", "uninstall"].contains(command) { throw Failure("--all-users only applies to install and uninstall.") }
    if command == "run", ProcessInfo.processInfo.environment["SPACERUN_SELF_LOG"] != nil {
        // Shared launch agent: launchd cannot point at each user's home, so open this user's log here.
        let log = Service.logFile
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 { dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); Darwin.close(fd) }
    }
    // Read-only and service-management commands do not create a config as a side effect.
    // An all-users install runs as root, so it must not create a config in root's home.
    if ["init", "edit", "run", "bind", "unbind"].contains(command) || (command == "install" && !allUsers) { try ConfigFile.initialize() }
    switch command {
    case "init": print(ConfigFile.url.path)
    case "config": print(ConfigFile.url.path)
    case "edit": try edit(args)
    case "run":
        let config = try ConfigFile.read()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory) // No Dock icon, but allowed to show the overlay.
        try Daemon(config: config).run()
    case "bind":
        guard args.count == 4 || (args.count == 5 && ["--toggle", "--previous"].contains(args[4]) && args[2] == "app"),
              let kind = Binding.Kind(rawValue: args[2]) else {
            throw Failure("Usage: spacerun bind KEY app /path/App.app [--toggle|--previous] OR spacerun bind KEY url https://example.com")
        }
        var config = try ConfigFile.read()
        let behavior: Binding.Behavior = args.count == 5 ? (args[4] == "--previous" ? .previous : .toggle) : .activate
        config.bindings[args[1].lowercased()] = Binding(kind: kind, target: args[3], behavior: behavior)
        try ConfigFile.write(config)
        print("Space + \(args[1].uppercased()) → \(args[3])")
    case "unbind":
        guard args.count == 2 else { throw Failure("Usage: spacerun unbind KEY") }
        var config = try ConfigFile.read()
        config.bindings.removeValue(forKey: args[1].lowercased())
        try ConfigFile.write(config)
    case "check":
        let config = try ConfigFile.read()
        var missing = false
        for (key, binding) in config.bindings.sorted(by: { $0.key < $1.key }) {
            let exists = binding.kind != .app || FileManager.default.fileExists(atPath: binding.target)
            print("\(exists ? "OK" : "MISSING")  Space + \(key.uppercased()) → \(binding.target)")
            missing = missing || !exists
        }
        if missing { throw Failure("Some app paths do not exist. Fix them with 'bind' or edit the config.") }
        print("Config valid. Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted for this process")")
    case "install": try allUsers ? Service.installShared() : Service.install()
    case "permissions":
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        print("Enable SpaceRun in Accessibility. If it is not listed, click + and choose:\n\(Service.app.path)\nThen run '\(Service.executable.path) start'.")
    case "start": try Service.start()
    case "stop": try Service.stop()
    case "status": try Service.status()
    case "uninstall": try allUsers ? Service.uninstallShared() : Service.uninstall()
    default: break
    }
}

do { try main() }
catch { log("Error: \(error.localizedDescription)"); exit(1) }
