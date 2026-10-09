import Hummingbird
import PanelDomain
import SystemMetrics

extension SystemSummary: ResponseCodable {}
extension SystemSnapshot: ResponseCodable {}
extension ProcessSnapshot: ResponseCodable {}
extension ProcessDetail: ResponseCodable {}
extension LiveSnapshot: ResponseCodable {}
extension ConnectionSnapshot: ResponseCodable {}
extension ProcessNetworkSnapshot: ResponseCodable {}
extension PowerThermalSnapshot: ResponseCodable {}
extension SiteInventory: ResponseCodable {}
extension SiteNote: ResponseCodable {}
extension SiteNoteInventory: ResponseCodable {}
extension SiteInfrastructure: ResponseCodable {}
extension ServiceInventory: ResponseCodable {}
extension ServiceActionResult: ResponseCodable {}
extension AuditEntry: ResponseCodable {}
extension EnvironmentInventory: ResponseCodable {}
extension BrewFormula: ResponseCodable {}
extension BrewCask: ResponseCodable {}
extension BrewTap: ResponseCodable {}
extension ContainerInventory: ResponseCodable {}
extension AdminInventory: ResponseCodable {}
extension FileInventory: ResponseCodable {}
extension FilePreview: ResponseCodable {}

// 描述文件接口的固定目录与相对路径。
public struct FileQuery: Decodable {
    public let root: String
    public let path: String?
}
extension MutationPlan: ResponseCodable {}

// 精确查询一个Homebrew软件标识。
public struct PackageQuery: Decodable {
    public let id: String
}

/// Query parameters for bounded historical monitoring data.
public struct HistoryQuery: Decodable, Equatable, Sendable {
    public let from: TimeInterval?
    public let to: TimeInterval?
    public let maxPoints: Int?

    /// Creates an optional historical range query.
    public init(from: TimeInterval?, to: TimeInterval?, maxPoints: Int?) {
        self.from = from
        self.to = to
        self.maxPoints = maxPoints
    }
}

/// Historical samples and their resolved query boundary.
public struct HistoryResponse: ResponseCodable, Equatable, Sendable {
    public let from: Date
    public let to: Date
    public let samples: [HistorySample]
}

/// Query parameters for one interface's historical counters and rates.
public struct NetworkHistoryQuery: Decodable, Equatable, Sendable {
    public let name: String
    public let from: TimeInterval?
    public let to: TimeInterval?
    public let maxPoints: Int?
}

/// Historical samples for one physical or virtual interface.
public struct NetworkHistoryResponse: ResponseCodable, Equatable, Sendable {
    public let name: String
    public let from: Date
    public let to: Date
    public let samples: [NetworkHistorySample]
}

/// Daily physical-interface totals over a bounded number of recent days.
public struct DailyNetworkResponse: ResponseCodable, Equatable, Sendable {
    public let from: Date
    public let to: Date
    public let totals: [DailyNetworkTotal]
}

/// Query parameters for recent daily network totals.
public struct DailyNetworkQuery: Decodable, Equatable, Sendable {
    public let days: Int?

    /// Creates a recent-day query.
    public init(days: Int?) {
        self.days = days
    }
}

/// Query parameters for historical process rankings and high-CPU filtering.
public struct ProcessHistoryQuery: Decodable, Equatable, Sendable {
    public let kind: String
    public let from: TimeInterval?
    public let to: TimeInterval?
    public let minimumCPU: Double?
}

/// Historical process rows and their resolved query boundary.
public struct ProcessHistoryResponse: ResponseCodable, Equatable, Sendable {
    public let from: Date
    public let to: Date
    public let samples: [ProcessHistorySample]
}

/// Health payload returned by the versioned API.
public struct HealthInfo: ResponseCodable, Equatable, Sendable {
    public let status: String
    public let apiVersion: String

    /// Creates an API health payload.
    public init(status: String, apiVersion: String) {
        self.status = status
        self.apiVersion = apiVersion
    }
}

/// Query parameters for the bounded audit trail.
public struct AuditQuery: Decodable, Equatable, Sendable {
    public let limit: Int?

    /// Creates one bounded audit query.
    public init(limit: Int?) {
        self.limit = limit
    }
}

