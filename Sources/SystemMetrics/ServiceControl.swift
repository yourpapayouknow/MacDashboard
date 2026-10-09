/// Fixed lifecycle operations accepted by the privileged service controller.
public enum ServiceAction: String, Codable, Equatable, Sendable {
    case start
    case stop
    case restart
}

/// Confirmed request sent across the narrow XPC boundary.
public struct ServiceActionRequest: Codable, Equatable, Sendable {
    public let id: String
    public let action: ServiceAction
    public let confirmation: String
    public let authorization: Data?

    /// Creates one explicit service lifecycle request.
    public init(id: String, action: ServiceAction, confirmation: String, authorization: Data? = nil) {
        self.id = id
        self.action = action
        self.confirmation = confirmation
        self.authorization = authorization
    }
}

/// Result of one privileged service lifecycle request.
public struct ServiceActionResult: Codable, Equatable, Sendable {
    public let id: String
    public let action: ServiceAction
    public let succeeded: Bool
    public let message: String
    public let exitCode: Int32?

    /// Creates one bounded lifecycle result.
    public init(id: String, action: ServiceAction, succeeded: Bool, message: String, exitCode: Int32?) {
        self.id = id
        self.action = action
        self.succeeded = succeeded
        self.message = message
        self.exitCode = exitCode
    }
}

/// One fixed executable invocation selected by validated service state.
struct ServiceCommand: Equatable, Sendable {
    let arguments: [String]
}

/// Executes validated launchd operations without accepting paths or commands from HTTP.
public struct ServiceController: Sendable {
    private let uid: uid_t
    private let roots: [(String, ServiceDefinitionSource)]

    /// Creates the root-side controller for the single allowed desktop user.
    public init(uid: uid_t) {
        self.uid = uid
        let home = Self.userhome(uid) ?? ""
        self.roots = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .systemAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
    }

    /// Creates a deterministic controller over fixture roots.
    init(uid: uid_t, roots: [(String, ServiceDefinitionSource)]) {
        self.uid = uid
        self.roots = roots
    }

    /// Validates, resolves, and executes one reversible launchd lifecycle operation.
    public func perform(_ request: ServiceActionRequest) -> ServiceActionResult {
        guard Self.validid(request.id), request.confirmation == request.id else {
            return fail(request, "Service id or confirmation is invalid", nil)
        }
        guard request.id != PrivilegedXPCClient.service else {
            return fail(request, "The active privileged helper cannot control itself", nil)
        }
        guard let definition = resolve(request.id) else {
            return fail(request, "Service is not present in an approved launchd directory", nil)
        }
        let target = target(definition)
        let loaded = run(["print", target]).exitCode == 0
        let disabled = disabled(definition)
        if (request.action == .start || request.action == .restart) && disabled {
            return fail(request, "Service is disabled; enable is a separate operation", nil)
        }
        let commands = Self.plan(definition: definition, action: request.action, target: target, loaded: loaded)
        for command in commands {
            let outcome = run(command.arguments)
            guard outcome.exitCode == 0 else {
                return fail(request, cleanerr(outcome.error), outcome.exitCode)
            }
        }
        return ServiceActionResult(
            id: request.id,
            action: request.action,
            succeeded: true,
            message: "Service \(request.action.rawValue) completed",
            exitCode: 0
        )
    }

    /// Builds only bootstrap, bootout, and kickstart commands for one resolved definition.
    static func plan(
        definition: ServiceDefinition,
        action: ServiceAction,
        target: String,
        loaded: Bool
    ) -> [ServiceCommand] {
        let domain = definition.source == .systemDaemon ? "system" : String(target.split(separator: "/").prefix(2).joined(separator: "/"))
        switch action {
        case .start:
            let bootstrap = loaded ? [] : [ServiceCommand(arguments: ["bootstrap", domain, definition.definitionPath])]
            return bootstrap + [ServiceCommand(arguments: ["kickstart", target])]
        case .stop:
            return loaded ? [ServiceCommand(arguments: ["bootout", target])] : []
        case .restart:
            // 已加载服务直接重启，避免卸载尚未完成时重复bootstrap。
            if loaded { return [ServiceCommand(arguments: ["kickstart", "-k", target])] }
            return [
                ServiceCommand(arguments: ["bootstrap", domain, definition.definitionPath]),
                ServiceCommand(arguments: ["kickstart", target]),
            ]
        }
    }

    /// Resolves an exact plist label from fixed user and system directories.
    private func resolve(_ id: String) -> ServiceDefinition? {
        LaunchServiceReader(roots: roots).rdall().first { $0.label == id }
    }

    /// Produces the native launchd service target for one definition source.
    private func target(_ definition: ServiceDefinition) -> String {
        definition.source == .systemDaemon ? "system/\(definition.label)" : "gui/\(uid)/\(definition.label)"
    }

    /// Reads the launchd database override before allowing start.
    private func disabled(_ definition: ServiceDefinition) -> Bool {
        if definition.isDisabled { return true }
        let domain = definition.source == .systemDaemon ? "system" : "gui/\(uid)"
        let outcome = run(["print-disabled", domain])
        return outcome.exitCode == 0 && ServiceInventoryReader.prtdsbl(outcome.output).contains(definition.label)
    }

    /// Executes only launchctl with controller-generated arguments.
    private func run(_ arguments: [String]) -> CommandOutcome {
        let allowed = ["print", "print-disabled", "bootstrap", "bootout", "kickstart"].contains(arguments.first ?? "")
        guard allowed else { return CommandOutcome(exitCode: -1, output: "", error: "Rejected command") }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        let finished = DispatchSemaphore(value: 0)
        do { try process.run() } catch {
            return CommandOutcome(exitCode: -1, output: "", error: "launchctl could not start")
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 25) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return CommandOutcome(exitCode: -2, output: "", error: "launchctl operation timed out")
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        return CommandOutcome(
            exitCode: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            error: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    /// Rejects traversal, separators, spaces, and unbounded service identifiers.
    public static func validid(_ id: String) -> Bool {
        guard (1...255).contains(id.count), id != ".", id != ".." else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || [".", "_", "-"].contains(Character($0))
        }
    }

    /// Returns one bounded error without exposing unrelated launchctl diagnostics.
    private func cleanerr(_ error: String) -> String {
        let first = error.split(separator: "\n").first.map(String.init) ?? "launchctl operation failed"
        return String(first.prefix(300))
    }

    /// Creates one consistent rejected or failed response.
    private func fail(_ request: ServiceActionRequest, _ message: String, _ exitCode: Int32?) -> ServiceActionResult {
        ServiceActionResult(
            id: request.id,
            action: request.action,
            succeeded: false,
            message: message,
            exitCode: exitCode
        )
    }

    /// Resolves the approved user's home directory without trusting process environment values.
    private static func userhome(_ uid: uid_t) -> String? {
        guard let record = getpwuid(uid), let directory = record.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }
}

/// Captured fixed-command result.
private struct CommandOutcome: Sendable {
    let exitCode: Int32
    let output: String
    let error: String
}
