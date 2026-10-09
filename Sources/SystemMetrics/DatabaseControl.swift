// 数据库动作冻结原文件身份和执行前的原生快照。
public struct DatabasePrepared: Sendable {
    let source: DirectorySnapshot
    let identity: FileIdentity
    let replacement: UUID?
    let replacementData: Data?
    let directory: URL
    public let backup: BackupRecord
}

// SQLite文件备份和恢复共用既有根目录与备份安全边界。
public struct DatabaseController: Sendable {
    private let reader: FileReader
    public let available: Bool
    private static let limit = 33_554_432

    // 只以普通用户管理既有可写范围中的库文件。
    public init(roots: [FileRoot] = AdminReader().rdfiles()) {
        reader = FileReader(roots: roots)
        available = geteuid() != 0 && roots.contains { $0.isAvailable && $0.isWritable }
    }

    // 参数必须完整绑定同一根内文件，恢复只接收UUID。
    public static func validpln(_ plan: MutationPlan) -> Bool {
        guard plan.domain == .database, FileController.validref(plan.target),
              plan.target == "\(plan.parameters["rootID"] ?? ""):\(plan.parameters["relativePath"] ?? "")" else { return false }
        if plan.action == .backup { return Set(plan.parameters.keys) == ["rootID", "relativePath"] }
        return plan.action == .restore && Set(plan.parameters.keys) == ["rootID", "relativePath", "backupID"]
            && UUID(uuidString: plan.parameters["backupID"] ?? "") != nil
    }

    // 先保存包含已提交WAL数据的快照，恢复还保留当前内容。
    public func prpr(_ plan: MutationPlan, directory: URL) throws -> DatabasePrepared {
        guard available, Self.validpln(plan) else { throw FileReadError.forbidden }
        let (source, identity) = try reader.prdb(plan.parameters["rootID"]!, path: plan.parameters["relativePath"]!)
        let replacement = plan.action == .restore ? UUID(uuidString: plan.parameters["backupID"]!) : nil
        let data = try replacement.map { try Self.rddwn($0, directory: directory) }
        let backup = try Self.wrtsnp(source.parentPath + "/" + source.name, directory: directory)
        let (after, afterIdentity) = try reader.prdb(source.rootID, path: source.relativePath)
        guard after == source, identity.device == afterIdentity.device, identity.inode == afterIdentity.inode else {
            throw FileReadError.changed
        }
        return DatabasePrepared(source: source, identity: afterIdentity, replacement: replacement,
            replacementData: data, directory: directory, backup: backup)
    }

    // 身份与内容再次核对后，用同一原生快照接口事务恢复。
    public func act(_ prepared: DatabasePrepared) -> MutationResult {
        do {
            let before = try Self.rddwn(prepared.backup.id, directory: prepared.directory)
            guard before.count == prepared.backup.byteCount else { throw FileReadError.changed }
            if let id = prepared.replacement {
                let (source, identity) = try reader.prdb(prepared.source.rootID, path: prepared.source.relativePath)
                guard source == prepared.source, identity == prepared.identity,
                      try Self.rddwn(id, directory: prepared.directory) == prepared.replacementData else { throw FileReadError.changed }
                let target = source.parentPath + "/" + source.name
                let checked = try Self.wrtsnp(target, directory: prepared.directory)
                defer { try? FileManager.default.removeItem(atPath: checked.path) }
                guard try Self.rddwn(checked.id, directory: prepared.directory) == before else { throw FileReadError.changed }
                let backupReader = FileReader(roots: [FileRoot(id: "backup", path: prepared.directory.path, isAvailable: true, isWritable: true)])
                let (archive, _) = try backupReader.prdb("backup", path: id.uuidString + ".sqlite")
                let restored = try SqliteFile(archive.parentPath + "/" + archive.name)
                let destination = try SqliteFile(target, writable: true)
                guard sqlite3_db_readonly(destination.handle, "main") == 0 else { throw FileReadError.forbidden }
                let (current, currentIdentity) = try reader.prdb(source.rootID, path: source.relativePath)
                guard current == source, currentIdentity == identity else { throw FileReadError.changed }
                try Self.cpdb(destination.handle, restored.handle)
            }
            return MutationResult(succeeded: true, message: prepared.replacement == nil ? "数据库快照已保存" : "数据库内容已恢复", exitCode: 0)
        } catch {
            return MutationResult(succeeded: false, message: "库文件、内容或备份未确认，操作未完成", exitCode: nil)
        }
    }

