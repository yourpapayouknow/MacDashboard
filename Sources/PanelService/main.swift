import Foundation
import Hummingbird
import PanelAPI
import PanelConfig
import SystemMetrics

let port = try prsprt(ProcessInfo.processInfo.environment["PANEL_PORT"])
let environment = ProcessInfo.processInfo.environment
let bindAddress = try prsbnd(environment["PANEL_BIND_ADDRESS"])
let dataDirectory = environment["PANEL_DATA_DIR"].map(URL.init(fileURLWithPath:))
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacDashboard", isDirectory: true)
try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
let historyStore = try HistoryStore(path: dataDirectory.appendingPathComponent("monitoring.sqlite").path)
let auditStore = try AuditStore(path: dataDirectory.appendingPathComponent("audit.jsonl").path)
let planStore = try MutationPlanStore(path: dataDirectory.appendingPathComponent("mutation-plans.jsonl").path)
let telemetry = TelemetryMonitor(store: historyStore)
// Native mutations require explicit deployment opt-in and the signed sibling broker.
let authorizer = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("PanelAuthorize")
let mode = environment["PANEL_NATIVE_ACTIONS"]
let serviceBroker = ["1", "fixture"].contains(mode ?? "") && ServiceBroker.trusted(authorizer)
    ? ServiceBroker(executable: authorizer, audit: auditStore, privileged: PrivilegedXPCClient(),
        target: mode == "fixture" ? "com.iwmei.macdashboard.review-fixture" : nil) : nil
// 审阅fixture模式不允许修改任何现有软件或容器。
let mutationDomains: Set<MutationDomain> = Set([
    PackageController().available ? MutationDomain.package : nil,
    ContainerController().available ? MutationDomain.container : nil,
    FileController().available ? MutationDomain.file : nil,
    DatabaseController().available ? MutationDomain.database : nil,
].compactMap { $0 })
let mutationBroker = mode == "1" && NativeGrant.trusted(authorizer) && !mutationDomains.isEmpty
    ? PlanBroker(executable: authorizer, plans: planStore, audit: auditStore,
        directory: dataDirectory.appendingPathComponent("backups", isDirectory: true), domains: mutationDomains) : nil
// Panel-owned project remarks share the explicit write opt-in and fixture boundary.
let siteNotes = try SiteNoteStore(path: dataDirectory.appendingPathComponent("site-notes.json").path,
    target: mode == "fixture" ? "com.iwmei.macdashboard.review-fixture" : nil,
    isWritable: ["1", "fixture"].contains(mode ?? ""))
// 内网部署仍限定明确Host和实际连接来源。
let requestPolicy = RequestPolicy(allowedHosts: ["127.0.0.1", "::1"].contains(bindAddress)
    ? ["127.0.0.1", "localhost", "::1"] : [bindAddress], trustedPeers: true)
let router = mkrtr(telemetry: telemetry, audit: auditStore, plans: planStore,
    serviceBroker: serviceBroker, mutationBroker: mutationBroker, siteNotes: siteNotes,
    backupDirectory: dataDirectory.appendingPathComponent("backups/databases", isDirectory: true),
    fileBackupDirectory: dataDirectory.appendingPathComponent("backups/files", isDirectory: true),
    packageBackupDirectory: dataDirectory.appendingPathComponent("backups/packages", isDirectory: true), requestPolicy: requestPolicy)

// 从本地应用资源提供同源页面。
let webRoot = environment["PANEL_WEB_ROOT"].map(URL.init(fileURLWithPath:))
    ?? authorizer.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/WebUI", isDirectory: true)
if FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path) {
    router.add(middleware: FileMiddleware(webRoot.path, searchForIndexHtml: true))
}

// Samples once per minute while the service is running.
let monitoringTask = Task {
    var nextPrune = Date.distantPast
    while !Task.isCancelled {
        _ = try? await telemetry.tick()
        if Date() >= nextPrune {
            _ = try? await telemetry.prune(before: Date().addingTimeInterval(-30 * 86_400))
            nextPrune = Date().addingTimeInterval(3_600)
        }
        try? await Task.sleep(for: .seconds(60))
    }
}
defer { monitoringTask.cancel() }

let app = Application(
    router: router,
    configuration: .init(address: .hostname(bindAddress, port: port))
)

try await app.runService()
