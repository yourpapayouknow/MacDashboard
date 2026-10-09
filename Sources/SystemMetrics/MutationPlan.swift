/// Administrative domain addressed by one narrow mutation plan.
public enum MutationDomain: String, Codable, CaseIterable, Sendable {
    case package, runtime, container, database, certificate, schedule, file, firewall, userGroup
}

/// Closed operation catalog shared by planning, authorization, and execution.
public enum MutationAction: String, Codable, CaseIterable, Sendable {
    case install, remove, upgrade, pin, unpin, setDefault
    case start, stop, restart, backup, restore
    case trust, untrust, enable, disable, stealthOn, stealthOff
    case createDirectory, createFile, move, write, trash, lock, unlock, addGroup, removeGroup
}

/// Lifecycle state for one immutable requested operation.
public enum MutationState: String, Codable, Sendable {
    case pending, queued, authorized, executing, succeeded, failed, rolledBack, expired
}

/// User-submitted request that can only create a non-executable pending plan.
public struct MutationPlanRequest: Codable, Equatable, Sendable {
    public let domain: MutationDomain
    public let action: MutationAction
    public let target: String
    public let parameters: [String: String]
    public let confirmation: String

    /// Creates one exact requested operation.
    public init(
        domain: MutationDomain,
        action: MutationAction,
        target: String,
        parameters: [String: String] = [:],
        confirmation: String
    ) {
        self.domain = domain
        self.action = action
        self.target = target
        self.parameters = parameters
        self.confirmation = confirmation
    }
}

/// Backup artifact attached by an executor before changing state.
public struct BackupRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let path: String
    public let createdAt: Date
    public let byteCount: UInt64
}

/// Persisted plan returned to the WebUI and consumed by the native broker.
public struct MutationPlan: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let domain: MutationDomain
    public let action: MutationAction
    public let target: String
    public let parameters: [String: String]
    public let state: MutationState
    public let backup: BackupRecord?
    public let rollbackToken: UUID?
    public let message: String
    public let exitCode: Int32?
}

/// Append-only owner-protected store for two-phase mutation plans.
public actor MutationPlanStore {
    private let path: String
    private let lifetime: TimeInterval

    /// Creates or opens one plan journal.
    public init(path: String, lifetime: TimeInterval = 600) throws {
        self.path = path
        self.lifetime = lifetime
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EPERM) }
    }

    /// Validates and persists one pending, non-executable plan.
    public func create(_ request: MutationPlanRequest, now: Date = Date()) throws -> MutationPlan {
        guard let error = Self.validate(request) else {
            let plan = MutationPlan(
                id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(lifetime),
                domain: request.domain, action: request.action, target: request.target,
                parameters: request.parameters, state: .pending, backup: nil,
                rollbackToken: nil, message: "Awaiting native administrator authorization", exitCode: nil
            )
            try append(plan)
            return plan
        }
        throw MutationPlanError.invalid(error)
    }

    /// Returns the newest bounded plans with pending expirations resolved in memory.
    public func recent(limit: Int, now: Date = Date()) throws -> [MutationPlan] {
        guard (1...1_000).contains(limit) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        var seen = Set<UUID>()
        return data.split(separator: 0x0A).reversed().compactMap {
            guard var plan = try? JSONDecoder().decode(MutationPlan.self, from: Data($0)),
                  seen.insert(plan.id).inserted else { return nil }
            if [.pending, .queued].contains(plan.state), plan.expiresAt <= now {
                plan = MutationPlan(
                    id: plan.id, createdAt: plan.createdAt, expiresAt: plan.expiresAt,
                    domain: plan.domain, action: plan.action, target: plan.target,
                    parameters: plan.parameters, state: .expired, backup: plan.backup,
                    rollbackToken: plan.rollbackToken, message: "Authorization window expired", exitCode: plan.exitCode
                )
            }
            return plan
        }.prefix(limit).map { $0 }
    }

    /// Returns one current plan by opaque identifier.
    public func get(_ id: UUID, now: Date = Date()) throws -> MutationPlan? {
        try recent(limit: 1_000, now: now).first { $0.id == id }
    }

    // 仅追加有效的执行状态转换，终态不可再次执行。
    public func trnstn(_ id: UUID, to state: MutationState, backup: BackupRecord? = nil,
        rollbackToken: UUID? = nil, message: String, exitCode: Int32? = nil, now: Date = Date()) throws -> MutationPlan {
        guard let current = try get(id, now: now) else { throw MutationPlanError.invalid("Unknown plan") }
        let allowed: [MutationState: Set<MutationState>] = [
            .pending: [.queued], .queued: [.authorized, .failed],
            .authorized: [.executing, .failed], .executing: [.succeeded, .failed],
        ]
        let recoverable = current.domain == .file && ([.move, .trash].contains(current.action)
            || [.write, .restore].contains(current.action) && current.backup?.kind == "file-text-state")
            || current.domain == .package && [.pin, .unpin].contains(current.action)
            || current.domain == .database && [.backup, .restore].contains(current.action)
        let restored = recoverable && current.state == .succeeded && state == .rolledBack
        guard (allowed[current.state]?.contains(state) == true || restored),
              state != .executing || ((backup ?? current.backup) != nil && (rollbackToken ?? current.rollbackToken) != nil) else {
            throw MutationPlanError.invalid("Invalid plan transition")
        }
        let plan = MutationPlan(id: current.id, createdAt: current.createdAt, expiresAt: current.expiresAt,
            domain: current.domain, action: current.action, target: current.target, parameters: current.parameters,
            state: state, backup: backup ?? current.backup, rollbackToken: rollbackToken ?? current.rollbackToken,
            message: message, exitCode: exitCode ?? current.exitCode)
        try append(plan)
        return plan
    }

    /// Appends one complete JSON journal record.
    private func append(_ plan: MutationPlan) throws {
        var data = try JSONEncoder().encode(plan)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Enforces domain/action/parameter and typed-confirmation boundaries.
    static func validate(_ request: MutationPlanRequest) -> String? {
        let actions: [MutationDomain: Set<MutationAction>] = [
            .package: [.install, .remove, .upgrade, .pin, .unpin, .restore],
            .runtime: [.install, .remove, .setDefault],
            .container: [.start, .stop, .restart, .remove],
            .database: [.start, .stop, .restart, .backup, .restore],
            .certificate: [.install, .remove, .trust, .untrust],
            .schedule: [.enable, .disable, .remove],
            .file: Set(FileController.actions),
            .firewall: [.enable, .disable, .stealthOn, .stealthOff],
            .userGroup: [.install, .remove, .lock, .unlock, .addGroup, .removeGroup],
        ]
        guard actions[request.domain]?.contains(request.action) == true else { return "Action is not valid for domain" }
        guard !request.target.isEmpty, request.target.count <= 512,
              !request.target.contains("\0"), !request.target.contains("\n") else { return "Invalid target" }
        let expected = "\(request.domain.rawValue):\(request.action.rawValue):\(request.target)"
        guard request.confirmation == expected else { return "Confirmation does not match exact operation" }
        let keys = Set(request.parameters.keys)
        let allowed: Set<String>
        switch request.domain {
        case .package: allowed = ["backupID", "kind"]
        case .runtime: allowed = ["version"]
        case .container: allowed = ["endpoint", "daemonID"]
        case .certificate: allowed = ["rootID", "relativePath", "destinationRootID", "destinationRelativePath"]
        case .file: allowed = ["rootID", "relativePath", "destinationRootID", "destinationRelativePath", "backupID", "digest", "content"]
        case .database: allowed = ["rootID", "relativePath", "backupID"]
        case .userGroup: allowed = ["group"]
        default: allowed = []
        }
        guard keys.isSubset(of: allowed), request.parameters.allSatisfy({ key, value in
            if key == "content", request.domain == .file, [.createFile, .write].contains(request.action) {
                return FileController.validtxt(Data(value.utf8))
            }
            return value.count <= 512 && !value.contains("\0") && !value.contains("\n")
        }) else {
            return "Unsupported parameters"
        }
        return nil
    }
}

