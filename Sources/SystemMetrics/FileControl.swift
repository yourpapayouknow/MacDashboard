// 保存单级目录创建前的父目录身份与不存在目标。
public struct DirectorySnapshot: Codable, Equatable, Sendable {
    public let rootID: String
    public let relativePath: String
    public let parentPath: String
    public let name: String
    public let device: Int32
    public let inode: UInt64
}

// 保存普通文件的身份和修改状态。
public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let byteCount: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let permissions: UInt16
}

// 保存移动两端的父目录及源文件身份。
public struct MoveSnapshot: Codable, Equatable, Sendable {
    public let source: DirectorySnapshot
    public let destination: DirectorySnapshot
    public let identity: FileIdentity
}

// 保存回收前身份、系统废纸篓位置和结果回执标识。
public struct TrashSnapshot: Codable, Equatable, Sendable {
    public let source: DirectorySnapshot
    public let identity: FileIdentity
    public let trash: DirectorySnapshot
    public let receiptID: UUID
}

// 保存完整文本、原文件身份及写入后的预期摘要。
public struct TextSnapshot: Codable, Equatable, Sendable {
    public let source: DirectorySnapshot
    public let identity: FileIdentity
    public let data: Data
    public let writtenDigest: String
}

// 文件动作共用执行前状态和备份记录。
public enum FilePrepared: Sendable {
    case directory(DirectorySnapshot, BackupRecord)
    case file(DirectorySnapshot, Data, BackupRecord)
    case move(MoveSnapshot, BackupRecord)
    case restore(MoveSnapshot, BackupRecord)
    case text(TextSnapshot, Data, BackupRecord)
    case trash(TrashSnapshot, BackupRecord)

    // 交付同一任务日志所需的备份记录。
    public var backup: BackupRecord {
        switch self {
        case .directory(_, let backup), .file(_, _, let backup), .move(_, let backup), .restore(_, let backup), .text(_, _, let backup), .trash(_, let backup): return backup
        }
    }
}

// 文件创建复用固定目录读取与同一备份格式。
public struct FileController: Sendable {
    public static let actions: [MutationAction] = [.createDirectory, .createFile, .move, .write, .trash, .restore]
    private let reader: FileReader
    public let available: Bool

    // 限定既有可写根目录，禁止以root用户启动执行器。
    public init(roots: [FileRoot] = AdminReader().rdfiles()) {
        reader = FileReader(roots: roots)
        available = geteuid() != 0 && roots.contains { $0.isAvailable && $0.isWritable }
    }

    // 隔离测试只替换系统回收原语，其余身份与恢复校验保持一致。
    init(reader: FileReader) { self.reader = reader; available = geteuid() != 0 }

