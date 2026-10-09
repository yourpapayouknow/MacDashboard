// 保存容器生命周期变更前的精确状态，不收集环境变量和挂载内容。
public struct ContainerBackup: Codable, Equatable, Sendable {
    public let endpoint: String
    public let daemonID: String
    public let action: MutationAction
    public let container: ContainerState
}

// 描述固定inspect模板返回的容器身份和生命周期字段。
public struct ContainerState: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let status: String
    public let running: Bool
    public let paused: Bool
    public let restarting: Bool
    public let dead: Bool
    public let startedAt: String
    public let finishedAt: String
}

// 将真实状态备份传递给共享计划代理。
public struct ContainerPrepared: Sendable {
    public let snapshot: ContainerBackup
    public let backup: BackupRecord
}

// 仅对已确认的本机Docker容器执行固定生命周期命令。
public struct ContainerController: Sendable {
    public static let actions: [MutationAction] = [.start, .stop, .restart, .remove]
    public let available: Bool
    private let command: @Sendable ([String]) -> NativeResult
    static let hostfmt = "{{.Endpoints.docker.Host}}"
    static let inspectfmt = #"{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Image}},"status":{{json .State.Status}},"running":{{json .State.Running}},"paused":{{json .State.Paused}},"restarting":{{json .State.Restarting}},"dead":{{json .State.Dead}},"startedAt":{{json .State.StartedAt}},"finishedAt":{{json .State.FinishedAt}}}"#

    // 复用库存模块定位的Docker，忽略外部Docker连接环境变量。
    public init() {
        self.init(path: ContainerReader().dockerPath)
    }

    // 库存与执行共用同一个已定位的程序。
    init(path: String?) {
        available = path != nil && geteuid() != 0
        command = { arguments in
            guard let path else { return NativeResult(code: -1, output: "") }
            return runcmd(path, arguments, environment: Self.clnenv())
        }
    }

    // 注入不修改真实容器的测试命令。
    init(command: @escaping @Sendable ([String]) -> NativeResult) {
        available = true
        self.command = command
    }

