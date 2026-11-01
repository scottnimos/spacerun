import Foundation

struct Binding: Codable, Equatable {
    enum Kind: String, Codable { case app, url }
    enum Behavior: String, Codable { case activate, toggle, previous }
    var kind: Kind
    var target: String
    var behavior: Behavior = .activate

    init(kind: Kind, target: String, behavior: Behavior = .activate) {
        self.kind = kind; self.target = target; self.behavior = behavior
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        target = try values.decode(String.self, forKey: .target)
        behavior = try values.decodeIfPresent(Behavior.self, forKey: .behavior) ?? .activate
    }
}

struct Configuration: Codable {
    var typingCooldown: Double = 0.2
    var activationDelay: Double = 0.2
    var disabledApps: [String] = []
    var bindings: [String: Binding] = [
        "c": Binding(kind: .app, target: "/System/Applications/Calendar.app"),
        "f": Binding(kind: .app, target: "/System/Library/CoreServices/Finder.app"),
        "g": Binding(kind: .url, target: "https://github.com"),
        "m": Binding(kind: .app, target: "/System/Applications/Music.app", behavior: .toggle),
        "n": Binding(kind: .app, target: "/System/Applications/Notes.app", behavior: .toggle),
        "s": Binding(kind: .app, target: "/Applications/Safari.app", behavior: .toggle),
        "t": Binding(kind: .app, target: "/System/Applications/Utilities/Terminal.app", behavior: .toggle),
        "w": Binding(kind: .url, target: "https://en.wikipedia.org")
    ]

    func validate() throws {
        guard typingCooldown.isFinite, (0...5).contains(typingCooldown),
              activationDelay.isFinite, (0...5).contains(activationDelay) else {
            throw Failure("Delays must be between 0 and 5 seconds.")
        }
        for (key, binding) in bindings {
            guard KeyMap.codes[key] != nil else { throw Failure("Unsupported shortcut key: \(key)") }
            guard !binding.target.isEmpty else { throw Failure("Empty target for \(key).") }
            switch binding.kind {
            case .app:
                guard binding.target.hasPrefix("/"), binding.target.hasSuffix(".app") else {
                    throw Failure("App target for \(key) must be an absolute .app path.")
                }
            case .url:
                guard let url = URL(string: binding.target),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil else { throw Failure("URL for \(key) must be an http(s) address.") }
            }
        }
    }
}

enum KeyMap {
    // Physical ANSI key positions, so shortcuts stay predictable across input languages.
    static let codes: [String: UInt16] = [
        "a":0, "s":1, "d":2, "f":3, "h":4, "g":5, "z":6, "x":7, "c":8,
        "v":9, "b":11, "q":12, "w":13, "e":14, "r":15, "y":16, "t":17,
        "1":18, "2":19, "3":20, "4":21, "6":22, "5":23, "=":24, "9":25,
        "7":26, "-":27, "8":28, "0":29, "]":30, "o":31, "u":32, "[":33,
        "i":34, "p":35, "l":37, "j":38, "'":39, "k":40, ";":41, "\\":42,
        ",":43, "/":44, "n":45, "m":46, ".":47, "`":50
    ]
}

struct Failure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ConfigFile {
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["SPACERUN_CONFIG"] {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spacerun/config.json")
    }

    static func read() throws -> Configuration {
        try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Configuration {
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        try config.validate()
        return config
    }

    static func write(_ config: Configuration) throws {
        try config.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    /// True while the config still has only the built-in example shortcuts.
    static var isStarter: Bool { (try? read().bindings) == Configuration().bindings }

    static func initialize() throws {
        if !FileManager.default.fileExists(atPath: url.path) { try write(Configuration()) }
    }
}
