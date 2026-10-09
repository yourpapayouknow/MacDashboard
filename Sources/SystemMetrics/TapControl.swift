// 保留软件源的原生身份及移除条件。
public struct BrewTap: Codable, Equatable, Sendable {
    public let name: String
    public let installed: Bool
    public let path: String
    public let remote: String?
    public let head: String?
    public let removable: Bool
    public let reason: String
}

// 源操作沿用现有计划、备份和授权代理。
public struct TapPrepared: Sendable {
    let state: BrewTap
    let action: MutationAction
    let stamp: String?
    public let backup: BackupRecord
}

// 使用原生Homebrew和ditto管理软件源，禁止连带卸载。
public struct TapController: Sendable {
    private let command: @Sendable ([String]) -> NativeResult

    // 复用软件执行器的固定路径、超时与非交互环境。
    public init() {
        let path = geteuid() == 0 ? nil : EnvironmentReader().brewPath
        command = { brewcmd(path, $0) }
    }

    // 注入只修改隔离目录的测试命令。
    init(command: @escaping @Sendable ([String]) -> NativeResult) { self.command = command }

    // 只接受Homebrew规范的小写GitHub源身份。
    public static func validid(_ name: String) -> Bool {
        name.count <= 255 && name.range(of: #"^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$"#,
            options: .regularExpression) == name.startIndex..<name.endIndex
            && !String(name.split(separator: "/").last ?? "").hasPrefix("homebrew-")
            && !String(name.split(separator: "/").last ?? "").hasPrefix("linuxbrew-")
    }

    // 添加与移除仅接受一个类型参数，不支持强制或自动恢复。
    public static func validpln(_ plan: MutationPlan) -> Bool {
        plan.domain == .package && validid(plan.target) && [.install, .remove].contains(plan.action)
            && plan.parameters == ["kind": "tap"]
    }

    // 查询精确源及软件占用，不把读取失败当成空清单。
    public func rdtap(_ name: String) -> BrewTap? {
        guard Self.validid(name) else { return nil }
        let result = command(["tap-info", "--json", name])
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let rows = try? JSONDecoder().decode([TapRow].self, from: data), rows.count == 1,
              let row = rows.first, row.name == name else { return nil }
        var reason = ""
        if !row.installed { reason = "源尚未安装" }
        else if row.official || name.hasPrefix("homebrew/") { reason = "官方源受保护" }
        else if row.customRemote != false || row.remote != "https://github.com/\(name.replacingOccurrences(of: "/", with: "/homebrew-"))" {
            reason = "自定义来源受保护"
        } else {
            let inventory = command(["info", "--json=v2", "--installed"])
            let packages = inventory.code == 0 ? EnvironmentReader.parse(inventory.output) : nil
            if packages == nil { reason = "软件占用未确认" }
            else if let packages, packages.0.contains(where: { $0.tap == name && !$0.versions.isEmpty || $0.tap == "unknown" })
                    || packages.1.contains(where: { $0.tap == name && $0.installedVersion?.isEmpty == false || $0.tap == "unknown" }) {
                reason = "源仍有已安装软件"
            } else if !sfpth(row) || stmp(row.path) == nil { reason = "仓库备份条件未满足" }
        }
        return BrewTap(name: row.name, installed: row.installed, path: row.path, remote: row.remote,
            head: row.head, removable: reason.isEmpty, reason: reason)
    }

