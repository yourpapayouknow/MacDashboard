/// One configured Docker endpoint.
public struct DockerContext: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let endpoint: String
    public let isCurrent: Bool
    public let error: String?
}

/// One local Docker container with operational fields only.
public struct DockerContainer: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let ports: String
    public let networks: [String]
}

/// Complete supported local container-provider snapshot.
public struct ContainerInventory: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let dockerAvailable: Bool
    public let daemonAvailable: Bool
    public let serverVersion: String?
    public let endpoint: String?
    public let daemonID: String?
    public let contexts: [DockerContext]
    public let containers: [DockerContainer]
    public let podmanAvailable: Bool
    public let colimaAvailable: Bool
    public let limaAvailable: Bool
    public let orbStackAvailable: Bool
}

/// Reads local container providers through fixed read-only CLI contracts.
public struct ContainerReader: Sendable {
    public let dockerPath: String?

    /// Creates a reader for standard provider installation locations.
    public init() {
        self.dockerPath = Self.find(["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"])
    }

    /// Creates a deterministic reader for fixtures.
    init(dockerPath: String?) {
        self.dockerPath = dockerPath
    }

    /// Returns provider availability, contexts, daemon version, and every container.
    public func read() -> ContainerInventory {
        let contexts = dockerPath.flatMap { run($0, ["context", "ls", "--format", "{{json .}}"] ) }
            .map(Self.prtctx) ?? []
        let controller = ContainerController(path: dockerPath)
        let endpoint = dockerPath == nil ? nil : controller.rdhost()
        let daemonID = endpoint.flatMap(controller.rddmn)
        let containers = endpoint.flatMap { host in dockerPath.flatMap {
            run($0, ["--host", host, "ps", "-a", "--no-trunc", "--format", "{{json .}}"])
        } }
            .map(Self.prtctr) ?? []
        let version = endpoint.flatMap { host in dockerPath.flatMap {
            run($0, ["--host", host, "info", "--format", "{{json .ServerVersion}}"])
        } }
            .flatMap(Self.prtver)
        return ContainerInventory(
            sampledAt: Date(),
            dockerAvailable: dockerPath != nil,
            daemonAvailable: version != nil && daemonID != nil,
            serverVersion: version,
            endpoint: endpoint,
            daemonID: daemonID,
            contexts: contexts,
            containers: containers,
            podmanAvailable: Self.find(["/opt/homebrew/bin/podman", "/usr/local/bin/podman"]) != nil,
            colimaAvailable: Self.find(["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]) != nil,
            limaAvailable: Self.find(["/opt/homebrew/bin/limactl", "/usr/local/bin/limactl"]) != nil,
            orbStackAvailable: FileManager.default.fileExists(atPath: "/Applications/OrbStack.app")
        )
    }

    /// Parses newline-delimited Docker context JSON.
    static func prtctx(_ text: String) -> [DockerContext] {
        text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONDecoder().decode(DockerContextRow.self, from: Data(line.utf8)) else { return nil }
            return DockerContext(
                name: row.name,
                description: row.description,
                endpoint: row.endpoint,
                isCurrent: row.current,
                error: row.error.isEmpty ? nil : row.error
            )
        }
    }

    /// Parses newline-delimited Docker container JSON without labels or mount sources.
    static func prtctr(_ text: String) -> [DockerContainer] {
        text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONDecoder().decode(DockerContainerRow.self, from: Data(line.utf8)) else { return nil }
            return DockerContainer(
                id: row.id,
                name: row.names,
                image: row.image,
                state: row.state,
                status: row.status,
                ports: row.ports,
                networks: row.networks.split(separator: ",").map(String.init)
            )
        }
    }

    /// Decodes Docker's JSON string version result.
    private static func prtver(_ text: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// Runs one of three fixed read-only Docker commands.
    private func run(_ path: String, _ arguments: [String]) -> String? {
        guard path == dockerPath else { return nil }
        let result = runcmd(path, arguments, environment: ContainerController.clnenv())
        return result.code == 0 ? result.output : nil
    }

    /// Finds the first executable from fixed supported locations.
    private static func find(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Docker context JSON fields.
private struct DockerContextRow: Decodable {
    let current: Bool
    let description: String
    let endpoint: String
    let error: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case current = "Current", description = "Description", endpoint = "DockerEndpoint"
        case error = "Error", name = "Name"
    }
}

/// Docker container JSON fields excluding sensitive labels and mounts.
private struct DockerContainerRow: Decodable {
    let id: String
    let image: String
    let names: String
    let networks: String
    let ports: String
    let state: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id = "ID", image = "Image", names = "Names", networks = "Networks"
        case ports = "Ports", state = "State", status = "Status"
    }
}