/// Builds the complete versioned HTTP router.
public func mkrtr(
    telemetry: TelemetryMonitor? = nil,
    privileged: any PrivilegedSource = PrivilegedXPCClient(),
    audit: AuditStore? = nil,
    plans: MutationPlanStore? = nil,
    serviceBroker: ServiceBroker? = nil,
    mutationBroker: PlanBroker? = nil,
    siteNotes: SiteNoteStore? = nil,
    backupDirectory: URL? = nil,
    fileBackupDirectory: URL? = nil,
    packageBackupDirectory: URL? = nil,
    requestPolicy: RequestPolicy = RequestPolicy()
) -> Router<PanelRequestContext> {
    let router = Router(context: PanelRequestContext.self)
    router.add(middleware: HostGuard(policy: requestPolicy, audit: audit))
    let summaryReader = SummaryReader()
    let snapshotReader = SnapshotReader()
    let processReader = ProcessReader()
    let sampler = MetricsSampler()
    let siteDiscovery = SiteDiscovery()
    let launchServiceReader = LaunchServiceReader()
    let siteInfrastructureReader = SiteInfrastructureReader()
    let serviceInventoryReader = ServiceInventoryReader()
    let environmentReader = EnvironmentReader()
    let containerReader = ContainerReader()
    let adminReader = AdminReader()
    let fileReader = FileReader()
    let catalog = ModuleCatalog()

    // Reports process liveness and the contract version.
    router.get("api/v1/health") { _, _ -> HealthInfo in
        HealthInfo(status: "ok", apiVersion: "v1")
    }

    // Returns the first native read-only system snapshot.
    router.get("api/v1/system/summary") { _, _ -> SystemSummary in
        summaryReader.rdsmry()
    }

    // Returns a complete low-cost native host snapshot.
    router.get("api/v1/system/snapshot") { _, _ -> SystemSnapshot in
        snapshotReader.rdsnp()
    }

    // Returns the visible process table and resource rankings.
    router.get("api/v1/system/processes") { _, _ -> ProcessSnapshot in
        processReader.rdprocs()
    }

    // Reads bounded native details for one positive process identity.
    router.get("api/v1/system/processes/{pid}") { _, context -> ProcessDetail in
        guard let value = context.parameters.get("pid"), let pid = Int32(value), pid > 0 else {
            throw HTTPError(.badRequest, message: "Invalid process identity")
        }
        return processReader.rddtl(pid)
    }

    // Returns TCP and UDP sockets with process ownership.
    router.get("api/v1/system/connections") { _, _ -> ConnectionSnapshot in
        await privileged.rdconns()
    }

    // Returns complete per-process network counters when hosted by the privileged helper.
    router.get("api/v1/system/process-network") { _, _ -> ProcessNetworkSnapshot in
        await privileged.rdprocnet()
    }

    // Returns supported Apple power and thermal-pressure data without fabricating temperature.
    router.get("api/v1/system/power-thermal") { _, _ -> PowerThermalSnapshot in
        await privileged.rdpower()
    }

    // Returns every local listening service with DNS, proxy, and browser-entry classification.
    router.get("api/v1/sites") { _, _ -> SiteInventory in
        siteDiscovery.discover(
            await privileged.rdconns(),
            definitions: launchServiceReader.rdall()
        )
    }

    // Returns safe AdGuardHome and Zoraxy configuration without secrets or private keys.
    router.get("api/v1/sites/infrastructure") { _, _ -> SiteInfrastructure in
        siteInfrastructureReader.read()
    }

    // Returns panel-owned remarks without modifying native project definitions.
    router.get("api/v1/sites/notes") { _, _ -> SiteNoteInventory in
        SiteNoteInventory(enabled: siteNotes?.isWritable == true,
            notes: try await siteNotes?.read() ?? [], target: siteNotes?.target)
    }

    // Persists remarks only for an existing exact project identity and same-origin requests.
    router.post("api/v1/sites/notes") { request, context -> SiteNote in
        guard let siteNotes, siteNotes.isWritable else { throw HTTPError(.serviceUnavailable) }
        let host = request.head.authority
        let origin = request.headers[.origin]
        if let reason = requestPolicy.writeerr(host: host, origin: origin, contentType: request.headers[.contentType]) {
            throw HTTPError(.forbidden, message: reason)
        }
        let value = try await request.decode(as: SiteNote.self, context: context)
        guard launchServiceReader.rdservices().contains(where: {
            $0.label == value.label && $0.source == value.source && $0.definitionPath == value.definitionPath
        }) else { throw HTTPError(.notFound, message: "Project definition no longer exists") }
        do {
            let saved = try await siteNotes.save(value)
            try? await audit?.record(AuditEntry(sourceAddress: context.remoteAddress,
                host: host, origin: origin, operation: "site.note.save", target: saved.label,
                succeeded: true, message: "Project remark saved"))
            return saved
        } catch is SiteNoteError {
            throw HTTPError(.badRequest, message: "Invalid or out-of-scope project remark")
        }
    }

    // Returns every third-party launchd and Homebrew service with native lifecycle state.
    router.get("api/v1/services") { _, _ -> ServiceInventory in
        serviceInventoryReader.read()
    }

    // Returns installed Homebrew packages and runtime-manager availability.
    router.get("api/v1/environments") { _, _ -> EnvironmentInventory in
        environmentReader.read()
    }

    // Returns supported local container providers, contexts, and containers.
    router.get("api/v1/environments/containers") { _, _ -> ContainerInventory in
        containerReader.read()
    }

    // Returns databases, certificates, schedules, file roots, firewall, and directory entries.
    router.get("api/v1/environments/admin") { _, _ -> AdminInventory in
        adminReader.read()
    }

    // 指纹定位公开DER证书，固定钥匙串且禁止缓存。
    router.get("api/v1/certificates/{hash}/download") { _, context -> Response in
        let hash = context.parameters.get("hash") ?? ""
        do {
            let data = try adminReader.rdcrt(hash)
            return Response(status: .ok, headers: [.contentType: "application/pkix-cert",
                .contentDisposition: "attachment; filename=\"\(hash.uppercased()).cer\"", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch CertificateReadError.invalid { throw HTTPError(.badRequest, message: "Invalid certificate fingerprint") }
        catch CertificateReadError.notFound { throw HTTPError(.notFound) }
        catch { throw HTTPError(.serviceUnavailable, message: "System certificates are unavailable") }
    }

    // 返回既有文件根目录，不触发其他管理域采集。
    router.get("api/v1/files/roots") { _, _ -> [FileRoot] in
        adminReader.rdfiles()
    }

    // Lists files within one existing, explicitly selected native root.
    router.get("api/v1/files") { request, context -> FileInventory in
        let query = try request.uri.decodeQuery(as: FileQuery.self, context: context)
        do { return try fileReader.rdlst(query.root, path: query.path ?? "") }
        catch FileReadError.forbidden { throw HTTPError(.forbidden) }
        catch { throw HTTPError(.badRequest, message: "Directory is unavailable") }
    }

    // Previews bounded regular-file text without accepting absolute paths.
    router.get("api/v1/files/preview") { request, context -> FilePreview in
        let query = try request.uri.decodeQuery(as: FileQuery.self, context: context)
        do { return try fileReader.rdtxt(query.root, path: query.path ?? "") }
        catch FileReadError.forbidden { throw HTTPError(.forbidden) }
        catch { throw HTTPError(.badRequest, message: "File is unavailable") }
    }

    // 以附件返回完整普通文件，文件名编码后再写入HTTP头。
    router.get("api/v1/files/download") { request, context -> Response in
        let query = try request.uri.decodeQuery(as: FileQuery.self, context: context)
        do {
            let data = try fileReader.rddwn(query.root, path: query.path ?? "")
            let characters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
            let name = String((query.path ?? "").split(separator: "/").last ?? "file")
                .addingPercentEncoding(withAllowedCharacters: characters) ?? "file"
            return Response(status: .ok, headers: [.contentType: "application/octet-stream",
                .contentDisposition: "attachment; filename*=UTF-8''\(name)", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch FileReadError.forbidden { throw HTTPError(.forbidden) }
        catch FileReadError.oversized { throw HTTPError(.contentTooLarge, message: "File exceeds32MiB") }
        catch FileReadError.changed { throw HTTPError(.conflict, message: "File changed during download") }
        catch { throw HTTPError(.badRequest, message: "File is unavailable") }
    }

    // 查询真实formula元数据，不创建计划或请求系统授权。
    router.get("api/v1/environments/formula") { request, context -> BrewFormula in
        let query = try request.uri.decodeQuery(as: PackageQuery.self, context: context)
        guard PackageController.validid(query.id) else { throw HTTPError(.badRequest) }
        let row = await Task.detached { PackageController().rdpkg(query.id, installed: false) }.value
        guard let row else { throw HTTPError(.serviceUnavailable, message: "无法确认软件元数据") }
        return row
    }

    // 查询图形应用元数据，不创建计划或请求系统授权。
    router.get("api/v1/environments/cask") { request, context -> BrewCask in
        let query = try request.uri.decodeQuery(as: PackageQuery.self, context: context)
        guard PackageController.validid(query.id) else { throw HTTPError(.badRequest) }
        let row = await Task.detached { PackageController().rdcask(query.id, installed: false) }.value
        guard let row else { throw HTTPError(.serviceUnavailable, message: "无法确认图形应用元数据") }
        return row
    }

    // 软件源详情只读，不验证未安装远端是否存在。
    router.get("api/v1/environments/tap") { request, context -> BrewTap in
        let query = try request.uri.decodeQuery(as: PackageQuery.self, context: context)
        guard TapController.validid(query.id) else { throw HTTPError(.badRequest) }
        let row = await Task.detached { TapController().rdtap(query.id) }.value
        guard let row else { throw HTTPError(.serviceUnavailable, message: "无法确认软件源状态") }
        return row
    }

    // Creates a pending plan only; no system mutation is performed by HTTP.
    router.post("api/v1/environments/plans") { request, context -> MutationPlan in
        guard let plans else { throw HTTPError(.serviceUnavailable) }
        let host = request.head.authority
        let origin = request.headers[.origin]
        if let reason = requestPolicy.writeerr(host: host, origin: origin, contentType: request.headers[.contentType]) {
            throw HTTPError(.forbidden, message: reason)
        }
        let body = try await request.decode(as: MutationPlanRequest.self, context: context)
        do {
            let plan = try await plans.create(body)
            try? await audit?.record(AuditEntry(
                sourceAddress: context.remoteAddress, host: host, origin: origin,
                operation: "plan.create", target: plan.id.uuidString,
                succeeded: true, message: "\(plan.domain.rawValue).\(plan.action.rawValue):\(plan.target)"
            ))
            return plan
        } catch let error as MutationPlanError {
            throw HTTPError(.badRequest, message: String(describing: error))
        }
    }

    // Returns recent mutation plans without exposing authorization material.
    router.get("api/v1/environments/plans") { request, context -> [MutationPlan] in
        guard let plans else { throw HTTPError(.serviceUnavailable) }
        let query = try request.uri.decodeQuery(as: AuditQuery.self, context: context)
        let limit = query.limit ?? 100
        guard (1...1_000).contains(limit) else { throw HTTPError(.badRequest) }
        return try await plans.recent(limit: limit)
    }

    // 查询一个计划的实际最新状态。
    router.get("api/v1/environments/plans/{id}") { _, context -> MutationPlan in
        guard let plans else { throw HTTPError(.serviceUnavailable) }
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest) }
        guard let plan = try await plans.get(id) else { throw HTTPError(.notFound) }
        return plan
    }

    // 软件执行仍需本机启用与授权核验，有效会话由系统复用。
    router.get("api/v1/environments/capabilities") { _, _ -> MutationCapability in
        let enabled = mutationBroker?.domains.contains(.package) == true
        return MutationCapability(enabled: enabled, actions: PackageController.actions.map(\.rawValue),
            reason: !enabled ? "软件原生执行未启用" : "本机授权有效期内复用")
    }

    // 容器执行复用同一个本机授权队列。
    router.get("api/v1/environments/containers/capabilities") { _, _ -> MutationCapability in
        let enabled = mutationBroker?.domains.contains(.container) == true
        return MutationCapability(enabled: enabled, actions: ContainerController.actions.map(\.rawValue),
            reason: !enabled ? "容器原生执行未启用" : "本机授权有效期内复用")
    }

    // 目录创建与其他管理操作复用本机授权队列。
    router.get("api/v1/files/capabilities") { _, _ -> MutationCapability in
        let enabled = mutationBroker?.domains.contains(.file) == true
        return MutationCapability(enabled: enabled, actions: FileController.actions.map(\.rawValue),
            reason: !enabled ? "文件原生执行未启用" : "本机授权有效期内复用")
    }

    // 数据库快照复用相同本机授权能力。
    router.get("api/v1/databases/capabilities") { _, _ -> MutationCapability in
        let enabled = mutationBroker?.domains.contains(.database) == true
        return MutationCapability(enabled: enabled, actions: ["backup", "restore"],
            reason: enabled ? "需要本机管理员授权" : "数据库原生执行未启用")
    }

    // 仅成功记录的UUID快照能下载，不接受任意文件路径。
    router.get("api/v1/databases/backups/{id}/download") { _, context -> Response in
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest) }
        guard let backupDirectory, let plans,
              try await plans.recent(limit: 1_000).contains(where: {
                  $0.domain == .database && [.succeeded, .rolledBack].contains($0.state)
                      && $0.rollbackToken == id && $0.backup?.kind == "sqlite-snapshot"
              }) else { throw HTTPError(.notFound) }
        do {
            let data = try DatabaseController.rddwn(id, directory: backupDirectory)
            return Response(status: .ok, headers: [.contentType: "application/octet-stream",
                .contentDisposition: "attachment; filename=\"\(id.uuidString).sqlite\"", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch { throw HTTPError(.notFound) }
    }

    // 已执行文本任务保留原文下载，失败写入也可取回备份。
    router.get("api/v1/files/backups/{id}/download") { _, context -> Response in
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest) }
        guard let fileBackupDirectory, let plans,
              try await plans.recent(limit: 1_000).contains(where: {
                  $0.domain == .file && [.write, .restore].contains($0.action)
                      && [.succeeded, .rolledBack, .failed].contains($0.state)
                      && $0.rollbackToken == id && $0.backup?.kind == "file-text-state"
              }) else { throw HTTPError(.notFound) }
        do {
            let data = try FileController.rddwntxt(id, directory: fileBackupDirectory)
            return Response(status: .ok, headers: [.contentType: "application/octet-stream",
                .contentDisposition: "attachment; filename=\"\(id.uuidString).txt\"", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch { throw HTTPError(.notFound) }
    }

    // 已执行源移除的仓库附件按原UUID下载，不接受任意路径。
    router.get("api/v1/environments/backups/{id}/download") { _, context -> Response in
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest) }
        guard let packageBackupDirectory, let plans,
              try await plans.recent(limit: 1_000).contains(where: {
                  $0.domain == .package && $0.action == .remove && $0.parameters == ["kind": "tap"]
                      && [.succeeded, .failed].contains($0.state) && $0.rollbackToken == id
                      && $0.backup?.kind == "homebrew-tap-repository"
              }) else { throw HTTPError(.notFound) }
        do {
            let data = try TapController.rddwn(id, directory: packageBackupDirectory)
            return Response(status: .ok, headers: [.contentType: "application/zip",
                .contentDisposition: "attachment; filename=\"\(id.uuidString).zip\"", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch { throw HTTPError(.notFound) }
    }

    // 同源HTTP只提交精确确认，不传输系统授权引用。
    router.post("api/v1/environments/plans/{id}/execute") { request, context -> MutationPlan in
        guard let mutationBroker else { throw HTTPError(.serviceUnavailable) }
        if let reason = requestPolicy.writeerr(host: request.head.authority, origin: request.headers[.origin],
            contentType: request.headers[.contentType]) { throw HTTPError(.forbidden, message: reason) }
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest) }
        let body = try await request.decode(as: PlanConfirmation.self, context: context)
        return try await mutationBroker.submit(id, confirmation: body.confirmation, source: context.remoteAddress,
            host: request.head.authority, origin: request.headers[.origin])
    }

    // Reports native authorization availability without granting execution rights.
    router.get("api/v1/services/capabilities") { _, _ -> ServiceCapability in
        ServiceCapability(enabled: serviceBroker != nil,
            reason: serviceBroker == nil ? "本机原生授权桥接尚未启用" : "本机授权有效期内复用",
            target: serviceBroker?.target)
    }

    // 列出本次服务进程保留的有界操作任务。
    router.get("api/v1/services/operations") { _, _ -> [PanelTask] in
        guard let serviceBroker else { throw HTTPError(.serviceUnavailable) }
        return await serviceBroker.lsttsks()
    }

    // Returns a single native operation task without authorization material.
    router.get("api/v1/services/operations/{task}") { _, context -> PanelTask in
        guard let serviceBroker, let id = UUID(uuidString: try context.parameters.require("task")),
              let task = await serviceBroker.status(id) else { throw HTTPError(.notFound) }
        return task
    }

    // Queues a confirmed operation for separate native administrator authorization.
    router.post("api/v1/services/{id}/{action}") { request, context -> PanelTask in
        let id = try context.parameters.require("id")
        let actionText = try context.parameters.require("action")
        let host = request.head.authority
        let origin = request.headers[.origin]
        if let reason = requestPolicy.writeerr(
            host: host,
            origin: origin,
            contentType: request.headers[.contentType]
        ) {
            try? await audit?.record(AuditEntry(
                sourceAddress: context.remoteAddress,
                host: host,
                origin: origin,
                operation: "service.\(actionText)",
                target: id,
                succeeded: false,
                message: reason
            ))
            throw HTTPError(.forbidden, message: reason)
        }
        guard let action = ServiceAction(rawValue: actionText) else {
            try? await audit?.record(AuditEntry(
                sourceAddress: context.remoteAddress,
                host: host,
                origin: origin,
                operation: "service.\(actionText)",
                target: id,
                succeeded: false,
                message: "Unsupported service action"
            ))
            throw HTTPError(.badRequest, message: "Unsupported service action")
        }
        let body: ServiceActionRequest
        do {
            body = try await request.decode(as: ServiceActionRequest.self, context: context)
        } catch {
            try? await audit?.record(AuditEntry(
                sourceAddress: context.remoteAddress,
                host: host,
                origin: origin,
                operation: "service.\(action.rawValue)",
                target: id,
                succeeded: false,
                message: "Invalid service action payload"
            ))
            throw error
        }
        guard body.id == id, body.action == action, body.confirmation == id else {
            try? await audit?.record(AuditEntry(
                sourceAddress: context.remoteAddress,
                host: host,
                origin: origin,
                operation: "service.\(action.rawValue)",
                target: id,
                succeeded: false,
                message: "Service action confirmation does not match the route"
            ))
            throw HTTPError(.badRequest, message: "Service action confirmation does not match the route")
        }
        guard let serviceBroker else {
            try? await audit?.record(AuditEntry(sourceAddress: context.remoteAddress, host: host, origin: origin,
                operation: "service.\(action.rawValue)", target: id, succeeded: false,
                message: "Native authorization bridge is disabled"))
            throw HTTPError(.forbidden, message: "本机原生授权桥接尚未启用")
        }
        guard body.authorization == nil, ServiceController.validid(id),
              id != PrivilegedXPCClient.service else {
            throw HTTPError(.badRequest, message: "目标不是可管理的启动服务")
        }
        let matches = serviceInventoryReader.read().services.filter { $0.manager == .launchd && $0.id == id }
        guard matches.count == 1, let service = matches.first else {
            throw HTTPError(.conflict, message: "未找到唯一的启动服务，请在本机检查项目配置")
        }
        guard action == .stop || !service.isDisabled else {
            throw HTTPError(.forbidden, message: "项目配置已禁用，请先在本机启用该项目")
        }
        return try await serviceBroker.submit(body, source: context.remoteAddress, host: host, origin: origin)
    }

    // Returns a bounded newest-first security audit trail.
    router.get("api/v1/audit") { request, context -> [AuditEntry] in
        guard let audit else { throw HTTPError(.serviceUnavailable) }
        let query = try request.uri.decodeQuery(as: AuditQuery.self, context: context)
        let limit = query.limit ?? 100
        guard (1...1_000).contains(limit) else { throw HTTPError(.badRequest) }
        return try await audit.recent(limit: limit)
    }

    // Returns the stateful live sample including network throughput rates.
    router.get("api/v1/system/live") { _, _ -> LiveSnapshot in
        if let telemetry { return try await telemetry.tick() }
        return await sampler.rdlive()
    }

    // Returns a bounded time range with deterministic point reduction.
    router.get("api/v1/system/history") { request, context -> HistoryResponse in
        guard let telemetry else { throw HTTPError(.serviceUnavailable) }
        let query = try request.uri.decodeQuery(as: HistoryQuery.self, context: context)
        let to = Date(timeIntervalSince1970: query.to ?? Date().timeIntervalSince1970)
        let from = Date(timeIntervalSince1970: query.from ?? to.addingTimeInterval(-86_400).timeIntervalSince1970)
        let maxPoints = query.maxPoints ?? 1_500
        guard from <= to, (1...15_000).contains(maxPoints) else {
            throw HTTPError(.badRequest, message: "Invalid history range or maxPoints")
        }
        return HistoryResponse(
            from: from,
            to: to,
            samples: try await telemetry.hist(from: from, to: to, maxPoints: maxPoints)
        )
    }

    // Returns isolated history for one interface, including FlClash and Tailscale tunnels.
    router.get("api/v1/system/network/history") { request, context -> NetworkHistoryResponse in
        guard let telemetry else { throw HTTPError(.serviceUnavailable) }
        let query = try request.uri.decodeQuery(as: NetworkHistoryQuery.self, context: context)
        let to = Date(timeIntervalSince1970: query.to ?? Date().timeIntervalSince1970)
        let from = Date(timeIntervalSince1970: query.from ?? to.addingTimeInterval(-86_400).timeIntervalSince1970)
        let maxPoints = query.maxPoints ?? 1_500
        guard !query.name.isEmpty, from <= to, (1...15_000).contains(maxPoints) else {
            throw HTTPError(.badRequest, message: "Invalid network history query")
        }
        return NetworkHistoryResponse(
            name: query.name,
            from: from,
            to: to,
            samples: try await telemetry.nethist(from: from, to: to, name: query.name, maxPoints: maxPoints)
        )
    }

    // Returns physical-interface traffic grouped by local calendar day.
    router.get("api/v1/system/network/daily") { request, context -> DailyNetworkResponse in
        guard let telemetry else { throw HTTPError(.serviceUnavailable) }
        let query = try request.uri.decodeQuery(as: DailyNetworkQuery.self, context: context)
        let days = query.days ?? 30
        guard (1...366).contains(days) else { throw HTTPError(.badRequest, message: "Invalid day count") }
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -days, to: to) ?? to.addingTimeInterval(-Double(days) * 86_400)
        return DailyNetworkResponse(from: from, to: to, totals: try await telemetry.netdays(from: from, to: to))
    }

    // Returns historical CPU/memory rankings; minimumCPU enables high-CPU event queries.
    router.get("api/v1/system/process/history") { request, context -> ProcessHistoryResponse in
        guard let telemetry else { throw HTTPError(.serviceUnavailable) }
        let query = try request.uri.decodeQuery(as: ProcessHistoryQuery.self, context: context)
        let to = Date(timeIntervalSince1970: query.to ?? Date().timeIntervalSince1970)
        let from = Date(timeIntervalSince1970: query.from ?? to.addingTimeInterval(-86_400).timeIntervalSince1970)
        let minimumCPU = query.minimumCPU ?? 0
        guard from <= to, ["cpu", "memory"].contains(query.kind), minimumCPU >= 0 else {
            throw HTTPError(.badRequest, message: "Invalid process history query")
        }
        return ProcessHistoryResponse(
            from: from,
            to: to,
            samples: try await telemetry.prochist(from: from, to: to, kind: query.kind, minimumCPU: minimumCPU)
        )
    }

    // Advertises implemented and planned backend modules.
    router.get("api/v1/capabilities") { _, _ -> [ModuleInfo] in
        catalog.lstmods()
    }

    return router
}
