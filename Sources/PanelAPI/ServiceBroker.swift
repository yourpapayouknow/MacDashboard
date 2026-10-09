import Hummingbird
import PanelDomain
import SystemMetrics

extension PanelTask: ResponseCodable {}

/// Runtime availability of the local interactive authorization bridge.
public struct ServiceCapability: ResponseCodable, Sendable {
    public let enabled: Bool
    public let reason: String
    public let target: String?
}

/// Serializes administrator-approved service operations and never exposes grants over HTTP.
public actor ServiceBroker {
    public nonisolated let target: String?
    private let tasks = TaskStore()
    private let audit: AuditStore
    private let execute: @Sendable (ServiceActionRequest) async -> ServiceActionResult
    private var active: UUID?

    /// Uses the fixed signed authorization executable beside PanelService.
    public init(executable: URL, audit: AuditStore, privileged: any PrivilegedSource, target: String? = nil) {
        self.target = target
        self.audit = audit
        self.execute = { request in
            await Self.act(executable, request, privileged)
        }
    }

    /// Injects a non-mutating executor for bounded tests.
    init(audit: AuditStore, target: String? = nil, execute: @escaping @Sendable (ServiceActionRequest) async -> ServiceActionResult) {
        self.target = target
        self.audit = audit
        self.execute = execute
    }

    /// Checks code identity before any native authorization dialog is launched.
    public nonisolated static func trusted(_ executable: URL) -> Bool {
        NativeGrant.trusted(executable)
    }

    /// Queues only a confirmed service action while another operation is not active.
    public func submit(_ request: ServiceActionRequest, source: String?, host: String?, origin: String?) async throws -> PanelTask {
        guard request.authorization == nil, request.id != PrivilegedXPCClient.service,
              ServiceController.validid(request.id),
              request.confirmation == request.id else { throw HTTPError(.badRequest) }
        guard target == nil || target == request.id else {
            throw HTTPError(.forbidden, message: "当前仅允许指定的测试项目")
        }
        guard active == nil else { throw HTTPError(.conflict, message: "已有本机授权任务正在进行") }
        active = UUID()
        let task = await tasks.mktsk(module: .services, action: request.action.rawValue, target: request.id)
        active = task.id
        do {
            try await audit.record(AuditEntry(sourceAddress: source, host: host, origin: origin,
                operation: "service.\(request.action.rawValue).request", target: request.id,
                succeeded: false, message: "Awaiting native administrator authorization"))
        } catch {
            _ = await tasks.updtsk(task.id, state: .running, message: "无法写入审计记录")
            _ = await tasks.updtsk(task.id, state: .failed, message: "无法写入审计记录，操作未执行")
            active = nil
            throw HTTPError(.internalServerError, message: "无法写入审计记录，操作未执行")
        }
        Task { await self.perform(task.id, request, source, host, origin) }
        return task
    }

    /// Returns progress without authorization bytes or command output.
    public func status(_ id: UUID) async -> PanelTask? { await tasks.rdtsk(id) }

    // 复用有界任务存储返回最新操作记录。
    public func lsttsks() async -> [PanelTask] { await tasks.lsttsks() }

    /// Records one native result and releases the single-operation gate.
    private func perform(_ id: UUID, _ request: ServiceActionRequest, _ source: String?, _ host: String?, _ origin: String?) async {
        _ = await tasks.updtsk(id, state: .running, message: "等待本机管理员授权")
        let reply = await execute(request)
        let result = reply.id == request.id && reply.action == request.action ? reply :
            ServiceActionResult(id: request.id, action: request.action, succeeded: false,
                message: "本机返回结果与请求目标不一致，请检查实际服务状态", exitCode: nil)
        do {
            try await audit.record(AuditEntry(sourceAddress: source, host: host, origin: origin,
                operation: "service.\(request.action.rawValue).result", target: request.id,
                succeeded: result.succeeded, message: result.message))
            _ = await tasks.updtsk(id, state: result.succeeded ? .succeeded : .failed,
                message: result.message, exitCode: result.exitCode)
        } catch {
            _ = await tasks.updtsk(id, state: .failed, message: "无法保存操作结果，请检查实际服务状态", exitCode: result.exitCode)
        }
        active = nil
    }

    /// 保留授权进程直到Helper使用授权引用完成操作。
    private nonisolated static func act(_ executable: URL, _ request: ServiceActionRequest,
        _ privileged: any PrivilegedSource) async -> ServiceActionResult {
        let denied = ServiceActionResult(id: request.id, action: request.action, succeeded: false,
            message: "本机管理员授权未完成或已取消", exitCode: nil)
        return await NativeGrant.withgrant(executable, scope: .service, target: request.id,
            action: request.action.rawValue) { data in
                await privileged.actservice(ServiceActionRequest(id: request.id, action: request.action,
                    confirmation: request.id, authorization: data))
            } ?? denied
    }
}
