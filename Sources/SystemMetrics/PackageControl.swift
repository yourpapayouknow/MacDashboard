// 保存一次固定状态变更前的软件状态。
public struct PackageBackup: Codable, Equatable, Sendable {
    public let target: String
    public let versions: [String]
    public let pinned: Bool
    public let action: MutationAction
    public let pinDestination: String?
    public let kind: String?
    public let tap: String?

    // 旧formula备份省略类型，图形应用额外冻结来源。
    public init(target: String, versions: [String], pinned: Bool, action: MutationAction, pinDestination: String?,
        kind: String? = nil, tap: String? = nil) {
        self.target = target; self.versions = versions; self.pinned = pinned; self.action = action
        self.pinDestination = pinDestination; self.kind = kind; self.tap = tap
    }
}

// 将真实备份与执行前状态传递给授权代理。
public struct PackagePrepared: Sendable {
    public let snapshot: PackageBackup
    public let backup: BackupRecord
    public let rollbackToken: UUID
    public let pinRestoreDestination: String?
}

// 返回固定命令结果，成功必须通过重新读取状态确认。
public struct MutationResult: Sendable {
    public let succeeded: Bool
    public let message: String
    public let exitCode: Int32?
    // 生成不包含授权凭据或原始命令输出的结果。
    public init(succeeded: Bool, message: String, exitCode: Int32?) {
        self.succeeded = succeeded
        self.message = message
        self.exitCode = exitCode
    }
}

// 使用同一原生Homebrew执行器管理两类软件。
public struct PackageController: Sendable {
    public static let actions: [MutationAction] = [.install, .remove, .pin, .unpin, .upgrade, .restore]
    public let available: Bool
    private let command: @Sendable ([String]) -> NativeResult
    private let pinRoot: URL?