    // 仅管理Homebrew仓库内同一所有者的真实源目录。
    private func sfpth(_ row: TapRow) -> Bool {
        let repository = command(["--repository"])
        let root = repository.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.code == 0, root.hasPrefix("/"), !root.contains("\n"), !root.contains("\0") else { return false }
        let parts = row.name.split(separator: "/")
        let expected = URL(fileURLWithPath: root).appendingPathComponent("Library/Taps/\(parts[0])/homebrew-\(parts[1])")
        let git = expected.appendingPathComponent(".git")
        var info = stat()
        guard row.path == expected.path && expected.resolvingSymlinksInPath().path == row.path
            && lstat(row.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid()
            && info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        return lstat(git.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && !FileManager.default.fileExists(atPath: git.appendingPathComponent("commondir").path)
            && !FileManager.default.fileExists(atPath: git.appendingPathComponent("objects/info/alternates").path)
    }

    // 有界读取仓库文件与链接，冻结内容、身份、权限和修改时间。
    private func stmp(_ path: String) -> String? {
        let root = URL(fileURLWithPath: path)
        var failed = false
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var values: [String] = []
        var total = 0
        for case let url as URL in entries {
            guard values.count < 8_192 else { return nil }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid() else { return nil }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFLNK || info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return nil }
            let content: String
            if kind == S_IFREG {
                guard info.st_size >= 0, info.st_size <= 16_777_216 - total else { return nil }
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { return nil }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let data = try? handle.read(upToCount: Int(info.st_size) + 1)
                try? handle.close()
                guard let data, data.count == info.st_size else { return nil }
                total += data.count
                content = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else if kind == S_IFLNK {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
                content = target
            } else if kind == S_IFDIR { content = "" }
            else { return nil }
            values.append("\(url.path.dropFirst(path.count))\0\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)\0\(content)")
        }
        guard !failed, !values.isEmpty else { return nil }
        return SHA256.hash(data: Data(values.sorted().joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // 添加保存原状态，移除先归档完整仓库并复核同一内容。
    public func prpr(_ plan: MutationPlan, directory: URL) throws -> TapPrepared {
        guard Self.validpln(plan), let row = rdtap(plan.target),
              plan.action == .install ? !row.installed : row.removable else { throw PackageError.unavailable }
        if plan.action == .install {
            let backup = try wrtbkp(JSONEncoder().encode(row), kind: "homebrew-tap-install-state", directory: directory)
            return TapPrepared(state: row, action: plan.action, stamp: nil, backup: backup)
        }
        guard let before = stmp(row.path) else { throw PackageError.backup }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("repository.zip")
        guard runcmd("/usr/bin/ditto", ["-c", "-k", "--keepParent", row.path, archive.path], timeout: 60).code == 0,
              let size = try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 33_554_432,
              let data = try? Data(contentsOf: archive), data.count == size, stmp(row.path) == before,
              rdtap(plan.target) == row else { throw PackageError.backup }
        let backup = try wrtbkp(data, kind: "homebrew-tap-repository", directory: directory, suffix: "zip")
        return TapPrepared(state: row, action: plan.action, stamp: before, backup: backup)
    }

    // 执行固定无强制命令，零退出还需精确重读实际状态。
    public func act(_ prepared: TapPrepared) -> MutationResult {
        let row = prepared.state
        guard rdtap(row.name) == row, prepared.action != .remove || stmp(row.path) == prepared.stamp else {
            return MutationResult(succeeded: false, message: "源或软件状态已改变", exitCode: nil)
        }
        let result = command([prepared.action == .install ? "tap" : "untap", row.name])
        guard result.code == 0 else {
            return MutationResult(succeeded: false, message: "源操作未完成，请检查实际状态", exitCode: result.code)
        }
        guard let after = rdtap(row.name), after.path == row.path, after.installed == (prepared.action == .install),
              prepared.action != .remove || !FileManager.default.fileExists(atPath: row.path),
              prepared.action != .install || after.remote == "https://github.com/\(row.name.replacingOccurrences(of: "/", with: "/homebrew-"))" else {
            return MutationResult(succeeded: false, message: "源操作结果未确认", exitCode: result.code)
        }
        return MutationResult(succeeded: true, message: prepared.action == .install ? "软件源已添加" : "软件源已移除", exitCode: result.code)
    }

    // 下载仅接受UUID和现有仓库附件，不执行解压或恢复。
    public static func rddwn(_ id: UUID, directory: URL) throws -> Data {
        try rdbkpbytes(id, directory: directory, suffix: "zip", limit: 33_554_432)
    }
}

// 仅解码Homebrew公开的软件源字段。
private struct TapRow: Decodable {
    let name: String
    let installed: Bool
    let official: Bool
    let path: String
    let remote: String?
    let customRemote: Bool?
    let head: String?
    enum CodingKeys: String, CodingKey { case name, installed, official, path, remote, customRemote = "custom_remote", head = "HEAD" }
}
