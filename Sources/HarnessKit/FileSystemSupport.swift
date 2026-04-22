import Foundation

enum FileSystemUtilities {
    static func prepareWorkspace(_ workspace: HarnessWorkspace) throws {
        try ensureDirectory(workspace.rootURL)
        try ensureDirectory(workspace.skillsDirectoryURL)
        try ensureDirectory(workspace.memoryDirectoryURL)
        try ensureDirectory(workspace.cacheDirectoryURL)
        try ensureDirectory(workspace.agentsDirectoryURL)
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func readTextIfPresent(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ text: String, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func markdownFiles(in directoryURL: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }

        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func referencedMarkdownFiles(inAgentsFile agentsFileURL: URL, relativeTo rootURL: URL) throws -> [URL] {
        guard let contents = try readTextIfPresent(at: agentsFileURL) else {
            return []
        }

        var matches: Set<URL> = []
        let patterns = [
            #"\[[^\]]+\]\(([^)]+\.md)\)"#,
            #"(?<!\()(?<![A-Za-z0-9/_-])([A-Za-z0-9._/\-]+\.md)"#
        ]

        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            for match in regex.matches(in: contents, range: range) {
                guard match.numberOfRanges >= 2,
                      let captureRange = Range(match.range(at: 1), in: contents)
                else {
                    continue
                }

                let captured = String(contents[captureRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
                let resolvedURL = resolvePath(captured, relativeTo: rootURL)
                if FileManager.default.fileExists(atPath: resolvedURL.path) {
                    matches.insert(resolvedURL.standardizedFileURL)
                }
            }
        }

        return matches.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    static func resolvePath(_ path: String, relativeTo rootURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: false)
        }

        return rootURL.appendingPathComponent(path, isDirectory: false)
    }
}

struct SectionedMarkdownDocument {
    struct Section {
        let level: Int
        let title: String
        let body: String
    }

    let sections: [Section]

    init(text: String) {
        let lines = text.components(separatedBy: .newlines)
        var sections: [Section] = []
        var currentTitle: String?
        var currentLevel = 1
        var buffer: [String] = []

        func commitSection() {
            guard let currentTitle else { return }
            sections.append(Section(
                level: currentLevel,
                title: currentTitle,
                body: buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let prefix = trimmed.prefix { $0 == "#" }
                let title = trimmed.drop { $0 == "#" || $0 == " " }
                if !title.isEmpty {
                    commitSection()
                    currentTitle = String(title)
                    currentLevel = prefix.count
                    continue
                }
            }

            buffer.append(line)
        }

        commitSection()
        self.sections = sections
    }

    func body(for title: String) -> String? {
        sections.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })?.body
    }

    var firstHeading: String? {
        sections.first?.title
    }

    static func render(_ sections: [Section]) -> String {
        sections.map { section in
            let hashes = String(repeating: "#", count: max(section.level, 1))
            return "\(hashes) \(section.title)\n\(section.body)"
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MarkdownSkillParser {
    struct FrontMatter {
        var scalars: [String: String]
        var lists: [String: [String]]
    }

    static func parseSkill(at url: URL) throws -> HarnessSkillDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        let (frontMatter, body) = extractFrontMatter(from: text)
        let sections = SectionedMarkdownDocument(text: body)

        let name = frontMatter.scalars["name"]
            ?? sections.firstHeading
            ?? url.deletingPathExtension().lastPathComponent

        let description = frontMatter.scalars["description"]
            ?? firstParagraph(in: body)
            ?? "No description provided."

        let tools = frontMatter.lists["tools"]
            ?? bulletList(in: sections.body(for: "Tools") ?? "")

        let header = HarnessSkillHeader(
            name: name,
            description: description,
            tools: tools,
            fileURL: url
        )

        return HarnessSkillDocument(
            header: header,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func extractFrontMatter(from text: String) -> (FrontMatter, String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
            return (FrontMatter(scalars: [:], lists: [:]), text)
        }

        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return (FrontMatter(scalars: [:], lists: [:]), text)
        }

        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var currentListKey: String?
        var bodyStartIndex: Int?

        for index in lines.indices.dropFirst() {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" {
                bodyStartIndex = index + 1
                break
            }

            if trimmed.hasPrefix("- "), let currentListKey {
                lists[currentListKey, default: []].append(
                    String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                )
                continue
            }

            currentListKey = nil

            guard let colonIndex = trimmed.firstIndex(of: ":") else {
                continue
            }

            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if value.isEmpty {
                currentListKey = key
                continue
            }

            if value.hasPrefix("[") && value.hasSuffix("]") {
                let rawValues = value
                    .dropFirst()
                    .dropLast()
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .map { String($0) }
                lists[key] = rawValues
            } else {
                scalars[key] = value
            }
        }

        guard let bodyStartIndex else {
            return (FrontMatter(scalars: scalars, lists: lists), text)
        }

        let body = lines[bodyStartIndex...].joined(separator: "\n")
        return (FrontMatter(scalars: scalars, lists: lists), body)
    }

    private static func firstParagraph(in body: String) -> String? {
        body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first {
                !$0.isEmpty &&
                !$0.hasPrefix("#") &&
                !$0.hasPrefix("-") &&
                !$0.hasPrefix("*")
            }
    }

    private static func bulletList(in section: String) -> [String] {
        section.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

public actor FileSystemMemoryStore: HarnessMemoryStoring {
    private let rootDirectoryURL: URL
    private var registeredURLs: Set<URL> = []

    public init(rootDirectoryURL: URL) throws {
        self.rootDirectoryURL = rootDirectoryURL
        try FileSystemUtilities.ensureDirectory(rootDirectoryURL)
    }

    public func registerMemoryFile(at url: URL) async {
        registeredURLs.insert(url.standardizedFileURL)
    }

    public func memoryFileURLs() async throws -> [URL] {
        let discovered = try FileSystemUtilities.markdownFiles(in: rootDirectoryURL)
        return Array(registeredURLs.union(discovered.map(\.standardizedFileURL))).sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    public func readMemoryFiles() async throws -> [HarnessMemoryFile] {
        try await memoryFileURLs().map { url in
            HarnessMemoryFile(url: url, contents: try String(contentsOf: url, encoding: .utf8))
        }
    }
}

public actor FileSystemHarnessCache: HarnessCaching {
    private let rootDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectoryURL: URL) throws {
        self.rootDirectoryURL = rootDirectoryURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileSystemUtilities.ensureDirectory(rootDirectoryURL)
    }

    public func createRecord(
        rawInput: String,
        processedContext: String,
        metadata: HarnessCacheMetadata
    ) async throws -> HarnessCacheRecord {
        let directoryURL = rootDirectoryURL.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        let rawInputURL = directoryURL.appendingPathComponent("raw-input.txt", isDirectory: false)
        let processedContextURL = directoryURL.appendingPathComponent("processed-context.md", isDirectory: false)
        let rawOutputURL = directoryURL.appendingPathComponent("raw-output.txt", isDirectory: false)
        let metadataURL = directoryURL.appendingPathComponent("metadata.json", isDirectory: false)

        try FileSystemUtilities.ensureDirectory(directoryURL)
        try FileSystemUtilities.write(rawInput, to: rawInputURL)
        try FileSystemUtilities.write(processedContext, to: processedContextURL)
        FileManager.default.createFile(atPath: rawOutputURL.path, contents: Data())
        try encoder.encode(metadata).write(to: metadataURL)

        return HarnessCacheRecord(
            metadata: metadata,
            directoryURL: directoryURL,
            rawInputURL: rawInputURL,
            processedContextURL: processedContextURL,
            rawOutputURL: rawOutputURL,
            metadataURL: metadataURL
        )
    }

    public func updateOutput(
        for record: HarnessCacheRecord,
        rawOutput: String
    ) async throws {
        try FileSystemUtilities.write(rawOutput, to: record.rawOutputURL)
    }

    public func records() async throws -> [HarnessCacheRecord] {
        guard FileManager.default.fileExists(atPath: rootDirectoryURL.path) else {
            return []
        }

        let directories = try FileManager.default.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try directories.compactMap { directoryURL in
            let metadataURL = directoryURL.appendingPathComponent("metadata.json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: metadataURL.path) else {
                return nil
            }

            let metadata = try decoder.decode(HarnessCacheMetadata.self, from: Data(contentsOf: metadataURL))
            return HarnessCacheRecord(
                metadata: metadata,
                directoryURL: directoryURL,
                rawInputURL: directoryURL.appendingPathComponent("raw-input.txt", isDirectory: false),
                processedContextURL: directoryURL.appendingPathComponent("processed-context.md", isDirectory: false),
                rawOutputURL: directoryURL.appendingPathComponent("raw-output.txt", isDirectory: false),
                metadataURL: metadataURL
            )
        }
    }
}

public actor FileSystemSubagentManager: HarnessSubagentManaging {
    private let agentsDirectoryURL: URL

    public init(agentsDirectoryURL: URL) throws {
        self.agentsDirectoryURL = agentsDirectoryURL
        try FileSystemUtilities.ensureDirectory(agentsDirectoryURL)
    }

    public func createSubagent(
        taskSummary: String,
        input: String,
        context: String
    ) async throws -> HarnessSubagentRecord {
        let identifier = UUID().uuidString.lowercased()
        let directoryURL = agentsDirectoryURL.appendingPathComponent(identifier, isDirectory: true)
        try FileSystemUtilities.ensureDirectory(directoryURL)

        let contextRecord = HarnessContextResolution(
            status: context.isEmpty ? .empty : .provided,
            details: context
        )
        let inputRecord = HarnessSubagentInput(task: input)
        let outputRecord = HarnessSubagentOutput(taskSummary: taskSummary)

        try writeContext(contextRecord, to: directoryURL)
        try writeInput(inputRecord, to: directoryURL)
        try writeOutput(outputRecord, to: directoryURL)

        return HarnessSubagentRecord(
            id: identifier,
            directoryURL: directoryURL,
            context: contextRecord,
            input: inputRecord,
            output: outputRecord
        )
    }

    public func listSubagents() async throws -> [HarnessSubagentRecord] {
        guard FileManager.default.fileExists(atPath: agentsDirectoryURL.path) else {
            return []
        }

        let directories = try FileManager.default.contentsOfDirectory(
            at: agentsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try directories.compactMap(readSubagent)
    }

    public func subagent(id: String) async throws -> HarnessSubagentRecord? {
        try readSubagent(
            at: agentsDirectoryURL.appendingPathComponent(id, isDirectory: true)
        )
    }

    public func markNeedsMoreContext(for id: String, request: String) async throws {
        guard var record = try await subagent(id: id) else {
            throw HarnessError.missingSubagent(id)
        }

        record.input.needsMoreContext = true
        record.input.contextRequest = request
        try writeInput(record.input, to: record.directoryURL)
    }

    public func satisfyContextRequest(for id: String, context: String) async throws -> HarnessSubagentRecord {
        guard var record = try await subagent(id: id) else {
            throw HarnessError.missingSubagent(id)
        }

        record.context = HarnessContextResolution(status: .provided, details: context)
        record.input.needsMoreContext = false
        record.input.contextRequest = ""
        try writeContext(record.context, to: record.directoryURL)
        try writeInput(record.input, to: record.directoryURL)
        return record
    }

    public func rejectContextRequest(for id: String, reason: String) async throws -> HarnessSubagentRecord {
        guard var record = try await subagent(id: id) else {
            throw HarnessError.missingSubagent(id)
        }

        record.context = HarnessContextResolution(status: .rejected, details: reason)
        record.input.needsMoreContext = false
        record.input.contextRequest = ""
        try writeContext(record.context, to: record.directoryURL)
        try writeInput(record.input, to: record.directoryURL)
        return record
    }

    public func updateOutput(for id: String, summary: String, output: String) async throws -> HarnessSubagentRecord {
        guard var record = try await subagent(id: id) else {
            throw HarnessError.missingSubagent(id)
        }

        record.output = HarnessSubagentOutput(taskSummary: summary, output: output)
        try writeOutput(record.output, to: record.directoryURL)
        return record
    }

    private func readSubagent(at directoryURL: URL) throws -> HarnessSubagentRecord? {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return nil
        }

        let identifier = directoryURL.lastPathComponent
        let context = try readContext(from: directoryURL)
        let input = try readInput(from: directoryURL)
        let output = try readOutput(from: directoryURL)

        return HarnessSubagentRecord(
            id: identifier,
            directoryURL: directoryURL,
            context: context,
            input: input,
            output: output
        )
    }

    private func writeContext(_ context: HarnessContextResolution, to directoryURL: URL) throws {
        let document = SectionedMarkdownDocument.render([
            .init(level: 1, title: "Context", body: context.details),
            .init(level: 2, title: "Resolution", body: context.status.rawValue)
        ])
        try FileSystemUtilities.write(document, to: directoryURL.appendingPathComponent("CONTEXT.md", isDirectory: false))
    }

    private func writeInput(_ input: HarnessSubagentInput, to directoryURL: URL) throws {
        let document = SectionedMarkdownDocument.render([
            .init(level: 1, title: "Input", body: input.task),
            .init(level: 2, title: "Need More Context", body: input.needsMoreContext ? "true" : "false"),
            .init(level: 2, title: "Context Request", body: input.contextRequest)
        ])
        try FileSystemUtilities.write(document, to: directoryURL.appendingPathComponent("INPUT.md", isDirectory: false))
    }

    private func writeOutput(_ output: HarnessSubagentOutput, to directoryURL: URL) throws {
        let document = SectionedMarkdownDocument.render([
            .init(level: 1, title: "Task Summary", body: output.taskSummary),
            .init(level: 2, title: "Output", body: output.output)
        ])
        try FileSystemUtilities.write(document, to: directoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false))
    }

    private func readContext(from directoryURL: URL) throws -> HarnessContextResolution {
        let url = directoryURL.appendingPathComponent("CONTEXT.md", isDirectory: false)
        let text = try FileSystemUtilities.readTextIfPresent(at: url) ?? ""
        let document = SectionedMarkdownDocument(text: text)
        let details = document.body(for: "Context") ?? ""
        let status = HarnessContextResolution.Status(rawValue: document.body(for: "Resolution") ?? "") ?? .empty
        return HarnessContextResolution(status: status, details: details)
    }

    private func readInput(from directoryURL: URL) throws -> HarnessSubagentInput {
        let url = directoryURL.appendingPathComponent("INPUT.md", isDirectory: false)
        let text = try FileSystemUtilities.readTextIfPresent(at: url) ?? ""
        let document = SectionedMarkdownDocument(text: text)
        let task = document.body(for: "Input") ?? ""
        let needsMoreContext = (document.body(for: "Need More Context") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        let contextRequest = document.body(for: "Context Request") ?? ""
        return HarnessSubagentInput(task: task, needsMoreContext: needsMoreContext, contextRequest: contextRequest)
    }

    private func readOutput(from directoryURL: URL) throws -> HarnessSubagentOutput {
        let url = directoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false)
        let text = try FileSystemUtilities.readTextIfPresent(at: url) ?? ""
        let document = SectionedMarkdownDocument(text: text)
        return HarnessSubagentOutput(
            taskSummary: document.body(for: "Task Summary") ?? "",
            output: document.body(for: "Output") ?? ""
        )
    }
}
