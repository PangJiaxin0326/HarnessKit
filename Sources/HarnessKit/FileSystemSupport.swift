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
        .filter { $0.pathExtension.lowercased() == "md" && isRegularFile($0) }
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
                if let resolvedURL = resolvedMarkdownURL(for: captured, relativeTo: rootURL) {
                    matches.insert(resolvedURL.standardizedFileURL)
                }
            }
        }

        return matches.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    static func referencedMarkdownDocuments(
        inAgentsFile agentsFileURL: URL,
        relativeTo rootURL: URL,
        excluding excludedURLs: Set<URL> = []
    ) throws -> [HarnessReferenceDocument] {
        let excludedPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })
        return try referencedMarkdownFiles(inAgentsFile: agentsFileURL, relativeTo: rootURL)
            .filter { !excludedPaths.contains($0.standardizedFileURL.path) }
            .map { url in
                let contents = try String(contentsOf: url, encoding: .utf8)
                let title = SectionedMarkdownDocument(text: contents).firstHeading
                    ?? url.deletingPathExtension().lastPathComponent
                return HarnessReferenceDocument(url: url, title: title, contents: contents)
            }
    }

    static func resolvePath(_ path: String, relativeTo rootURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: false)
        }

        return rootURL.appendingPathComponent(path, isDirectory: false)
    }

    static func isDescendant(_ url: URL, of directoryURL: URL) -> Bool {
        let path = canonicalURL(url).path
        var directoryPath = canonicalURL(directoryURL).path
        if !directoryPath.hasSuffix("/") {
            directoryPath += "/"
        }
        return path.hasPrefix(directoryPath)
    }

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func resolvedMarkdownURL(for path: String, relativeTo rootURL: URL) -> URL? {
        let primaryURL = resolvePath(path, relativeTo: rootURL)
        if isRegularFile(primaryURL), isDescendant(primaryURL, of: rootURL) {
            return primaryURL
        }

        guard !path.contains("/") else {
            return nil
        }

        let docsURL = rootURL
            .appendingPathComponent("Docs", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        if isRegularFile(docsURL), isDescendant(docsURL, of: rootURL) {
            return docsURL
        }

        return nil
    }
}

struct SectionedMarkdownDocument {
    struct Section {
        let level: Int
        let title: String
        let body: String
        let bodyIncludingSubsections: String
        fileprivate let index: Int

        init(
            level: Int,
            title: String,
            body: String,
            bodyIncludingSubsections: String? = nil,
            index: Int = 0
        ) {
            self.level = level
            self.title = title
            self.body = body
            self.bodyIncludingSubsections = bodyIncludingSubsections ?? body
            self.index = index
        }
    }

    let sections: [Section]

    init(text: String) {
        let lines = text.components(separatedBy: .newlines)
        let headings = MarkdownHeading.headings(in: lines)
        self.sections = headings.enumerated().map { offset, heading in
            let bodyStartIndex = heading.lineIndex + 1
            let remainingHeadings = headings.dropFirst(offset + 1)
            let immediateEndIndex = remainingHeadings.first?.lineIndex ?? lines.count
            let subtreeEndIndex = remainingHeadings.first(where: { $0.level <= heading.level })?.lineIndex ?? lines.count

            return Section(
                level: heading.level,
                title: heading.title,
                body: Self.body(in: lines, from: bodyStartIndex, to: immediateEndIndex),
                bodyIncludingSubsections: Self.body(in: lines, from: bodyStartIndex, to: subtreeEndIndex),
                index: offset
            )
        }
    }

    func body(for title: String) -> String? {
        section(named: title)?.body
    }

    func bodyIncludingSubsections(for title: String) -> String? {
        section(named: title)?.bodyIncludingSubsections
    }

    var firstHeading: String? {
        sections.first?.title
    }

