import Foundation

/// Backend modules derived from BaoTa's public route families.
public enum PanelModule: String, Codable, CaseIterable, Sendable {
    case system
    case monitoring
    case websites
    case databases
    case containers
    case files
    case schedules
    case certificates
    case services
    case environments
    case logs
    case security
    case terminal
    case backups
}

/// Implementation maturity exposed to future clients.
public enum ModuleState: String, Codable, Sendable {
    case ready
    case partial
    case planned
    case unavailable
}

/// One discoverable backend capability.
public struct ModuleInfo: Codable, Equatable, Sendable {
    public let id: PanelModule
    public let state: ModuleState
    public let readOnly: Bool

    /// Creates a capability descriptor.
    public init(id: PanelModule, state: ModuleState, readOnly: Bool) {
        self.id = id
        self.state = state
        self.readOnly = readOnly
    }
}

/// Produces the authoritative capability catalog.
public struct ModuleCatalog: Sendable {
    /// Creates the stateless catalog.
    public init() {}

    /// Lists every backend module in stable order.
    public func lstmods() -> [ModuleInfo] {
        [
            ModuleInfo(id: .system, state: .ready, readOnly: true),
            ModuleInfo(id: .monitoring, state: .partial, readOnly: true),
            ModuleInfo(id: .websites, state: .partial, readOnly: false),
            ModuleInfo(id: .databases, state: .partial, readOnly: false),
            ModuleInfo(id: .containers, state: .partial, readOnly: false),
            ModuleInfo(id: .files, state: .partial, readOnly: false),
            ModuleInfo(id: .schedules, state: .partial, readOnly: true),
            ModuleInfo(id: .certificates, state: .partial, readOnly: true),
            ModuleInfo(id: .services, state: .partial, readOnly: false),
            ModuleInfo(id: .environments, state: .partial, readOnly: false),
            ModuleInfo(id: .logs, state: .partial, readOnly: true),
            ModuleInfo(id: .security, state: .partial, readOnly: true),
            ModuleInfo(id: .terminal, state: .planned, readOnly: false),
            ModuleInfo(id: .backups, state: .planned, readOnly: false),
        ]
    }
}

/// Lifecycle states shared by all long-running backend work.
public enum TaskState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

/// A typed record for an asynchronous backend operation.
public struct PanelTask: Codable, Equatable, Sendable {
    public let id: UUID
    public let module: PanelModule
    public let action: String
    public let state: TaskState
    public let createdAt: Date
    public let updatedAt: Date
    public let target: String?
    public let message: String?
    public let exitCode: Int32?

    /// Creates an immutable task snapshot.
    public init(
        id: UUID,
        module: PanelModule,
        action: String,
        state: TaskState,
        createdAt: Date,
        updatedAt: Date,
        target: String? = nil,
        message: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.module = module
        self.action = action
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.target = target
        self.message = message
        self.exitCode = exitCode
    }
}

/// Stores in-process task snapshots until persistent storage is added.
public actor TaskStore {
    private var tasks: [UUID: PanelTask] = [:]

    /// Creates an empty task store.
    public init() {}

    /// Queues a typed task without executing arbitrary commands.
    public func mktsk(module: PanelModule, action: String, target: String? = nil) -> PanelTask {
        let now = Date()
        let task = PanelTask(
            id: UUID(),
            module: module,
            action: action,
            state: .queued,
            createdAt: now,
            updatedAt: now,
            target: target
        )
        tasks[task.id] = task
        if tasks.count > 100, let oldest = tasks.values.min(by: { $0.createdAt < $1.createdAt }) {
            tasks.removeValue(forKey: oldest.id)
        }
        return task
    }

    /// Advances one task without allowing a terminal task to execute twice.
    public func updtsk(_ id: UUID, state: TaskState, message: String, exitCode: Int32? = nil) -> PanelTask? {
        guard let old = tasks[id], old.state == .queued || old.state == .running else { return nil }
        guard (old.state == .queued && state == .running) ||
              (old.state == .running && [.succeeded, .failed, .cancelled].contains(state)) else { return nil }
        let task = PanelTask(id: old.id, module: old.module, action: old.action, state: state,
                             createdAt: old.createdAt, updatedAt: Date(), target: old.target,
                             message: message, exitCode: exitCode)
        tasks[id] = task
        return task
    }

    /// Returns one task for progress polling.
    public func rdtsk(_ id: UUID) -> PanelTask? { tasks[id] }

    /// Lists task snapshots newest first.
    public func lsttsks() -> [PanelTask] {
        tasks.values.sorted { $0.createdAt > $1.createdAt }
    }
}
