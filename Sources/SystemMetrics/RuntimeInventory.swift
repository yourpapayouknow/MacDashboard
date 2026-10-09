// 读取本机语言运行时，不启动Shell或安装工具。
struct RuntimeReader {
    // 仅探测已存在的固定工具路径和版本目录。
    func read() -> (rows: [RuntimeVersion], warnings: [String]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var rows: [RuntimeVersion] = []
        var warnings: [String] = []
        let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv"]
            .first { fm.isExecutableFile(atPath: $0) }
        if let uv {
            let result = runcmd(uv, ["python", "list", "--only-installed", "--output-format", "json", "--offline", "--no-config"], timeout: 10)
            if result.code == 0, let python = Self.prsuv(result.output) { rows += python }
            else { warnings.append("Python") }
        }
        var probes: [(String, String, String, [String])] = [
            ("ruby", "macOS", "/usr/bin/ruby", ["--version"]),
            ("perl", "macOS", "/usr/bin/perl", ["-v"]),
            ("swift", "Swiftly", "\(home)/.swiftly/bin/swift", ["--version"]),
            ("swift", "Apple工具链", "/usr/bin/swift", ["--version"]),
            ("cpp", "Apple工具链", "/usr/bin/clang", ["--version"]),
        ]
        if uv == nil { probes.append(("python", "macOS", "/usr/bin/python3", ["--version"])) }
        // 常见版本管理器按其现有版本目录枚举，不扫描项目虚拟环境。
        for (tool, source, directory, suffix) in [
            ("node", "nvm", "\(home)/.nvm/versions/node", "bin/node"),
            ("node", "fnm", "\(home)/.local/share/fnm/node-versions", "installation/bin/node"),
            ("node", "Volta", "\(home)/.volta/tools/image/node", "bin/node"),
            ("python", "uv", "\(home)/.local/share/uv/python", "bin/python3"),
            ("python", "pyenv", "\(home)/.pyenv/versions", "bin/python"),
        ] {
            for entry in (try? fm.contentsOfDirectory(atPath: directory))?.sorted().prefix(200) ?? [] {
                probes.append((tool, source, "\(directory)/\(entry)/\(suffix)", ["--version"]))
            }
        }
        // JDK只从已安装应用包读取，Homebrew链接由软件清单负责。
        for directory in ["/Library/Java/JavaVirtualMachines", "\(home)/Library/Java/JavaVirtualMachines"] {
            for entry in (try? fm.contentsOfDirectory(atPath: directory))?.sorted().prefix(200) ?? [] {
                probes.append(("java", "JDK", "\(directory)/\(entry)/Contents/Home/bin/java", ["--version"]))
            }
        }
        var checked = Set(rows.map { $0.tool + ":" + URL(fileURLWithPath: $0.installPath).resolvingSymlinksInPath().path })
        for (tool, source, path, arguments) in probes where fm.isExecutableFile(atPath: path) && !Self.brew(path) {
            guard checked.insert(tool + ":" + URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted else { continue }
            let result = runcmd(path, arguments, timeout: 10)
            if result.code == 0, let version = Self.vrsn(result.output) {
                rows.append(RuntimeVersion(tool: tool, version: version, installPath: path, active: false, source: source))
            } else { warnings.append(source + ":" + tool) }
        }
        return (Self.uniq(rows), Array(Set(warnings)).sorted())
    }

    // 提取语言工具返回的首个完整版本号。
    static func vrsn(_ text: String) -> String? {
        guard let range = text.range(of: #"(?<![0-9])\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.]+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // uv离线清单仅保留本机版本，Homebrew由原清单展示。
    static func prsuv(_ text: String) -> [RuntimeVersion]? {
        struct Row: Decodable { let version: String; let path: String? }
        guard let data = text.data(using: .utf8), let decoded = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return uniq(decoded.compactMap { row in
            guard let path = row.path, path.hasPrefix("/"), !brew(path) else { return nil }
            let source = path.hasPrefix("/usr/bin/") ? "macOS" : path.contains("/uv/python/") ? "uv" : "Python"
            return RuntimeVersion(tool: "python", version: row.version, installPath: path, active: false, source: source)
        })
    }

    // 合并管理器别名，保留不同安装位置的真实版本。
    static func uniq(_ rows: [RuntimeVersion]) -> [RuntimeVersion] {
        var seen: Set<String> = []
        return rows.filter { row in
            let path = URL(fileURLWithPath: row.installPath).resolvingSymlinksInPath().path
            return seen.insert(row.tool + ":" + row.version + ":" + path).inserted
        }.sorted { ($0.tool, $0.version, $0.installPath) < ($1.tool, $1.version, $1.installPath) }
    }

    // 识别Homebrew安装目录及其可执行链接。
    private static func brew(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ["/opt/homebrew/Cellar/", "/usr/local/Cellar/"].contains { real.hasPrefix($0) }
    }
}