    // 保持库存与执行读取同一本机默认上下文。
    static func clnenv() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DOCKER_") }
    }

    // 完整64位十六进制身份禁止名称、缩写和参数注入。
    public static func validid(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // 只接受规范的本机Unix连接，拒绝TCP、SSH和路径穿越。
    public static func validhost(_ host: String) -> Bool {
        guard host.hasPrefix("unix:///"), host.utf8.count <= 512 else { return false }
        let path = String(host.dropFirst(7))
        return !path.contains("\0") && !path.contains("\n") && !path.contains("\r") && !path.contains("%")
            && path.count > 1 && (path as NSString).standardizingPath == path
    }

    // 校验守护进程的稳定身份。
    public static func validdmn(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 58].contains($0)
        }
    }

    // 管理队列与执行器共用精确动作、身份和参数边界。
    public static func validpln(_ plan: MutationPlan) -> Bool {
        plan.domain == .container && actions.contains(plan.action) && validid(plan.target)
            && Set(plan.parameters.keys) == ["endpoint", "daemonID"]
            && validhost(plan.parameters["endpoint"] ?? "") && validdmn(plan.parameters["daemonID"] ?? "")
    }

    // 获取默认上下文并拒绝远端连接。
    public func rdhost() -> String? {
        guard available else { return nil }
        let result = command(["context", "inspect", "--format", Self.hostfmt])
        let host = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.code == 0 && Self.validhost(host) ? host : nil
    }

    // 从固定连接获取引擎身份。
    func rddmn(_ host: String) -> String? {
        guard Self.validhost(host) else { return nil }
        let result = command(["--host", host, "info", "--format", "{{.ID}}"])
        let id = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.code == 0 && Self.validdmn(id) ? id : nil
    }

    // 精确读取容器且不暴露配置中的凭据。
    func rdctr(_ id: String, host: String) -> ContainerState? {
        guard Self.validid(id), Self.validhost(host) else { return nil }
        let result = command(["--host", host, "container", "inspect", "--format", Self.inspectfmt, id])
        guard result.code == 0, let row = try? JSONDecoder().decode(ContainerState.self, from: Data(result.output.utf8)),
              row.id == id else { return nil }
        return row
    }

    // 拒绝暂停、重启中、死亡及不一致状态，重启仅用于运行中的容器。
    private func validst(_ row: ContainerState, _ action: MutationAction) -> Bool {
        !row.paused && !row.restarting && !row.dead && ["running", "created", "exited"].contains(row.status)
            && row.running == (row.status == "running") && (action != .restart || row.running)
            && (action != .remove || !row.running)
    }

    // 先核对确认时的连接和引擎，再保存700目录中的状态备份。
    public func prpr(_ plan: MutationPlan, directory: URL) throws -> ContainerPrepared {
        guard Self.validpln(plan), let host = rdhost(),
              host == plan.parameters["endpoint"], let daemon = rddmn(host), daemon == plan.parameters["daemonID"],
              let row = rdctr(plan.target, host: host), validst(row, plan.action) else {
            throw MutationPlanError.invalid("Container or engine changed")
        }
        let snapshot = ContainerBackup(endpoint: host, daemonID: daemon, action: plan.action, container: row)
        let backup = try wrtbkp(JSONEncoder().encode(snapshot),
            kind: plan.action == .remove ? "docker-remove-state" : "docker-lifecycle-state", directory: directory)
        return ContainerPrepared(snapshot: snapshot, backup: backup)
    }

    // 执行前后核对精确状态，零退出码和重启时间变化共同确认结果。
    public func act(_ prepared: ContainerPrepared) -> MutationResult {
        let snapshot = prepared.snapshot
        guard Self.actions.contains(snapshot.action), validst(snapshot.container, snapshot.action),
              rdhost() == snapshot.endpoint, rddmn(snapshot.endpoint) == snapshot.daemonID,
              rdctr(snapshot.container.id, host: snapshot.endpoint) == snapshot.container else {
            return MutationResult(succeeded: false, message: "容器或引擎已改变，请重新确认", exitCode: nil)
        }
        let expected = snapshot.action != .stop
        if ![.restart, .remove].contains(snapshot.action) && snapshot.container.running == expected {
            return MutationResult(succeeded: true, message: "已处于目标状态", exitCode: 0)
        }
        var arguments = ["--host", snapshot.endpoint, "container", snapshot.action == .remove ? "rm" : snapshot.action.rawValue]
        if [.stop, .restart].contains(snapshot.action) { arguments += ["--timeout", "10"] }
        arguments.append(snapshot.container.id)
        let result = command(arguments)
        guard result.code == 0 else {
            return MutationResult(succeeded: false, message: "容器操作未完成，请检查实际状态", exitCode: result.code)
        }
        // 成功查询同一引擎的全部容器，空结果才证明目标已移除。
        if snapshot.action == .remove {
            guard rdhost() == snapshot.endpoint, rddmn(snapshot.endpoint) == snapshot.daemonID else {
                return MutationResult(succeeded: false, message: "容器结果未确认，请检查实际状态", exitCode: result.code)
            }
            let listed = command(["--host", snapshot.endpoint, "container", "ls", "--all", "--no-trunc", "--quiet",
                "--filter", "id=\(snapshot.container.id)"])
            guard listed.code == 0, listed.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rdhost() == snapshot.endpoint, rddmn(snapshot.endpoint) == snapshot.daemonID else {
                return MutationResult(succeeded: false, message: "容器结果未确认，请检查实际状态", exitCode: result.code)
            }
            return MutationResult(succeeded: true, message: "容器已移除，可写层不可恢复", exitCode: result.code)
        }
        guard rddmn(snapshot.endpoint) == snapshot.daemonID,
              let after = rdctr(snapshot.container.id, host: snapshot.endpoint),
              after.image == snapshot.container.image, after.running == expected, validst(after, snapshot.action),
              snapshot.action != .restart || after.startedAt != snapshot.container.startedAt else {
            return MutationResult(succeeded: false, message: "容器结果未确认，请检查实际状态", exitCode: result.code)
        }
        return MutationResult(succeeded: true, message: snapshot.action == .start ? "容器已启动"
            : snapshot.action == .stop ? "容器已停止" : "容器已重启", exitCode: result.code)
    }
}
