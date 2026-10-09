/// Native manager responsible for one background service.
public enum ServiceManager: String, Codable, Equatable, Sendable {
    case launchd
    case homebrew
}

/// Current lifecycle state reported by the service manager.
public enum ServiceState: String, Codable, Equatable, Sendable {
    case running
    case stopped
    case scheduled
    case error
    case unloaded
    case unknown
}

/// One launchd or Homebrew service with configuration and runtime evidence.
public struct ManagedService: Codable, Equatable, Sendable {
    public let id: String
    public let manager: ServiceManager
    public let source: ServiceDefinitionSource?
    public let state: ServiceState
    public let program: String?
    public let arguments: [String]
    public let definitionPath: String?
    public let isDisabled: Bool
    public let runAtLoad: Bool
    public let pid: Int32?
    public let runs: UInt64?
    public let lastExitCode: Int32?
    public let user: String?
}

/// Complete third-party service inventory from launchd and Homebrew.
public struct ServiceInventory: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let services: [ManagedService]
    public let homebrewAvailable: Bool
}

/// Reads all configured third-party launchd jobs plus Homebrew's JSON contract.
public struct ServiceInventoryReader: Sendable {
    private let launchReader: LaunchServiceReader
    private let brewPath: String?

    /// Creates the reader for standard launchd roots and the installed Homebrew binary.
    public init() {
        self.launchReader = LaunchServiceReader()
        self.brewPath = Self.findbrew()
    }

    /// Creates a deterministic reader for fixture-based tests.
    init(launchReader: LaunchServiceReader, brewPath: String?) {
        self.launchReader = launchReader
        self.brewPath = brewPath
    }

    /// Returns launchd first, current activity first, with Homebrew-only entries merged by label.
    public func read() -> ServiceInventory {
        let userDomain = "gui/\(getuid())"
        let userDisabled = run("/bin/launchctl", ["print-disabled", userDomain]).map(Self.prtdsbl) ?? []
        let systemDisabled = run("/bin/launchctl", ["print-disabled", "system"]).map(Self.prtdsbl) ?? []
        let launch = launchReader.rdall().map { definition in
            let disabled = definition.source == .systemDaemon ? systemDisabled : userDisabled
            return rdlaunch(definition, disabled)
        }
        let brew = brewPath.flatMap(rdbrew) ?? []
        let labels = Set(launch.map(\.id))
        let merged = launch + brew.filter { !labels.contains("homebrew.mxcl.\($0.id)") && !labels.contains($0.id) }
        return ServiceInventory(
            sampledAt: Date(),
            services: merged.sorted {
                if rank($0.state) != rank($1.state) { return rank($0.state) < rank($1.state) }
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            },
            homebrewAvailable: brewPath != nil
        )
    }

    /// Resolves one configured launchd job through its native domain target.
    private func rdlaunch(_ definition: ServiceDefinition, _ disabled: Set<String>) -> ManagedService {
        let target: String
        switch definition.source {
        case .systemDaemon: target = "system/\(definition.label)"
        case .userAgent, .systemAgent: target = "gui/\(getuid())/\(definition.label)"
        }
        let runtime = run("/bin/launchctl", ["print", target]).flatMap(Self.prtlch)
        return ManagedService(
            id: definition.label,
            manager: .launchd,
            source: definition.source,
            state: runtime?.state ?? .unloaded,
            program: definition.program,
            arguments: definition.arguments,
            definitionPath: definition.definitionPath,
            isDisabled: definition.isDisabled || disabled.contains(definition.label),
            runAtLoad: definition.runAtLoad,
            pid: runtime?.pid,
            runs: runtime?.runs,
            lastExitCode: runtime?.lastExitCode,
            user: nil
        )
    }

    /// Reads Homebrew's documented service JSON without invoking a shell.
    private func rdbrew(_ path: String) -> [ManagedService]? {
        guard let text = run(path, ["services", "list", "--json"]) else { return nil }
        return Self.prtbrew(text)
    }

    /// Parses stable launchctl print fields for one exact job target.
    static func prtlch(_ text: String) -> LaunchRuntime? {
        var state: ServiceState = .unknown
        var pid: Int32?
        var runs: UInt64?
        var exitCode: Int32?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("state = "), state == .unknown {
                let value = String(line.dropFirst("state = ".count))
                if value == "running" { state = .running }
                else if value == "not running" { state = .stopped }
                else if value == "spawn scheduled" { state = .scheduled }
            } else if line.hasPrefix("pid = ") {
                pid = Int32(line.dropFirst("pid = ".count))
            } else if line.hasPrefix("runs = ") {
                runs = UInt64(line.dropFirst("runs = ".count))
            } else if line.hasPrefix("last exit code = ") {
                exitCode = Int32(line.dropFirst("last exit code = ".count))
            }
        }
        return LaunchRuntime(state: state, pid: pid, runs: runs, lastExitCode: exitCode)
    }

    /// Parses Homebrew's five-field JSON service contract.
    static func prtbrew(_ text: String) -> [ManagedService] {
        guard let data = text.data(using: .utf8),
              let rows = try? JSONDecoder().decode([BrewService].self, from: data) else { return [] }
        return rows.map { row in
            ManagedService(
                id: row.name,
                manager: .homebrew,
                source: nil,
                state: brewstate(row.status),
                program: nil,
                arguments: [],
                definitionPath: row.file,
                isDisabled: false,
                runAtLoad: row.status == "started" || row.status == "scheduled",
                pid: nil,
                runs: nil,
                lastExitCode: row.exitCode,
                user: row.user
            )
        }
    }

    /// Parses only explicit disabled overrides from one launchd domain.
    static func prtdsbl(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix("=> disabled"),
                  let first = line.firstIndex(of: "\""),
                  let last = line[line.index(after: first)...].firstIndex(of: "\"") else { return nil }
            return String(line[line.index(after: first)..<last])
        })
    }

    /// Converts Homebrew status strings into the common lifecycle contract.
    private static func brewstate(_ value: String) -> ServiceState {
        switch value {
        case "started": .running
        case "stopped", "none": .stopped
        case "scheduled": .scheduled
        case "error": .error
        default: .unknown
        }
    }

    /// Runs one fixed read-only service inventory command.
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let isLaunch = path == "/bin/launchctl" && arguments.count == 2
            && ["print", "print-disabled"].contains(arguments[0])
        let isBrew = path == brewPath && arguments == ["services", "list", "--json"]
        guard isLaunch || isBrew else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Finds supported Apple Silicon or Intel Homebrew installations without using PATH.
    private static func findbrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Orders actionable failure and active states before inactive definitions.
    private func rank(_ state: ServiceState) -> Int {
        switch state {
        case .error: 0
        case .running: 1
        case .scheduled: 2
        case .stopped: 3
        case .unloaded: 4
        case .unknown: 5
        }
    }
}

/// Selected runtime fields from one launchctl print response.
struct LaunchRuntime: Equatable, Sendable {
    let state: ServiceState
    let pid: Int32?
    let runs: UInt64?
    let lastExitCode: Int32?
}

/// Homebrew's documented JSON service-list fields.
private struct BrewService: Decodable {
    let name: String
    let status: String
    let user: String?
    let file: String?
    let exitCode: Int32?

    private enum CodingKeys: String, CodingKey {
        case name, status, user, file
        case exitCode = "exit_code"
    }
}