/// Validation failures returned while creating a plan.
public enum MutationPlanError: Error, Equatable {
    case invalid(String)
}

// 复用不可覆盖的600权限备份，拒绝非所有者目录和符号链接。
func wrtbkp(_ data: Data, kind: String, directory: URL, suffix: String = "json", id: UUID = UUID()) throws -> BackupRecord {
    guard ["json", "sqlite", "zip"].contains(suffix) else { throw MutationPlanError.invalid("Unsupported backup type") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("\(id.uuidString).\(suffix)")
    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard root >= 0 else { throw MutationPlanError.invalid("Backup directory unavailable") }
    defer { close(root) }
    var attributes = stat()
    guard fstat(root, &attributes) == 0, attributes.st_uid == geteuid(),
          attributes.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw MutationPlanError.invalid("Unsafe backup directory") }
    let descriptor = openat(root, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw MutationPlanError.invalid("Backup unavailable") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    return BackupRecord(id: id, kind: kind, path: url.path, createdAt: Date(), byteCount: UInt64(data.count))
}

// 文件和软件恢复共用UUID限定的所有者备份读取。
func rdbkp<T: Decodable>(_ id: UUID, directory: URL, as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: rdbkpbytes(id, directory: directory))
}

// 固定UUID、格式和上限共用所有者普通备份读取。
func rdbkpbytes(_ id: UUID, directory: URL, suffix: String = "json", limit: Int = 16_384) throws -> Data {
    guard ["json", "sqlite", "zip"].contains(suffix), (1...33_554_432).contains(limit) else {
        throw MutationPlanError.invalid("Unsupported backup type")
    }
    let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw MutationPlanError.invalid("Backup unavailable") }
    defer { close(parent) }
    var root = stat()
    guard fstat(parent, &root) == 0, root.st_uid == geteuid(), root.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
        throw MutationPlanError.invalid("Unsafe backup directory")
    }
    let descriptor = openat(parent, "\(id.uuidString).\(suffix)", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw MutationPlanError.invalid("Backup unavailable") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
          info.st_mode & (S_IWGRP | S_IWOTH) == 0, info.st_size > 0, info.st_size <= limit else {
        throw MutationPlanError.invalid("Unsafe backup file")
    }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    var after = stat()
    guard data.count == info.st_size, fstat(descriptor, &after) == 0, after.st_size == info.st_size,
          after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
        throw MutationPlanError.invalid("Backup changed")
    }
    return data
}
