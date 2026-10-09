/// Configuration errors that must stop service startup.
public enum PanelConfigError: Error, Equatable, Sendable {
    case invalidPort
    case invalidAddress
}

// 原生解析数字地址，拒绝域名、作用域、嵌入NUL和非地址字符。
public func nrmaddr(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 45, value.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || [46, 58].contains($0)
    }) else { return nil }
    if value.contains("."), value.split(separator: ":").last?.split(separator: ".").contains(where: {
        $0.count > 1 && $0.hasPrefix("0")
    }) != false { return nil }
    if value.contains(":") {
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return nil }
        return withUnsafePointer(to: &address) { addrstr(AF_INET6, $0) }
    }
    var address = in_addr()
    guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
    return withUnsafePointer(to: &address) { addrstr(AF_INET, $0) }
}

// 两种地址族共用系统规范文本转换。
private func addrstr(_ family: Int32, _ address: UnsafeRawPointer) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    return buffer.withUnsafeMutableBufferPointer { bytes in
        guard let base = bytes.baseAddress, inet_ntop(family, address, base, socklen_t(bytes.count)) != nil else { return nil }
        return String(cString: base)
    }
}

// 只允许回环、私有IPv4、唯一局部IPv6及Tailscale来源。
public func prvtaddr(_ value: String) -> Bool {
    guard let address = nrmaddr(value) else { return false }
    if address == "::1" { return true }
    if address.hasPrefix("::ffff:") { return prvtaddr(String(address.dropFirst(7))) }
    if address.contains(":") {
        guard let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              let prefix = UInt16(first, radix: 16) else { return false }
        return (0xfc00...0xfdff).contains(prefix)
    }
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == 4, zip(parts, numbers).allSatisfy({ String($1) == $0 && (0...255).contains($1) }) else { return false }
    return numbers[0] == 127 || numbers[0] == 10
        || (numbers[0] == 172 && (16...31).contains(numbers[1]))
        || (numbers[0] == 192 && numbers[1] == 168)
        || (numbers[0] == 100 && (64...127).contains(numbers[1]))
}

// 默认仅本机，显式选择一个可信接口，禁止公共、通配与映射监听。
public func prsbnd(_ value: String?) throws -> String {
    guard let address = nrmaddr(value ?? "127.0.0.1"), !address.hasPrefix("::ffff:"), prvtaddr(address) else {
        throw PanelConfigError.invalidAddress
    }
    return address
}

// 应用启动与健康检查共用带IPv6方括号的明确面板URL。
public func pnlurl(_ host: String, port: Int) -> URL? {
    guard let address = try? prsbnd(host), (1...65_535).contains(port) else { return nil }
    let authority = address.contains(":") ? "[\(address)]" : address
    return URL(string: "http://\(authority):\(port)/")
}

/// Parses a required TCP listener port.
public func prsprt(_ value: String?) throws -> Int {
    guard
        let value,
        let port = Int(value),
        (1...65_535).contains(port)
    else {
        throw PanelConfigError.invalidPort
    }
    return port
}