    func section(named title: String) -> Section? {
        sections.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    func containsSubsection(named childTitle: String, under parentTitle: String) -> Bool {
        guard let parent = section(named: parentTitle) else {
            return false
        }

        return sections
            .dropFirst(parent.index + 1)
            .prefix { $0.level > parent.level }
            .contains { $0.title.caseInsensitiveCompare(childTitle) == .orderedSame }
    }

    static func render(_ sections: [Section]) -> String {
        sections.map { section in
            let hashes = String(repeating: "#", count: max(section.level, 1))
            return "\(hashes) \(section.title)\n\(section.body)"
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func body(in lines: [String], from startIndex: Int, to endIndex: Int) -> String {
        guard startIndex < endIndex else {
            return ""
        }

        return lines[startIndex..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct MarkdownHeading {
        var lineIndex: Int
        var level: Int
        var title: String

        static func headings(in lines: [String]) -> [MarkdownHeading] {
            var headings: [MarkdownHeading] = []
            var activeFence: String?

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if let fence = activeFence {
                    if trimmed.hasPrefix(fence) {
                        activeFence = nil
                    }
                    continue
                }

                if trimmed.hasPrefix("```") {
                    activeFence = "```"
                    continue
                }

                if trimmed.hasPrefix("~~~") {
                    activeFence = "~~~"
                    continue
                }

                guard let heading = parseHeading(trimmed, lineIndex: lineIndex) else {
                    continue
                }
                headings.append(heading)
            }

            return headings
        }

        private static func parseHeading(_ line: String, lineIndex: Int) -> MarkdownHeading? {
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count) else {
                return nil
            }

            let remainder = line.dropFirst(hashes.count)
            guard remainder.first?.isWhitespace == true else {
                return nil
            }

            let title = String(remainder.drop(while: \.isWhitespace))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return nil
            }

            return MarkdownHeading(lineIndex: lineIndex, level: hashes.count, title: title)
        }
    }
}

struct MarkdownSkillParser {
    struct FrontMatter {
        var scalars: [String: String]
        var lists: [String: [String]]
    }

    static func parseSkill(at url: URL) throws -> HarnessSkillDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        let (frontMatter, body) = try extractFrontMatter(from: text, sourceURL: url)
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

    private static func extractFrontMatter(from text: String, sourceURL: URL) throws -> (FrontMatter, String) {
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
                lists[currentListKey, default: []].append(normalizedScalar(String(trimmed.dropFirst(2))))
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
                lists[key] = inlineListValues(from: value)
            } else {
                scalars[key] = normalizedScalar(value)
            }
        }

        guard let bodyStartIndex else {
            throw HarnessError.invalidSkillFile(sourceURL)
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
            .map { normalizedScalar(String($0.dropFirst(2))) }
    }

    private static func inlineListValues(from value: String) -> [String] {
        let contents = value.dropFirst().dropLast()
        var values: [String] = []
        var current = ""
        var activeQuote: Character?

        for character in contents {
            if let quote = activeQuote {
                current.append(character)
                if character == quote {
                    activeQuote = nil
                }
                continue
            }

            if character == "'" || character == "\"" {
                activeQuote = character
                current.append(character)
            } else if character == "," {
                values.append(normalizedScalar(current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(normalizedScalar(current))
        }

        return values
    }

    private static func normalizedScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else {
            return trimmed
        }

        return String(trimmed.dropFirst().dropLast())
    }
}

enum SubagentMarkdownFields {
    private static let escapedStartMarkerPrefix = "<!-- HarnessKit-Field-Escaped-Start:"
    private static let escapedEndMarkerPrefix = "<!-- HarnessKit-Field-Escaped-End:"

    static func render(documentTitle: String, fields: [(name: String, value: String)]) -> String {
        var parts = ["# \(documentTitle)"]
        parts.append(contentsOf: fields.map { field in
            """
            <!-- HarnessKit:\(field.name) -->
            \(escapeFieldValue(field.value))
            <!-- /HarnessKit:\(field.name) -->
            """
        })
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func field(named name: String, in text: String) -> String? {
        let startMarker = "<!-- HarnessKit:\(name) -->"
        let endMarker = "<!-- /HarnessKit:\(name) -->"

        guard
            let startRange = text.range(of: startMarker),
            let endRange = text.range(of: endMarker, range: startRange.upperBound..<text.endIndex)
        else {
            return nil
        }

        let value = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unescapeFieldValue(value)
    }

    private static func escapeFieldValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<!-- /HarnessKit:", with: escapedEndMarkerPrefix)
            .replacingOccurrences(of: "<!-- HarnessKit:", with: escapedStartMarkerPrefix)
    }

    private static func unescapeFieldValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: escapedStartMarkerPrefix, with: "<!-- HarnessKit:")
            .replacingOccurrences(of: escapedEndMarkerPrefix, with: "<!-- /HarnessKit:")
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
        try FileSystemUtilities.write("", to: rawOutputURL)
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
            at: subagentDirectoryURL(for: id)
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

        let state = SubagentFileState(directoryURL: directoryURL)
        switch state.validation {
        case .absent:
            return nil
        case .invalid(let missingFiles):
            throw HarnessError.invalidSubagent(
                "Subagent '\(directoryURL.lastPathComponent)' is missing required files: \(missingFiles.joined(separator: ", "))."
            )
        case .valid:
            break
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

    private func subagentDirectoryURL(for id: String) throws -> URL {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              trimmedID == id,
              !trimmedID.contains("/"),
              !trimmedID.contains("\\"),
              trimmedID != ".",
              trimmedID != ".."
        else {
            throw HarnessError.invalidSubagent("Invalid subagent id '\(id)'.")
        }

        let directoryURL = agentsDirectoryURL
            .appendingPathComponent(trimmedID, isDirectory: true)
            .standardizedFileURL
        let parentURL = directoryURL.deletingLastPathComponent().standardizedFileURL
        guard parentURL.path == agentsDirectoryURL.standardizedFileURL.path,
              directoryURL.lastPathComponent == trimmedID
        else {
            throw HarnessError.invalidSubagent("Invalid subagent id '\(id)'.")
        }

        return directoryURL
    }

    private func writeContext(_ context: HarnessContextResolution, to directoryURL: URL) throws {
        let document = SubagentMarkdownFields.render(
            documentTitle: "Context",
            fields: [
                ("Resolution", context.status.rawValue),
                ("Context", context.details)
            ]
        )
        try FileSystemUtilities.write(document, to: directoryURL.appendingPathComponent("CONTEXT.md", isDirectory: false))
    }

    private func writeInput(_ input: HarnessSubagentInput, to directoryURL: URL) throws {
        let document = SubagentMarkdownFields.render(
            documentTitle: "Input",
            fields: [
                ("NeedMoreContext", input.needsMoreContext ? "true" : "false"),
                ("ContextRequest", input.contextRequest),
                ("Input", input.task)
            ]
        )
        try FileSystemUtilities.write(document, to: directoryURL.appendingPathComponent("INPUT.md", isDirectory: false))
    }

    private func writeOutput(_ output: HarnessSubagentOutput, to directoryURL: URL) throws {
        let document = SubagentMarkdownFields.render(
            documentTitle: "Output",
            fields: [
                ("TaskSummary", output.taskSummary),
                ("Output", output.output)
            ]
        )
        try FileSystemUtilities.write(document, to: directoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false))
    }

    private func readContext(from directoryURL: URL) throws -> HarnessContextResolution {
        let url = directoryURL.appendingPathComponent("CONTEXT.md", isDirectory: false)
        let text = try FileSystemUtilities.readTextIfPresent(at: url) ?? ""
        let document = SectionedMarkdownDocument(text: text)
        let details = SubagentMarkdownFields.field(named: "Context", in: text)
            ?? subagentFieldBody(
                named: "Context",
                in: document,
                legacyChildTitles: ["Resolution"]
            )
        let statusText = SubagentMarkdownFields.field(named: "Resolution", in: text)
            ?? document.bodyIncludingSubsections(for: "Resolution")
            ?? ""
        let status = HarnessContextResolution.Status(rawValue: statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .empty
        return HarnessContextResolution(status: status, details: details)
    }

    private func readInput(from directoryURL: URL) throws -> HarnessSubagentInput {
        let url = directoryURL.appendingPathComponent("INPUT.md", isDirectory: false)
        let text = try FileSystemUtilities.readTextIfPresent(at: url) ?? ""
        let document = SectionedMarkdownDocument(text: text)
        let task = SubagentMarkdownFields.field(named: "Input", in: text)
            ?? subagentFieldBody(
                named: "Input",
                in: document,
                legacyChildTitles: ["Need More Context", "Context Request"]
            )
        let needsMoreContext = (
            SubagentMarkdownFields.field(named: "NeedMoreContext", in: text)
                ?? document.bodyIncludingSubsections(for: "Need More Context")
                ?? ""
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        let contextRequest = SubagentMarkdownFields.field(named: "ContextRequest", in: text)
            ?? document.bodyIncludingSubsections(for: "Context Request")
            ?? ""
        return HarnessSubagentInput(task: task, needsMoreContext: needsMoreContext, contextRequest: contextRequest)
    }

    private func readOutput(from directoryURL: URL) throws -> HarnessSubagentOutput {
        let url = directoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false)
        let text = try FileSystemUtilities.readTextIfPresent(at: url) ?? ""
        let document = SectionedMarkdownDocument(text: text)
        return HarnessSubagentOutput(
            taskSummary: SubagentMarkdownFields.field(named: "TaskSummary", in: text)
                ?? document.body(for: "Task Summary")
                ?? "",
            output: SubagentMarkdownFields.field(named: "Output", in: text)
                ?? document.bodyIncludingSubsections(for: "Output")
                ?? ""
        )
    }

    private func subagentFieldBody(
        named title: String,
        in document: SectionedMarkdownDocument,
        legacyChildTitles: [String]
    ) -> String {
        let hasLegacyChildField = legacyChildTitles.contains {
            document.containsSubsection(named: $0, under: title)
        }

        if hasLegacyChildField {
            return document.body(for: title) ?? ""
        }

        return document.bodyIncludingSubsections(for: title) ?? ""
    }

    private struct SubagentFileState {
        enum Validation {
            case absent
            case valid
            case invalid(missingFiles: [String])
        }

        private static let requiredFileNames = [
            "CONTEXT.md",
            "INPUT.md",
            "OUTPUT.md"
        ]

        var validation: Validation

        init(directoryURL: URL) {
            let existingFileNames = Set(Self.requiredFileNames.filter { fileName in
                FileSystemUtilities.isRegularFile(
                    directoryURL.appendingPathComponent(fileName, isDirectory: false)
                )
            })

            guard !existingFileNames.isEmpty else {
                self.validation = .absent
                return
            }

            let missingFileNames = Self.requiredFileNames.filter { !existingFileNames.contains($0) }
            self.validation = missingFileNames.isEmpty
                ? .valid
                : .invalid(missingFiles: missingFileNames)
        }
    }
}
