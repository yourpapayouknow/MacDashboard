// 描述固定命令的退出状态和有界输出。
struct NativeResult: Sendable {
    let code: Int32
    let output: String
}

// 软件和源共用非交互Homebrew执行器。
func brewcmd(_ path: String?, _ arguments: [String]) -> NativeResult {
    guard let path else { return NativeResult(code: -1, output: "") }
    return runcmd(path, arguments, timeout: ["install", "upgrade", "uninstall", "tap", "untap"].contains(arguments.first ?? "") ? 300 : 25,
        environment: ProcessInfo.processInfo.environment.merging([
            "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_INSTALL_UPGRADE": "1", "HOMEBREW_NO_ASK": "1", "HOMEBREW_NO_SUDO": "1",
        ]) { _, new in new })
}

// 执行调用方已验证的固定程序，限制耗时与输出。
func runcmd(_ path: String, _ arguments: [String], timeout: TimeInterval = 25,
    limit: Int = 4 * 1_024 * 1_024, environment: [String: String]? = nil) -> NativeResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.environment = (environment ?? ProcessInfo.processInfo.environment).merging([
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1",
    ]) { _, new in new }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return NativeResult(code: -1, output: "") }
    try? output.fileHandleForWriting.close()
    let descriptor = output.fileHandleForReading.fileDescriptor
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
        process.terminate()
        return NativeResult(code: -1, output: "")
    }
    defer { try? output.fileHandleForReading.close() }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    var failure: Int32?
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            guard data.count + count <= limit else { failure = -3; break }
            data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 && !process.isRunning { break }
        else if count < 0 && errno != EAGAIN && errno != EINTR { failure = -1; break }
        if ProcessInfo.processInfo.systemUptime >= deadline { failure = -2; break }
        if count <= 0 { usleep(10_000) }
    }
    if let failure {
        if process.isRunning { process.terminate() }
        let grace = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return NativeResult(code: failure, output: "")
    }
    return NativeResult(code: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
}
