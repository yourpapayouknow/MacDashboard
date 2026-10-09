import Hummingbird
import SystemMetrics

// 描述已启用管理域的原生执行能力。
public struct MutationCapability: ResponseCodable, Sendable {
    public let enabled: Bool
    public let actions: [String]
    public let reason: String
}

// 仅接受计划的精确二次确认，不接受命令或授权数据。
public struct PlanConfirmation: Decodable, Sendable {
    public let confirmation: String
}

// 管理域复用计划日志串行执行本机授权操作。
public actor PlanBroker {
    public nonisolated let domains: Set<MutationDomain>
    private let plans: MutationPlanStore
    private let audit: AuditStore
    private let operation: @Sendable (MutationPlan,
        @escaping @Sendable (BackupRecord, UUID) async throws -> Void) async -> MutationResult
    private var active: UUID?

    // 持有授权进程并在备份和记录成功后执行固定原生命令。
    public init(executable: URL, plans: MutationPlanStore, audit: AuditStore, directory: URL,
        domains: Set<MutationDomain>) {
        self.domains = domains.intersection([.package, .container, .file, .database])
        self.plans = plans
        self.audit = audit
        let packages = PackageController()
        let taps = TapController()
        let containers = ContainerController()
        let files = FileController()
        let databases = DatabaseController()
        self.operation = { plan, before in
            await NativeGrant.withgrant(executable, scope: plan.domain == .package ? .package : plan.domain == .container ? .container : plan.domain == .database ? .database : .file, target: plan.target,
                action: plan.action.rawValue) { data in
                guard OperationAuthorization.verify(data) else {
                    return MutationResult(succeeded: false, message: "本机授权无效", exitCode: nil)
                }
                do {
                    if plan.domain == .package {
                        if plan.parameters["kind"] == "tap" {
                            let prepared = try await Task.detached {
                                try taps.prpr(plan, directory: directory.appendingPathComponent("packages"))
                            }.value
                            try await before(prepared.backup, prepared.backup.id)
                            return await Task.detached { taps.act(prepared) }.value
                        }
                        let prepared = try await Task.detached {
                            try packages.prpr(plan, directory: directory.appendingPathComponent("packages"))
                        }.value
                        try await before(prepared.backup, prepared.rollbackToken)
                        return await Task.detached { packages.act(prepared) }.value
                    }
                    if plan.domain == .file {
                        let prepared = try await Task.detached {
                            try files.prpr(plan, directory: directory.appendingPathComponent("files"))
                        }.value
                        if plan.action == .restore {
                            guard let original = try await Self.rdorigin(plans, plan) else { throw FileReadError.forbidden }
                            switch prepared {
                            case .restore(let snapshot, _):
                                guard [.move, .trash].contains(original.action), snapshot.destination.rootID == original.parameters["rootID"],
                                      snapshot.destination.relativePath == original.parameters["relativePath"] else { throw FileReadError.forbidden }
                            case .text(let snapshot, _, _):
                                guard original.backup?.kind == "file-text-state", snapshot.source.rootID == original.parameters["rootID"],
                                      snapshot.source.relativePath == original.parameters["relativePath"] else { throw FileReadError.forbidden }
                            default: throw FileReadError.forbidden
                            }
                        }
                        try await before(prepared.backup, prepared.backup.id)
                        return await Task.detached { files.act(prepared) }.value
                    }
                    if plan.domain == .database {
                        let prepared = try await Task.detached {
                            try databases.prpr(plan, directory: directory.appendingPathComponent("databases"))
                        }.value
                        try await before(prepared.backup, prepared.backup.id)
                        return await Task.detached { databases.act(prepared) }.value
                    }
                    let prepared = try await Task.detached {
                        try containers.prpr(plan, directory: directory.appendingPathComponent("containers"))
                    }.value
                    try await before(prepared.backup, prepared.backup.id)
                    return await Task.detached { containers.act(prepared) }.value
                } catch {
                    return MutationResult(succeeded: false, message: "目标状态、备份或执行记录未确认，操作未执行", exitCode: nil)
                }
            } ?? MutationResult(succeeded: false, message: "本机授权未完成或已取消", exitCode: nil)
        }
    }

    // 注入不弹系统窗口且不修改业务对象的测试执行器。
    init(plans: MutationPlanStore, audit: AuditStore, domains: Set<MutationDomain> = [.package],
        operation: @escaping @Sendable (MutationPlan,
            @escaping @Sendable (BackupRecord, UUID) async throws -> Void) async -> MutationResult) {
        self.domains = domains
        self.plans = plans
        self.audit = audit
        self.operation = operation
    }

    // 原子认领有效计划，拒绝过期、重复和跨域执行。
    public func submit(_ id: UUID, confirmation: String, source: String?, host: String?, origin: String?) async throws -> MutationPlan {
        guard active == nil else { throw HTTPError(.conflict, message: "已有原生授权任务正在进行") }
        active = id
        do {
            guard let plan = try await plans.get(id), plan.state == .pending, domains.contains(plan.domain),
                  Self.validpln(plan), confirmation == "\(plan.domain.rawValue):\(plan.action.rawValue):\(plan.target)" else {
                throw HTTPError(.badRequest, message: "计划或确认无效")
            }
            if plan.action == .restore {
                guard try await Self.rdorigin(plans, plan) != nil else { throw HTTPError(.badRequest, message: "没有可恢复的成功记录") }
            }
            try await audit.record(AuditEntry(sourceAddress: source, host: host, origin: origin,
                operation: "\(plan.domain.rawValue).\(plan.action.rawValue).request", target: plan.target,
                succeeded: false, message: "等待本机管理员授权"))
            let queued = try await plans.trnstn(id, to: .queued, message: "等待本机管理员授权")
            Task { await self.prfrm(queued, source: source, host: host, origin: origin) }
            return queued
        } catch {
            active = nil
            throw error
        }
    }

    // 恢复只关联同一管理域中尚未回滚的成功记录。
    private static func rdorigin(_ plans: MutationPlanStore, _ plan: MutationPlan) async throws -> MutationPlan? {
        guard let token = UUID(uuidString: plan.parameters["backupID"] ?? "") else { return nil }
        return try await plans.recent(limit: 1_000).first {
            guard $0.domain == plan.domain, $0.state == .succeeded, $0.rollbackToken == token else { return false }
            if plan.domain == .package { return [.pin, .unpin].contains($0.action) && $0.target == plan.target
                && ($0.parameters["kind"] ?? "formula") == (plan.parameters["kind"] ?? "formula") }
            if plan.domain == .database { return [.backup, .restore].contains($0.action) && $0.target == plan.target
                && $0.parameters["rootID"] == plan.parameters["rootID"] && $0.parameters["relativePath"] == plan.parameters["relativePath"] }
            if plan.domain == .file, ([.write, .restore].contains($0.action) && $0.backup?.kind == "file-text-state"
                || $0.action == .trash && $0.backup?.kind == "file-trash-state") {
                return $0.target == plan.target && $0.parameters["rootID"] == plan.parameters["rootID"]
                    && $0.parameters["relativePath"] == plan.parameters["relativePath"]
            }
            return plan.domain == .file && $0.action == .move
                && $0.parameters["destinationRootID"] == plan.parameters["rootID"]
                && $0.parameters["destinationRelativePath"] == plan.parameters["relativePath"]
        }
    }

    // 仅启用的实际管理域共用确认边界，其余计划禁止执行。
    private static func validpln(_ plan: MutationPlan) -> Bool {
        if plan.domain == .package {
            return PackageController.validpln(plan)
        }
        if plan.domain == .file {
            return FileController.validpln(plan)
        }
        if plan.domain == .database { return DatabaseController.validpln(plan) }
        return ContainerController.validpln(plan)
    }

    // 备份与执行状态落盘后才允许变更，结果写入同一计划。
    private func prfrm(_ plan: MutationPlan, source: String?, host: String?, origin: String?) async {
        let result = await operation(plan) { backup, token in
            _ = try await self.plans.trnstn(plan.id, to: .authorized, backup: backup,
                rollbackToken: token, message: "本机已授权，原状态已备份")
            _ = try await self.plans.trnstn(plan.id, to: .executing, message: "正在执行已确认操作")
        }
        do {
            try await audit.record(AuditEntry(sourceAddress: source, host: host, origin: origin,
                operation: "\(plan.domain.rawValue).\(plan.action.rawValue).result", target: plan.target,
                succeeded: result.succeeded, message: result.message))
            if result.succeeded && plan.action == .restore {
                guard let original = try await Self.rdorigin(plans, plan) else { throw HTTPError(.conflict) }
                _ = try await plans.trnstn(original.id, to: .rolledBack,
                    message: plan.domain == .database ? "此快照已用于恢复" : "原操作已恢复", exitCode: 0)
            }
            _ = try await plans.trnstn(plan.id, to: result.succeeded ? .succeeded : .failed,
                message: result.message, exitCode: result.exitCode)
        } catch {
            _ = try? await plans.trnstn(plan.id, to: .failed, message: "结果记录失败，请检查实际目标状态", exitCode: result.exitCode)
        }
        active = nil
    }
}