    // 复用环境模块定位到的标准Homebrew路径。
    public init() {
        let path = EnvironmentReader().brewPath
        pinRoot = path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("var/homebrew/pinned", isDirectory: true) }
        available = path != nil && geteuid() != 0
        command = { brewcmd(path, $0) }
    }

    // 注入不会修改真实软件的测试命令。
    init(command: @escaping @Sendable ([String]) -> NativeResult, pinRoot: URL? = nil) {
        available = true
        self.command = command
        self.pinRoot = pinRoot
    }

    // 拒绝参数、路径、非ASCII字符和过长的formula身份。
    public static func validid(_ id: String) -> Bool {
        id.count <= 255 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.+@-]*(/[A-Za-z0-9][A-Za-z0-9_.+@-]*){0,2}$"#,
            options: .regularExpression) == id.startIndex..<id.endIndex && !id.isEmpty
    }

    // 图形应用显式标记类型，恢复额外绑定原备份。
    public static func validpln(_ plan: MutationPlan) -> Bool {
        guard plan.domain == .package, validid(plan.target) else { return false }
        if plan.parameters["kind"] == "tap" { return TapController.validpln(plan) }
        let keys = Set(plan.parameters.keys)
        let cask = plan.parameters["kind"] == "cask"
        return [.install, .remove, .pin, .unpin, .upgrade].contains(plan.action) && (plan.parameters.isEmpty || cask && keys == ["kind"])
            || plan.action == .restore && (keys == ["backupID"] || cask && keys == ["kind", "backupID"])
                && UUID(uuidString: plan.parameters["backupID"] ?? "") != nil
    }

    // 两类软件共用精确标识、固定CLI及JSON解析。
    private func rdmeta(_ target: String, kind: String) -> ([BrewFormula], [BrewCask])? {
        guard available, Self.validid(target), ["formula", "cask"].contains(kind) else { return nil }
        let result = command(["info", "--json=v2", "--\(kind)", target])
        return result.code == 0 ? EnvironmentReader.parse(result.output) : nil
    }

    // 精确读取formula，查询和移除后核验可接受空安装版本。
    public func rdpkg(_ target: String, installed: Bool = true) -> BrewFormula? {
        guard let rows = rdmeta(target, kind: "formula"), rows.0.count == 1, rows.1.isEmpty,
              let row = rows.0.first, row.id == target, !installed || !row.versions.isEmpty else { return nil }
        return row
    }

    // 图形应用使用完整规范标识，不把读取失败当成未安装。
    public func rdcask(_ target: String, installed: Bool = true) -> BrewCask? {
        guard let rows = rdmeta(target, kind: "cask"), rows.1.count == 1, rows.0.isEmpty,
              let row = rows.1.first, row.id == target, !installed || row.installedVersion?.isEmpty == false else { return nil }
        return row
    }

    // 共享执行器只归一化两类软件真实存在的生命周期状态。
    private func rdstate(_ target: String, kind: String, installed: Bool = true)
        -> (id: String, versions: [String], pinned: Bool, outdated: Bool, disabled: Bool, tap: String)? {
        if kind == "cask" {
            guard let row = rdcask(target, installed: installed), let pinned = row.pinned, !row.tap.isEmpty, row.tap != "unknown" else { return nil }
            let versions = row.installedVersion.flatMap { $0.isEmpty ? nil : [$0] } ?? []
            return (row.id, versions, pinned, row.outdated, row.disabled, row.tap)
        }
        guard kind == "formula", let row = rdpkg(target, installed: installed) else { return nil }
        return (row.id, row.versions, row.pinned, row.outdated, row.disabled, row.tap)
    }

    // 两类软件分别使用Homebrew原生固定目录，保留精确版本链接。
    private func pindst(_ target: String, kind: String) -> String? {
        let root = kind == "cask" ? pinRoot?.deletingLastPathComponent().appendingPathComponent("pinned_casks") : pinRoot
        return root.flatMap { try? FileManager.default.destinationOfSymbolicLink(
            atPath: $0.appendingPathComponent(String(target.split(separator: "/").last ?? "")).path) }
    }

    // 在执行命令前保存不可覆盖的600权限状态备份。
    public func prpr(_ plan: MutationPlan, directory: URL) throws -> PackagePrepared {
        let kind = plan.parameters["kind"] ?? "formula"
        guard Self.validpln(plan),
              let row = rdstate(plan.target, kind: kind, installed: plan.action != .install) else { throw PackageError.unavailable }
        guard plan.action != .install || row.versions.isEmpty && !row.disabled && !row.pinned,
              plan.action != .remove || !row.pinned else { throw PackageError.unavailable }
        guard plan.action != .upgrade || row.outdated && !row.pinned && !row.disabled else { throw PackageError.unavailable }
        let destination = pindst(row.id, kind: kind)
        guard !row.pinned || pinRoot == nil || destination != nil else { throw PackageError.backup }
        let original: PackageBackup?
        if plan.action == .restore {
            original = try rdbkp(UUID(uuidString: plan.parameters["backupID"]!)!, directory: directory, as: PackageBackup.self)
            guard let original, original.target == row.id, (original.kind ?? "formula") == kind, original.versions == row.versions,
                  kind != "cask" || original.tap == row.tap,
                  [.pin, .unpin].contains(original.action), row.pinned == (original.action == .pin),
                  !original.pinned || original.versions.count == 1,
                  !original.pinned || pinRoot == nil || original.pinDestination != nil else { throw PackageError.unavailable }
        } else { original = nil }
        let action = original.map { $0.pinned ? MutationAction.pin : .unpin } ?? plan.action
        let snapshot = PackageBackup(target: row.id, versions: row.versions, pinned: row.pinned,
            action: action, pinDestination: destination, kind: kind == "cask" ? kind : nil, tap: kind == "cask" ? row.tap : nil)
        let data = try JSONEncoder().encode(snapshot)
        let backup: BackupRecord
        do {
            let prefix = kind == "cask" ? "homebrew-cask" : "homebrew"
            let suffix = [.install, .remove, .upgrade].contains(action) ? "\(action.rawValue)-state"
                : original == nil ? "pin-state" : "pin-restore-state"
            backup = try wrtbkp(data, kind: "\(prefix)-\(suffix)", directory: directory)
        }
        catch { throw PackageError.backup }
        return PackagePrepared(snapshot: snapshot, backup: backup, rollbackToken: backup.id,
            pinRestoreDestination: original?.pinned == true && pinRoot != nil ? original?.pinDestination : nil)
    }

    // 重读状态后执行固定操作，拒绝备份后发生的变化。
    public func act(_ prepared: PackagePrepared) -> MutationResult {
        let snapshot = prepared.snapshot
        let kind = snapshot.kind ?? "formula"
        guard let before = rdstate(snapshot.target, kind: kind, installed: snapshot.action != .install), before.versions == snapshot.versions,
              kind != "cask" || before.tap == snapshot.tap,
              before.pinned == snapshot.pinned, pindst(snapshot.target, kind: kind) == snapshot.pinDestination else {
            return MutationResult(succeeded: false, message: "软件状态已改变，请重新确认", exitCode: nil)
        }
        if snapshot.action == .upgrade && (!before.outdated || before.pinned || before.disabled) {
            return MutationResult(succeeded: false, message: "升级条件已改变，请重新确认", exitCode: nil)
        }
        if snapshot.action == .install && (!before.versions.isEmpty || before.disabled || before.pinned)
            || snapshot.action == .remove && before.pinned {
            return MutationResult(succeeded: false, message: "软件条件已改变，请重新确认", exitCode: nil)
        }
        let expected = snapshot.action == .pin
        if [.pin, .unpin].contains(snapshot.action) && before.pinned == expected {
            guard prepared.pinRestoreDestination == nil || pindst(snapshot.target, kind: kind) == prepared.pinRestoreDestination else {
                return MutationResult(succeeded: false, message: "原固定链接未确认", exitCode: nil)
            }
            return MutationResult(succeeded: true, message: "已处于目标固定状态", exitCode: 0)
        }
        let result = command([snapshot.action == .remove ? "uninstall" : snapshot.action.rawValue, "--\(kind)", snapshot.target])
        guard result.code == 0 else {
            return MutationResult(succeeded: false,
                message: result.code == -2 ? "Homebrew执行超时，请检查实际状态" : "Homebrew未完成操作，请检查实际状态",
                exitCode: result.code)
        }
        if snapshot.action == .remove {
            guard let after = rdstate(snapshot.target, kind: kind, installed: false), !after.pinned,
                  kind != "cask" || after.tap == snapshot.tap,
                  after.versions.count < snapshot.versions.count,
                  after.versions.allSatisfy({ snapshot.versions.contains($0) }) else {
                return MutationResult(succeeded: false, message: "移除结果未确认，请检查实际状态", exitCode: result.code)
            }
            return MutationResult(succeeded: true, message: after.versions.isEmpty ? "软件已移除" : "当前版本已移除", exitCode: result.code)
        }
        if [.install, .upgrade].contains(snapshot.action) {
            guard let after = rdstate(snapshot.target, kind: kind), !after.outdated, !after.pinned,
                  kind != "cask" || after.tap == snapshot.tap,
                  after.versions != snapshot.versions else {
                return MutationResult(succeeded: false, message: snapshot.action == .install ? "安装结果未确认，请检查实际状态" : "升级结果未确认，请检查实际状态", exitCode: result.code)
            }
            return MutationResult(succeeded: true, message: snapshot.action == .install ? "软件已安装" : "软件已升级", exitCode: result.code)
        }
        guard let after = rdstate(snapshot.target, kind: kind), after.pinned == expected,
              kind != "cask" || after.tap == snapshot.tap,
              after.versions == snapshot.versions,
              prepared.pinRestoreDestination == nil || pindst(snapshot.target, kind: kind) == prepared.pinRestoreDestination else {
            return MutationResult(succeeded: false, message: "固定状态未确认，请检查实际软件状态", exitCode: result.code)
        }
        return MutationResult(succeeded: true, message: expected ? "版本已固定" : "版本固定已解除", exitCode: result.code)
    }
}

// 区分不可用的软件状态和备份失败。
public enum PackageError: Error { case unavailable, backup }
