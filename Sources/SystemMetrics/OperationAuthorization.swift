// 从当前进程的有效签名生成同团队原生组件约束。
public enum NativeIdentity {
    // 缺少有效开发团队的进程不能信任特权组件。
    static let team: String? = {
        var code: SecCode?
        var origin: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &origin) == errSecSuccess, let origin,
              SecCodeCopySigningInformation(origin, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        return team
    }()

    // 仅接受精确标识、Apple证书链与同一开发团队。
    public static func cdreq(_ identifier: String) -> String {
        guard let team, (1...255).contains(identifier.utf8.count), identifier.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0)
        }) else { return "never" }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// Validates one online Authorization Services grant inside the privileged helper.
public enum OperationAuthorization {
    public static let right = kAuthorizationRightExecute

    // 重建并逐次核验系统授权，释放引用但保留系统有效会话。
    public static func verify(_ data: Data?) -> Bool {
        guard let data, data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreateFromExternalForm(&form, &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else { return false }
        defer { AuthorizationFree(authorization, []) }
        let status = right.withCString { rightName in
            var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: UnsafeMutablePointer(mutating: pointer))
                return AuthorizationCopyRights(authorization, &rights, nil, [], nil)
            }
        }
        return status == errAuthorizationSuccess
    }
}
