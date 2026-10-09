// 核验原生操作边界并复用内存中的有效系统授权会话。
public enum NativeGrant {
    private static let session = AuthorizationSession()
    // 按实际操作对象选择授权程序入口。
    public enum Scope: Sendable { case service, package, container, file, database }
    // 校验固定授权程序的签名身份。
    public static func trusted(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard geteuid() != 0,
              SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(NativeIdentity.cdreq("com.iwmei.macdashboard.panel-authorize") as CFString,
                  [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // 仅接收各管理域已有的精确动作和目标。
    public static func withgrant<T: Sendable>(_ executable: URL, scope: Scope,
        target: String, action: String, body: @Sendable (Data) async -> T) async -> T? {
        let service = scope == .service && ServiceController.validid(target)
            && ServiceAction(rawValue: action) != nil
        let package = scope == .package && PackageController.validid(target)
            && PackageController.actions.contains { $0.rawValue == action }
        let container = scope == .container && ContainerController.validid(target)
            && ContainerController.actions.contains { $0.rawValue == action }
        let file = scope == .file && FileController.validref(target) && FileController.actions.contains { $0.rawValue == action }
        let database = scope == .database && FileController.validref(target) && ["backup", "restore"].contains(action)
        guard (service || package || container || file || database), trusted(executable) else { return nil }
        let mode = service ? "service-grant" : package ? "package-grant" : container ? "container-grant" : database ? "database-grant" : "file-grant"
        return await session.rngrnt(executable, arguments: [mode, target, action], body: body)
    }
}

// 同一进程只在内存保留五分钟系统授权，过期主动释放。
actor AuthorizationSession {
    private var authorization: AuthorizationRef?
    private var grant: Data?
    private var deadline = 0.0
    private var expiry: Task<Void, Never>?
    private var active = false

    // 导入授权引用，保留原生授权进程结束后的同一会话。
    func hldauth(_ data: Data, lifetime: Duration = .seconds(300)) -> Bool {
        clr()
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
              let reference else { return false }
        authorization = reference
        grant = data
        let duration = min(300, max(0, Double(lifetime.components.seconds) + Double(lifetime.components.attoseconds) / 1e18))
        deadline = ProcessInfo.processInfo.systemUptime + duration
        expiry = Task {
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            clr()
        }
        return true
    }

    // 有效期内仍逐次验证，失效或撤销的授权不会被复用。
    func rdauth() -> Data? {
        guard let grant, ProcessInfo.processInfo.systemUptime < deadline,
              OperationAuthorization.verify(grant) else { clr(); return nil }
        return grant
    }

    // 释放本服务持有的会话引用，不清除其他进程的授权。
    func clr() {
        expiry?.cancel()
        expiry = nil
        if let authorization { AuthorizationFree(authorization, []) }
        authorization = nil
        grant = nil
        deadline = 0
    }

    // 串行复用有效会话，只有缺少授权时才启动系统请求。
    func rngrnt<T: Sendable>(_ executable: URL, arguments: [String], body: @Sendable (Data) async -> T) async -> T? {
        guard !active, !Task.isCancelled else { return nil }
        active = true
        defer { active = false }
        if let data = rdauth() { return await body(data) }
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        do { try process.run() } catch { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var data = Data()
        let size = MemoryLayout<AuthorizationExternalForm>.size
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline && data.count < size && !Task.isCancelled {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0 && descriptor.revents & Int16(POLLIN) != 0 {
                guard let part = try? output.fileHandleForReading.read(upToCount: size - data.count),
                      !part.isEmpty else { return nil }
                data.append(part)
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard data.count == size, process.isRunning, !Task.isCancelled, hldauth(data), rdauth() != nil else { return nil }
        return await body(data)
    }
}
