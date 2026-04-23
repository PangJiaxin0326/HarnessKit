import Foundation

public enum HarnessError: Error, Sendable {
    case permissionDenied(String)
    case governanceBlocked(String)
    case missingTool(String)
    case invalidToolResponse(String)
    case invalidSkillFile(URL)
    case invalidSubagent(String)
    case missingSubagent(String)
}

extension HarnessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let message):
            "Harness permission denied: \(message)"
        case .governanceBlocked(let message):
            "Harness governance blocked completion: \(message)"
        case .missingTool(let name):
            "No tool named '\(name)' is registered."
        case .invalidToolResponse(let output):
            "The model returned an invalid structured tool response: \(output)"
        case .invalidSkillFile(let url):
            "The skill file at \(url.path) could not be parsed."
        case .invalidSubagent(let message):
            "Invalid subagent data: \(message)"
        case .missingSubagent(let identifier):
            "No subagent with id '\(identifier)' exists."
        }
    }
}

public enum HarnessStatus: String, Sendable, Codable {
    case idle
    case working
    case waiting
}

public enum AIProviderKind: String, Sendable, Codable {
    case api
    case appleIntelligence
    case custom
}

public struct Generation: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case metadata
        case delta
        case completed
    }

    public var kind: Kind
    public var text: String
    public var createdAt: Date

    public init(kind: Kind, text: String, createdAt: Date = Date()) {
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}

public struct HarnessToolDescriptor: Sendable, Equatable, Codable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct HarnessToolInvocationResult: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case success
        case failure
    }

    public var name: String
    public var input: String
    public var output: String
    public var status: Status

    public init(
        name: String,
        input: String,
        output: String,
        status: Status
    ) {
        self.name = name
        self.input = input
        self.output = output
        self.status = status
    }
}

public struct HarnessToolResponseEnvelope: Sendable, Equatable, Codable {
    public var response: String
    public var toolResults: [HarnessToolInvocationResult]

    public init(response: String, toolResults: [HarnessToolInvocationResult]) {
        self.response = response
        self.toolResults = toolResults
    }
}

public struct HarnessTool: Sendable {
    public typealias Handler = @Sendable (String) async throws -> String

    public let descriptor: HarnessToolDescriptor
    let handler: Handler

    public init(name: String, description: String, handler: @escaping Handler) {
        self.descriptor = HarnessToolDescriptor(name: name, description: description)
        self.handler = handler
    }

    public var name: String { descriptor.name }
    public var description: String { descriptor.description }

    func invoke(_ input: String) async throws -> String {
        try await handler(input)
    }
}

public struct HarnessSkillHeader: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var tools: [String]
    public var fileURL: URL

    public init(name: String, description: String, tools: [String] = [], fileURL: URL) {
        self.name = name
        self.description = description
        self.tools = tools
        self.fileURL = fileURL
    }
}

public struct HarnessSkillDocument: Sendable, Equatable, Codable {
    public var header: HarnessSkillHeader
    public var body: String

    public init(header: HarnessSkillHeader, body: String) {
        self.header = header
        self.body = body
    }
}

public struct HarnessMemoryFile: Sendable, Equatable, Codable {
    public var url: URL
    public var contents: String

    public init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }
}

public struct HarnessIntent: Sendable, Equatable, Codable {
    public var goal: String
    public var acceptanceCriteria: [String]
    public var constraints: [String]

    public init(
        goal: String,
        acceptanceCriteria: [String] = [],
        constraints: [String] = []
    ) {
        self.goal = goal
        self.acceptanceCriteria = acceptanceCriteria
        self.constraints = constraints
    }
}

public struct HarnessContext: Sendable, Equatable, Codable {
    public struct Fragment: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable {
            case userInput
            case agentsFile
            case skillHeader
            case memory
            case tool
            case subagent
            case cache
            case custom
        }

        public var kind: Kind
        public var title: String
        public var body: String
        public var sourceURL: URL?