    // 只读取固定备份目录的所有者普通SQLite附件。
    public static func rddwn(_ id: UUID, directory: URL) throws -> Data {
        let data = try rdbkpbytes(id, directory: directory, suffix: "sqlite", limit: limit)
        guard data.prefix(16) == Data("SQLite format 3\0".utf8) else { throw DatabaseError.header }
        return data
    }

    // 在排他创建的普通备份文件内完成原生快照并独立关闭事务。
    private static func wrtsnp(_ path: String, directory: URL) throws -> BackupRecord {
        let source = try SqliteFile(path)
        let backup = try wrtbkp(Data(), kind: "sqlite-snapshot", directory: directory, suffix: "sqlite")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(atPath: backup.path) } }
        let backupReader = FileReader(roots: [FileRoot(id: "backup", path: directory.path, isAvailable: true, isWritable: true)])
        let (archive, _) = try backupReader.prdb("backup", path: backup.id.uuidString + ".sqlite")
        let destination = try SqliteFile(archive.parentPath + "/" + archive.name, writable: true)
        try cpdb(destination.handle, source.handle)
        guard sqlite3_exec(destination.handle, "PRAGMA journal_mode=WAL; PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.native("snapshotJournal", sqlite3_errcode(destination.handle))
        }
        let data = try rddwn(backup.id, directory: directory)
        completed = true
        return BackupRecord(id: backup.id, kind: backup.kind, path: backup.path, createdAt: backup.createdAt, byteCount: UInt64(data.count))
    }

    // 固定PRAGMA只读取原生页大小，不接受用户SQL。
    private static func pgsz(_ handle: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, "PRAGMA page_size", -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw DatabaseError.native("pageSize", status)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FileReadError.invalid }
        let size = sqlite3_column_int(statement, 0)
        guard (512...65_536).contains(size), size & (size - 1) == 0 else { throw FileReadError.invalid }
        return size
    }

    // 分批快照限制容量和时间，未完成时finish回滚目的事务。
    private static func cpdb(_ destination: OpaquePointer, _ source: OpaquePointer) throws {
        let size = try pgsz(source)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseError.native("backupInit", sqlite3_errcode(destination))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var status = SQLITE_OK
        repeat {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                status = SQLITE_INTERRUPT; break
            }
            status = sqlite3_backup_step(backup, 64)
            if Int64(sqlite3_backup_pagecount(backup)) * Int64(size) > limit { status = SQLITE_TOOBIG; break }
        } while status == SQLITE_OK
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw DatabaseError.native("backupStep", status == SQLITE_DONE ? finished : status) }
    }
}

// 每个线程持有并关闭独立SQLite连接，不装载扩展或创建源库。
private final class SqliteFile {
    let handle: OpaquePointer

    // 原文件严格不跟随链接且禁止创建不存在的库。
    init(_ path: String, writable: Bool = false) throws {
        var connection: OpaquePointer?
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let status = sqlite3_open_v2(path, &connection, flags, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw DatabaseError.native("open", status)
        }
        handle = connection
        sqlite3_busy_timeout(handle, 1_000)
    }

    // 回收原生连接和已结束事务。
    deinit { sqlite3_close(handle) }
}

// 内部错误仅保留操作阶段和原生状态码，不记录数据或路径。
enum DatabaseError: Error { case header, native(String, Int32) }
