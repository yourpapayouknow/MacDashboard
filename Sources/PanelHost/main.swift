import Foundation
import AppKit
import PanelConfig
@preconcurrency import ServiceManagement

private let plistName = "com.iwmei.macdashboard.monitor-helper.native.plist"
private let serviceID = "com.iwmei.macdashboard.monitor-helper.native"
private let legacyName = "com.iwmei.macdashboard.monitor-helper.plist"
private let legacyURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(legacyName)")

/// Stores one completion result across the Service Management callback boundary.
final class HostResult: @unchecked Sendable {
    let lock = NSLock()
    var message: String?
}

/// Converts the native service state into a stable command-line value.
func statename(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
}

/// Writes one deterministic JSON result for scripts and the future WebUI bridge.
func wrresult(
    _ command: String,
    status: SMAppService.Status,
    legacy: SMAppService.Status? = nil,
    message: String? = nil
) {
    var value: [String: String] = [
        "command": command,
        "service": serviceID,
        "status": statename(status),
    ]
    if let legacy { value["legacyStatus"] = statename(legacy) }
    if let message { value["message"] = message }
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Rejects registration changes when this executable is not running from its app bundle.
func chkapp() -> Bool {
    Bundle.main.bundleURL.pathExtension == "app"
}

/// Treats a registered daemon awaiting macOS approval as a completed installation step.
func regresult(_ command: String, service: SMAppService, error: Error) -> Int32 {
    wrresult(command, status: service.status, message: error.localizedDescription)
    return service.status == .requiresApproval ? 0 : 1
}

/// Replaces a registered daemon only after Service Management finishes removing its prior version.
func reregister(_ service: SMAppService) -> Int32 {
    if service.status == .notRegistered || service.status == .notFound {
        do {
            try service.register()
            wrresult("reregister", status: service.status)
            return 0
        } catch {
            return regresult("reregister", service: service, error: error)
        }
    }

    let done = DispatchSemaphore(value: 0)
    let result = HostResult()
    service.unregister { error in
        defer { done.signal() }
        if let error {
            result.lock.withLock { result.message = error.localizedDescription }
        }
    }
    done.wait()
    if let message = result.lock.withLock({ result.message }) {
        wrresult("reregister", status: service.status, message: message)
        return 1
    }

    Thread.sleep(forTimeInterval: 2)
    do {
        try service.register()
        wrresult("reregister", status: service.status)
        return 0
    } catch {
        return regresult("reregister", service: service, error: error)
    }
}

// 检查同源页面与原生服务是否均可读取。
func rdhealth(_ port: Int, _ host: String) async -> Bool {
    guard let base = pnlurl(host, port: port) else { return false }
    do {
        var request = URLRequest(url: base.appendingPathComponent("api/v1/health"))
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
              value["status"] == "ok", value["apiVersion"] == "v1" else { return false }
        request.url = base
        let (_, page) = try await URLSession.shared.data(for: request)
        return (page as? HTTPURLResponse)?.statusCode == 200
            && page.mimeType == "text/html"
    } catch { return false }
}

// 从应用包启动本机服务并打开同源管理界面。
@MainActor func opnpnl(_ service: SMAppService) async -> Int32 {
    guard chkapp(), geteuid() != 0, let executable = Bundle.main.executableURL else {
        wrresult("open", status: service.status, message: "请以当前用户打开MacDashboard.app")
        return 64
    }
    let environment = ProcessInfo.processInfo.environment
    let port: Int
    let bindAddress: String
    do {
        port = try prsprt(environment["PANEL_PORT"] ?? "18761")
        bindAddress = try prsbnd(environment["PANEL_BIND_ADDRESS"])
    }
    catch {
        wrresult("open", status: service.status, message: "面板端口或监听地址无效")
        return 64
    }
    guard let address = pnlurl(bindAddress, port: port) else {
        wrresult("open", status: service.status, message: "面板端口或监听地址无效")
        return 64
    }
    if !(await rdhealth(port, bindAddress)) {
        let webRoot = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/WebUI")
        guard FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path) else {
            wrresult("open", status: service.status, message: "应用内缺少管理页面")
            return 66
        }
        do {
            let dataDirectory = environment["PANEL_DATA_DIR"].map(URL.init(fileURLWithPath:))
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MacDashboard", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let logURL = dataDirectory.appendingPathComponent("service.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            try log.seekToEnd()
            let process = Process()
            process.executableURL = executable.deletingLastPathComponent().appendingPathComponent("PanelService")
            // 应用默认开放已实现动作，保留显式只读及fixture模式。
            process.environment = environment.merging([
                "PANEL_PORT": String(port), "PANEL_BIND_ADDRESS": bindAddress, "PANEL_WEB_ROOT": webRoot.path,
                "PANEL_NATIVE_ACTIONS": environment["PANEL_NATIVE_ACTIONS"] ?? "1",
            ]) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            try process.run()
            var ready = false
            for _ in 0..<40 {
                if await rdhealth(port, bindAddress) { ready = true; break }
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard ready else {
                if process.isRunning { process.terminate() }
                wrresult("open", status: service.status, message: "端口被占用或启动失败，请查看service.log")
                return 1
            }
        } catch {
            wrresult("open", status: service.status, message: error.localizedDescription)
            return 1
        }
    }
    if !CommandLine.arguments.contains("--no-browser"), !NSWorkspace.shared.open(address) {
        wrresult("open", status: service.status, message: "服务已启动，未能打开浏览器：\(address.absoluteString)")
        return 1
    }
    wrresult("open", status: service.status, message: address.absoluteString)
    return 0
}

/// Runs the narrow Service Management command selected by the local app.
func runhost() async -> Int32 {
    let command = CommandLine.arguments.dropFirst().first ?? (chkapp() ? "open" : "status")
    let service = SMAppService.daemon(plistName: plistName)

    switch command {
    case "open":
        return await opnpnl(service)
    case "status":
        wrresult(
            command,
            status: service.status,
            legacy: SMAppService.statusForLegacyPlist(at: legacyURL)
        )
        return 0
    case "register":
        guard chkapp() else {
            wrresult(command, status: service.status, message: "Run PanelHost from MacDashboard.app")
            return 64
        }
        do {
            try service.register()
            wrresult(command, status: service.status)
            return 0
        } catch {
            return regresult(command, service: service, error: error)
        }
    case "reregister":
        guard chkapp() else {
            wrresult(command, status: service.status, message: "Run PanelHost from MacDashboard.app")
            return 64
        }
        return reregister(service)
    case "unregister":
        guard chkapp(), CommandLine.arguments.dropFirst(2).first == serviceID else {
            wrresult(command, status: service.status, message: "Repeat the service identifier to confirm removal")
            return 64
        }
        do {
            try await service.unregister()
            wrresult(command, status: service.status)
            return 0
        } catch {
            wrresult(command, status: service.status, message: error.localizedDescription)
            return 1
        }
    case "open-settings":
        SMAppService.openSystemSettingsLoginItems()
        wrresult(command, status: service.status)
        return 0
    default:
        wrresult(command, status: service.status, message: "Usage: PanelHost <open [--no-browser]|status|register|reregister|open-settings|unregister SERVICE_ID>")
        return 64
    }
}

exit(await runhost())