        public init(kind: Kind, title: String, body: String, sourceURL: URL? = nil) {
            self.kind = kind
            self.title = title
            self.body = body
            self.sourceURL = sourceURL
        }
    }

    public var fragments: [Fragment]

    public init(fragments: [Fragment] = []) {
        self.fragments = fragments
    }

    public var rendered: String {
        fragments.map { fragment in
            var lines = ["## \(fragment.title)"]
            if let sourceURL = fragment.sourceURL {
                lines.append("Source: \(sourceURL.path)")
            }
            lines.append(fragment.body)
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct HarnessPlan: Sendable, Equatable, Codable {
    public var input: String
    public var intent: HarnessIntent
    public var context: HarnessContext
    public var tools: [HarnessToolDescriptor]
    public var skills: [HarnessSkillHeader]
    public var memoryFileURLs: [URL]
    public var prompt: String

    public init(
        input: String,
        intent: HarnessIntent,
        context: HarnessContext,
        tools: [HarnessToolDescriptor],
        skills: [HarnessSkillHeader],
        memoryFileURLs: [URL],
        prompt: String
    ) {
        self.input = input
        self.intent = intent
        self.context = context
        self.tools = tools
        self.skills = skills
        self.memoryFileURLs = memoryFileURLs
        self.prompt = prompt
    }
}

public struct AIModelRequest: Sendable, Equatable, Codable {
    public var prompt: String
    public var input: String
    public var intent: HarnessIntent
    public var context: HarnessContext
    public var tools: [HarnessToolDescriptor]
    public var skills: [HarnessSkillHeader]
    public var providerKind: AIProviderKind

    public init(
        prompt: String,
        input: String,
        intent: HarnessIntent,
        context: HarnessContext,
        tools: [HarnessToolDescriptor],
        skills: [HarnessSkillHeader],
        providerKind: AIProviderKind
    ) {
        self.prompt = prompt
        self.input = input
        self.intent = intent
        self.context = context
        self.tools = tools
        self.skills = skills
        self.providerKind = providerKind
    }
}

public struct HarnessPermissionDecision: Sendable, Equatable, Codable {
    public var isAllowed: Bool
    public var reason: String?

    public init(isAllowed: Bool, reason: String? = nil) {
        self.isAllowed = isAllowed
        self.reason = reason
    }
}

public struct HarnessVerification: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable {
        case passed
        case needsMoreContext
        case failed
    }

    public var outcome: Outcome
    public var note: String?

    public init(outcome: Outcome, note: String? = nil) {
        self.outcome = outcome
        self.note = note
    }
}

public struct HarnessEvaluation: Sendable, Equatable, Codable {
    public var requiresHumanReview: Bool
    public var summary: String?

    public init(requiresHumanReview: Bool = false, summary: String? = nil) {
        self.requiresHumanReview = requiresHumanReview
        self.summary = summary
    }
}

public enum HarnessGovernanceDecision: Sendable, Equatable {
    case finish
    case wait(reason: String?)
    case fail(reason: String?)
}

public enum HarnessEventKind: String, Sendable, Codable {
    case started
    case cached
    case completed
    case waiting
    case failed
    case toolRegistered
    case skillRegistered
    case memoryRegistered
    case subagentUpdated
}

public struct HarnessEvent: Sendable, Equatable, Codable {
    public var kind: HarnessEventKind
    public var message: String
    public var createdAt: Date

    public init(kind: HarnessEventKind, message: String, createdAt: Date = Date()) {
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

public struct HarnessWorkspace: Sendable, Equatable, Codable {
    public var rootURL: URL
    public var skillsDirectoryURL: URL
    public var memoryDirectoryURL: URL
    public var cacheDirectoryURL: URL
    public var agentsDirectoryURL: URL
    public var agentsFileURL: URL

    public init(
        rootURL: URL,
        skillsDirectoryName: String = "Skills",
        memoryDirectoryName: String = "Memory",
        cacheDirectoryName: String = ".harness-cache",
        agentsDirectoryName: String = "agents",
        agentsFileName: String = "AGENTS.md"
    ) {
        self.rootURL = rootURL
        self.skillsDirectoryURL = rootURL.appendingPathComponent(skillsDirectoryName, isDirectory: true)
        self.memoryDirectoryURL = rootURL.appendingPathComponent(memoryDirectoryName, isDirectory: true)
        self.cacheDirectoryURL = rootURL.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        self.agentsDirectoryURL = rootURL.appendingPathComponent(agentsDirectoryName, isDirectory: true)
        self.agentsFileURL = rootURL.appendingPathComponent(agentsFileName, isDirectory: false)
    }

    public static func current() -> HarnessWorkspace {
        HarnessWorkspace(rootURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }
}

public struct HarnessContextResolution: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case empty
        case provided
        case rejected
    }

    public var status: Status
    public var details: String

    public init(status: Status, details: String = "") {
        self.status = status
        self.details = details
    }
}

public struct HarnessSubagentInput: Sendable, Equatable, Codable {
    public var task: String
    public var needsMoreContext: Bool
    public var contextRequest: String

    public init(task: String, needsMoreContext: Bool = false, contextRequest: String = "") {
        self.task = task
        self.needsMoreContext = needsMoreContext
        self.contextRequest = contextRequest
    }
}

public struct HarnessSubagentOutput: Sendable, Equatable, Codable {
    public var taskSummary: String
    public var output: String

    public init(taskSummary: String, output: String = "") {
        self.taskSummary = taskSummary
        self.output = output
    }
}

public struct HarnessSubagentRecord: Sendable, Equatable, Codable {
    public var id: String
    public var directoryURL: URL
    public var context: HarnessContextResolution
    public var input: HarnessSubagentInput
    public var output: HarnessSubagentOutput

    public init(
        id: String,
        directoryURL: URL,
        context: HarnessContextResolution,
        input: HarnessSubagentInput,
        output: HarnessSubagentOutput
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.context = context
        self.input = input
        self.output = output
    }
}

public struct HarnessCacheMetadata: Sendable, Equatable, Codable {
    public var id: UUID
    public var createdAt: Date
    public var providerKind: AIProviderKind
    public var intentGoal: String
    public var toolNames: [String]
    public var skillNames: [String]
    public var memoryFiles: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        providerKind: AIProviderKind,
        intentGoal: String,
        toolNames: [String],
        skillNames: [String],
        memoryFiles: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.providerKind = providerKind
        self.intentGoal = intentGoal
        self.toolNames = toolNames
        self.skillNames = skillNames
        self.memoryFiles = memoryFiles
    }
}

public struct HarnessCacheRecord: Sendable, Equatable, Codable {
    public var metadata: HarnessCacheMetadata
    public var directoryURL: URL
    public var rawInputURL: URL
    public var processedContextURL: URL
    public var rawOutputURL: URL
    public var metadataURL: URL

    public init(
        metadata: HarnessCacheMetadata,
        directoryURL: URL,
        rawInputURL: URL,
        processedContextURL: URL,
        rawOutputURL: URL,
        metadataURL: URL
    ) {
        self.metadata = metadata
        self.directoryURL = directoryURL
        self.rawInputURL = rawInputURL
        self.processedContextURL = processedContextURL
        self.rawOutputURL = rawOutputURL
        self.metadataURL = metadataURL
    }
}

public struct HarnessEnvironmentSnapshot: Sendable, Equatable, Codable {
    public var workspace: HarnessWorkspace
    public var providerKind: AIProviderKind
    public var toolDescriptors: [HarnessToolDescriptor]
    public var skills: [HarnessSkillHeader]
    public var memoryFiles: [HarnessMemoryFile]
    public var subagents: [HarnessSubagentRecord]
    public var agentsFileText: String?

    public init(
        workspace: HarnessWorkspace,
        providerKind: AIProviderKind,
        toolDescriptors: [HarnessToolDescriptor],
        skills: [HarnessSkillHeader],
        memoryFiles: [HarnessMemoryFile],
        subagents: [HarnessSubagentRecord],
        agentsFileText: String?
    ) {
        self.workspace = workspace
        self.providerKind = providerKind
        self.toolDescriptors = toolDescriptors
        self.skills = skills
        self.memoryFiles = memoryFiles
        self.subagents = subagents
        self.agentsFileText = agentsFileText
    }
}

public protocol AIModelProviding: Sendable {
    func generate(_ request: AIModelRequest) async throws -> String
    func stream(_ request: AIModelRequest) -> AsyncThrowingStream<Generation, Error>
}

extension AIModelProviding {
    public func stream(_ request: AIModelRequest) -> AsyncThrowingStream<Generation, Error> {
        let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
        let worker = Task {
            do {
                let output = try await generate(request)
                continuation.yield(Generation(kind: .completed, text: output))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            worker.cancel()
        }

        return stream
    }
}

public protocol APIModelProviding: AIModelProviding {}
public protocol AppleIntelligenceProviding: AIModelProviding {}

public struct ClosureAIModelProvider: AIModelProviding {
    public typealias GenerateHandler = @Sendable (AIModelRequest) async throws -> String
    public typealias StreamHandler = @Sendable (AIModelRequest) -> AsyncThrowingStream<Generation, Error>

    private let generateHandler: GenerateHandler
    private let streamHandler: StreamHandler?

    public init(
        generate: @escaping GenerateHandler,
        stream: StreamHandler? = nil
    ) {
        self.generateHandler = generate
        self.streamHandler = stream
    }

    public func generate(_ request: AIModelRequest) async throws -> String {
        try await generateHandler(request)
    }

    public func stream(_ request: AIModelRequest) -> AsyncThrowingStream<Generation, Error> {
        if let streamHandler {
            return streamHandler(request)
        }

        let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
        let worker = Task {
            do {
                let output = try await generateHandler(request)
                continuation.yield(Generation(kind: .completed, text: output))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            worker.cancel()
        }

        return stream
    }
}

public struct ClosureAPIModelProvider: APIModelProviding {
    private let base: ClosureAIModelProvider

    public init(
        generate: @escaping ClosureAIModelProvider.GenerateHandler,
        stream: ClosureAIModelProvider.StreamHandler? = nil
    ) {
        self.base = ClosureAIModelProvider(generate: generate, stream: stream)
    }

    public func generate(_ request: AIModelRequest) async throws -> String {
        try await base.generate(request)
    }

    public func stream(_ request: AIModelRequest) -> AsyncThrowingStream<Generation, Error> {
        base.stream(request)
    }
}

public struct ClosureAppleIntelligenceProvider: AppleIntelligenceProviding {
    private let base: ClosureAIModelProvider

    public init(
        generate: @escaping ClosureAIModelProvider.GenerateHandler,
        stream: ClosureAIModelProvider.StreamHandler? = nil
    ) {
        self.base = ClosureAIModelProvider(generate: generate, stream: stream)
    }

    public func generate(_ request: AIModelRequest) async throws -> String {
        try await base.generate(request)
    }

    public func stream(_ request: AIModelRequest) -> AsyncThrowingStream<Generation, Error> {
        base.stream(request)
    }
}

public protocol HarnessIntentResolving: Sendable {
    func resolveIntent(for input: String) async throws -> HarnessIntent
}

public protocol HarnessContextBuilding: Sendable {
    func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext
}

public protocol HarnessPermissionChecking: Sendable {
    func authorize(
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision
}

public protocol HarnessWorkflowBuilding: Sendable {
    func makePlan(
        input: String,
        intent: HarnessIntent,
        context: HarnessContext,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPlan
}

public protocol HarnessVerifying: Sendable {
    func verify(
        result: String,
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessVerification
}

public protocol HarnessEvaluating: Sendable {
    func evaluate(
        result: String,
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessEvaluation
}

public protocol HarnessObserving: Sendable {
    func record(_ event: HarnessEvent) async
}

public protocol HarnessGoverning: Sendable {
    func decide(
        verification: HarnessVerification,
        evaluation: HarnessEvaluation
    ) async -> HarnessGovernanceDecision
}

public protocol HarnessCaching: Sendable {
    func createRecord(
        rawInput: String,
        processedContext: String,
        metadata: HarnessCacheMetadata
    ) async throws -> HarnessCacheRecord

    func updateOutput(
        for record: HarnessCacheRecord,
        rawOutput: String
    ) async throws

    func records() async throws -> [HarnessCacheRecord]
}

public protocol HarnessMemoryStoring: Sendable {
    func registerMemoryFile(at url: URL) async
    func memoryFileURLs() async throws -> [URL]
    func readMemoryFiles() async throws -> [HarnessMemoryFile]
}

public protocol HarnessSubagentManaging: Sendable {
    func createSubagent(
        taskSummary: String,
        input: String,
        context: String
    ) async throws -> HarnessSubagentRecord

    func listSubagents() async throws -> [HarnessSubagentRecord]
    func subagent(id: String) async throws -> HarnessSubagentRecord?
    func markNeedsMoreContext(for id: String, request: String) async throws
    func satisfyContextRequest(for id: String, context: String) async throws -> HarnessSubagentRecord
    func rejectContextRequest(for id: String, reason: String) async throws -> HarnessSubagentRecord
    func updateOutput(for id: String, summary: String, output: String) async throws -> HarnessSubagentRecord
}