    // 拒绝绝对路径、穿越、空段、换行和超长名称。
    public static func validpath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 512 && !path.contains("\0") && !path.contains("\n") && !path.contains("\r")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }

    // 校验固定根标识与相对路径构成的确认目标。
    public static func validref(_ target: String) -> Bool {
        let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let root = String(parts[0])
        return !root.isEmpty && root.utf8.count <= 64 && root.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0)
        } && validpath(String(parts[1]))
    }

    // 文本摘要只接受完整ASCII十六进制值。
    public static func validdgt(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    // 文本保存与恢复共用字节上限和编码校验。
    static func validtxt(_ data: Data) -> Bool {
        data.count <= 262_144 && !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    // 文件预览和写入共用原生SHA256摘要。
    static func txtdgt(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // 文件动作共用精确参数和目标校验。
    public static func validpln(_ plan: MutationPlan) -> Bool {
        guard plan.domain == .file, validref(plan.target),
              plan.target == "\(plan.parameters["rootID"] ?? ""):\(plan.parameters["relativePath"] ?? "")" else { return false }
        if [.createDirectory, .trash].contains(plan.action) { return Set(plan.parameters.keys) == ["rootID", "relativePath"] }
        if plan.action == .createFile {
            return Set(plan.parameters.keys) == ["rootID", "relativePath", "content"]
                && validtxt(Data((plan.parameters["content"] ?? "").utf8))
        }
        if plan.action == .write {
            return Set(plan.parameters.keys) == ["rootID", "relativePath", "digest", "content"]
                && validdgt(plan.parameters["digest"] ?? "") && validtxt(Data((plan.parameters["content"] ?? "").utf8))
        }
        if plan.action == .restore {
            return Set(plan.parameters.keys) == ["rootID", "relativePath", "backupID"]
                && UUID(uuidString: plan.parameters["backupID"] ?? "") != nil
        }
        return plan.action == .move && Set(plan.parameters.keys) == ["rootID", "relativePath", "destinationRootID", "destinationRelativePath"]
            && validref("\(plan.parameters["destinationRootID"] ?? ""):\(plan.parameters["destinationRelativePath"] ?? "")")
    }

    // 备份真实状态后才交付固定文件动作。
    public func prpr(_ plan: MutationPlan, directory: URL) throws -> FilePrepared {
        guard available, Self.validpln(plan), let root = plan.parameters["rootID"],
              let path = plan.parameters["relativePath"] else { throw FileReadError.forbidden }
        if plan.action == .createDirectory {
            let snapshot = try reader.prmkdir(root, path: path)
            let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "directory-create-state", directory: directory)
            return .directory(snapshot, backup)
        }
        if plan.action == .createFile {
            let snapshot = try reader.prmkdir(root, path: path)
            let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-create-state", directory: directory)
            return .file(snapshot, Data(plan.parameters["content"]!.utf8), backup)
        }
        if plan.action == .trash {
            let snapshot = try reader.prtrsh(root, path: path)
            let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-trash-state", directory: directory)
            return .trash(snapshot, backup)
        }
        if plan.action == .write {
            let replacement = Data(plan.parameters["content"]!.utf8)
            let snapshot = try reader.prtxt(root, path: path, digest: plan.parameters["digest"]!, replacement: replacement)
            guard snapshot.data != replacement else { throw FileReadError.changed }
            let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-text-state", directory: directory)
            return .text(snapshot, replacement, backup)
        }
        if plan.action == .restore {
            let id = UUID(uuidString: plan.parameters["backupID"]!)!
            if let original = try? rdbkp(id, directory: directory, as: TrashSnapshot.self) {
                guard root == original.source.rootID, path == original.source.relativePath else { throw FileReadError.forbidden }
                let receipt = try rdbkp(original.receiptID, directory: directory, as: MoveSnapshot.self)
                guard receipt.source == original.source, receipt.identity == original.identity,
                      receipt.destination.rootID == original.trash.rootID,
                      receipt.destination.parentPath == original.trash.parentPath,
                      receipt.destination.device == original.trash.device,
                      receipt.destination.inode == original.trash.inode else { throw FileReadError.changed }
                let snapshot = try reader.prmv(receipt.destination.rootID, path: receipt.destination.relativePath,
                    destinationRoot: root, destinationPath: path)
                guard snapshot == MoveSnapshot(source: receipt.destination, destination: original.source, identity: original.identity),
                      try reader.trshid(snapshot.source) == original.identity else { throw FileReadError.changed }
                let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-trash-restore-state", directory: directory)
                return .restore(snapshot, backup)
            }
            guard let original = try? rdbkp(id, directory: directory, as: MoveSnapshot.self) else {
                let original = try JSONDecoder().decode(TextSnapshot.self,
                    from: rdbkpbytes(id, directory: directory, limit: 524_288))
                guard root == original.source.rootID, path == original.source.relativePath,
                      Self.validtxt(original.data), Self.validdgt(original.writtenDigest) else { throw FileReadError.forbidden }
                let snapshot = try reader.prtxt(root, path: path, digest: original.writtenDigest, replacement: original.data)
                guard snapshot.source == original.source, snapshot.identity.device == original.identity.device,
                      snapshot.identity.inode == original.identity.inode, snapshot.identity.permissions == original.identity.permissions else {
                    throw FileReadError.changed
                }
                let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-text-state", directory: directory)
                return .text(snapshot, original.data, backup)
            }
            guard root == original.destination.rootID, path == original.destination.relativePath else { throw FileReadError.forbidden }
            let snapshot = try reader.prmv(root, path: path, destinationRoot: original.source.rootID,
                destinationPath: original.source.relativePath)
            guard snapshot == MoveSnapshot(source: original.destination, destination: original.source, identity: original.identity) else {
                throw FileReadError.changed
            }
            let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-restore-state", directory: directory)
            return .restore(snapshot, backup)
        }
        let snapshot = try reader.prmv(root, path: path, destinationRoot: plan.parameters["destinationRootID"]!,
            destinationPath: plan.parameters["destinationRelativePath"]!)
        let backup = try wrtbkp(JSONEncoder().encode(snapshot), kind: "file-move-state", directory: directory)
        return .move(snapshot, backup)
    }

    // 原子创建后重读类型和所有者，失败保留实际错误码。
    public func act(_ prepared: FilePrepared) -> MutationResult {
        do {
            switch prepared {
            case .directory(let snapshot, _):
                try reader.mkdir(snapshot)
                return MutationResult(succeeded: true, message: "目录已创建", exitCode: 0)
            case .file(let snapshot, let content, _):
                try reader.mkfile(snapshot, content: content)
                return MutationResult(succeeded: true, message: "文本已创建", exitCode: 0)
            case .move(let snapshot, _):
                try reader.mv(snapshot)
                return MutationResult(succeeded: true, message: "文件已移动", exitCode: 0)
            case .restore(let snapshot, let backup):
                if backup.kind == "file-trash-restore-state" {
                    guard try reader.trshid(snapshot.source) == snapshot.identity else { throw FileReadError.changed }
                }
                try reader.mv(snapshot)
                return MutationResult(succeeded: true, message: "原位置已恢复", exitCode: 0)
            case .trash(let snapshot, let backup):
                let receipt = try reader.trsh(snapshot)
                _ = try wrtbkp(JSONEncoder().encode(receipt), kind: "file-trash-receipt",
                    directory: URL(fileURLWithPath: backup.path).deletingLastPathComponent(), id: snapshot.receiptID)
                return MutationResult(succeeded: true, message: "文件已移至废纸篓", exitCode: 0)
            case .text(let snapshot, let replacement, _):
                try reader.wrtxt(snapshot, replacement: replacement)
                return MutationResult(succeeded: true, message: "文本已保存", exitCode: 0)
            }
        } catch {
            let message: String
            if case .trash = prepared { message = "回收未确认，请检查废纸篓" }
            else { message = error is POSIXError ? "文件操作未完成，请检查实际状态" : "文件状态已改变，请重新确认" }
            return MutationResult(succeeded: false, message: message, exitCode: (error as? POSIXError).map { Int32($0.errorCode) })
        }
    }

    // 只从固定UUID备份读取完整原文。
    public static func rddwntxt(_ id: UUID, directory: URL) throws -> Data {
        let snapshot = try JSONDecoder().decode(TextSnapshot.self,
            from: rdbkpbytes(id, directory: directory, limit: 524_288))
        guard validtxt(snapshot.data) else { throw FileReadError.invalid }
        return snapshot.data
    }

}
