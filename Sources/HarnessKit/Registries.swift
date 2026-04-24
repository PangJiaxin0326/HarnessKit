import Foundation

public actor HarnessToolRegistry {
    private var toolsByName: [String: HarnessTool] = [:]

    public init() {}

    public func register(_ tool: HarnessTool) {
        toolsByName[normalized(tool.name)] = tool
    }

    public func descriptors() -> [HarnessToolDescriptor] {
        toolsByName.values
            .map(\.descriptor)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func invoke(named name: String, input: String) async throws -> String {
        guard let tool = toolsByName[normalized(name)] else {
            throw HarnessError.missingTool(name)
        }
        return try await tool.invoke(input)
    }

    public func tool(named name: String) -> HarnessToolDescriptor? {
        toolsByName[normalized(name)]?.descriptor
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public actor HarnessSkillRegistry {
    private let workspace: HarnessWorkspace
    private var registeredURLs: Set<URL> = []
    private var headersByURL: [URL: HarnessSkillHeader] = [:]

    public init(workspace: HarnessWorkspace) {
        self.workspace = workspace
    }

    @discardableResult
    public func registerSkill(at url: URL) throws -> HarnessSkillHeader {
        let standardizedURL = url.standardizedFileURL
        let document = try MarkdownSkillParser.parseSkill(at: standardizedURL)
        registeredURLs.insert(standardizedURL)
        headersByURL[standardizedURL] = document.header
        return document.header
    }

    @discardableResult
    public func refreshFromAgentsFile() throws -> [HarnessSkillHeader] {
        let agentURLs = try FileSystemUtilities.referencedMarkdownFiles(
            inAgentsFile: workspace.agentsFileURL,
            relativeTo: workspace.rootURL
        )
        let agentSkillURLs = agentURLs.filter {
            FileSystemUtilities.isDescendant($0, of: workspace.skillsDirectoryURL)
        }
        let allURLs = registeredURLs.union(agentSkillURLs.map(\.standardizedFileURL))
        var refreshedHeaders: [URL: HarnessSkillHeader] = [:]

        for url in allURLs {
            let document = try MarkdownSkillParser.parseSkill(at: url)
            refreshedHeaders[url] = document.header
        }

        headersByURL = refreshedHeaders
        return headers()
    }

    public func headers() -> [HarnessSkillHeader] {
        headersByURL.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func skillDocument(named name: String) throws -> HarnessSkillDocument? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let entry = headersByURL.values.first(where: { $0.name.lowercased() == normalized }) else {
            return nil
        }
        return try MarkdownSkillParser.parseSkill(at: entry.fileURL)
    }
}
