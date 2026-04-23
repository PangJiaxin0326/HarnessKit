import Foundation

public enum AIServiceBackend: Sendable {
    case api(any APIModelProviding)
    case appleIntelligence(any AppleIntelligenceProviding)
    case custom(any AIModelProviding)

    var kind: AIProviderKind {
        switch self {
        case .api:
            .api
        case .appleIntelligence:
            .appleIntelligence
        case .custom:
            .custom
        }
    }

    var provider: any AIModelProviding {
        switch self {
        case .api(let provider):
            provider
        case .appleIntelligence(let provider):
            provider
        case .custom(let provider):
            provider
        }
    }
}

public struct PassthroughIntentResolver: HarnessIntentResolving {
    public init() {}

    public func resolveIntent(for input: String) async throws -> HarnessIntent {
        HarnessIntent(
            goal: input,
            acceptanceCriteria: ["Produce a useful response for the request."],
            constraints: ["Use the registered tools, skills, and memory files that the harness exposes."]
        )
    }
}

public struct DefaultContextBuilder: HarnessContextBuilding {
    public init() {}

    public func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext {
        var fragments: [HarnessContext.Fragment] = [
            .init(
                kind: .userInput,
                title: "Intent",
                body: """
                Goal: \(intent.goal)

                Acceptance Criteria:
                \(formatList(intent.acceptanceCriteria, fallback: "- None supplied."))

                Constraints:
                \(formatList(intent.constraints, fallback: "- None supplied."))
                """
            )
        ]

        if let agentsFileText = environment.agentsFileText, !agentsFileText.isEmpty {
            fragments.append(.init(
                kind: .agentsFile,
                title: "AGENTS.md",
                body: agentsFileText,
                sourceURL: environment.workspace.agentsFileURL
            ))
        }

        if !environment.toolDescriptors.isEmpty {
            fragments.append(.init(
                kind: .tool,
                title: "Registered Tools",
                body: environment.toolDescriptors
                    .map { "- \($0.name): \($0.description)" }
                    .joined(separator: "\n")
            ))
        }

        fragments.append(contentsOf: environment.skills.map { skill in
            HarnessContext.Fragment(
                kind: .skillHeader,
                title: "Skill Header: \(skill.name)",
                body: """
                Description: \(skill.description)
                Tools: \(skill.tools.isEmpty ? "None" : skill.tools.joined(separator: ", "))
                """,
                sourceURL: skill.fileURL
            )
        })

        fragments.append(contentsOf: environment.memoryFiles.map { memoryFile in
            HarnessContext.Fragment(
                kind: .memory,
                title: "Memory: \(memoryFile.url.lastPathComponent)",
                body: memoryFile.contents,
                sourceURL: memoryFile.url
            )
        })

        fragments.append(contentsOf: environment.subagents.compactMap { subagent in
            guard !subagent.context.details.isEmpty || !subagent.output.output.isEmpty else {
                return nil
            }

            return HarnessContext.Fragment(
                kind: .subagent,
                title: "Subagent: \(subagent.id)",
                body: """
                Context Status: \(subagent.context.status.rawValue)
                Task Summary: \(subagent.output.taskSummary)
                Context:
                \(subagent.context.details)

                Output:
                \(subagent.output.output)
                """,
                sourceURL: subagent.directoryURL
            )
        })

        return HarnessContext(fragments: fragments)
    }

    private func formatList(_ items: [String], fallback: String) -> String {
        if items.isEmpty {
            return fallback
        }

        return items.map { "- \($0)" }.joined(separator: "\n")
    }
}

public struct AllowAllPermissionChecker: HarnessPermissionChecking {
    public init() {}

    public func authorize(
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision {
        _ = (plan, environment)
        return HarnessPermissionDecision(isAllowed: true)
    }
}

public struct DefaultHarnessWorkflow: HarnessWorkflowBuilding {
    public init() {}

    public func makePlan(
        input: String,
        intent: HarnessIntent,
        context: HarnessContext,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPlan {
        let toolLines = environment.toolDescriptors.isEmpty
            ? "- No registered tools."
            : environment.toolDescriptors.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let skillLines = environment.skills.isEmpty
            ? "- No exposed skills."
            : environment.skills.map { skill in
                let toolText = skill.tools.isEmpty ? "none" : skill.tools.joined(separator: ", ")
                return "- \(skill.name): \(skill.description) [tools: \(toolText)]"
            }.joined(separator: "\n")

        let memoryLines = environment.memoryFiles.isEmpty
            ? "- No memory files."
            : environment.memoryFiles.map { "- \($0.url.path)" }.joined(separator: "\n")

        let toolCallInstructions = environment.toolDescriptors.isEmpty ? "" : """

        Tool Calling Protocol
        - If a registered tool is needed, respond with only this block and no other text:
          <tool_call>
          {"name":"tool-name","input":"plain text or JSON string input"}
          </tool_call>
        - Request one tool at a time.
        - Do not wrap the tool call block in Markdown code fences.
        - After the harness returns a tool result, either request another tool with the same format or respond with only valid JSON in this shape:
          {"response":"plain-text answer for the user"}
        - The harness will attach the executed tool results to the final returned payload.
        - Do not add extra commentary around the JSON response.
        """

        let prompt = """
        You are operating inside an AI harness.

        Goal
        \(intent.goal)

        Acceptance Criteria
        \(formatList(intent.acceptanceCriteria, fallback: "- Produce a useful answer."))

        Constraints
        \(formatList(intent.constraints, fallback: "- Respect the current harness configuration."))

        Registered Tools
        \(toolLines)
        \(toolCallInstructions)

        Skill Headers
        \(skillLines)

        Memory Files
        \(memoryLines)

        Processed Context
        \(context.rendered.isEmpty ? "_No additional context._" : context.rendered)

        User Input
        \(input)
        """

        return HarnessPlan(
            input: input,
            intent: intent,
            context: context,
            tools: environment.toolDescriptors,
            skills: environment.skills,
            memoryFileURLs: environment.memoryFiles.map(\.url),
            prompt: prompt
        )
    }

    private func formatList(_ items: [String], fallback: String) -> String {
        if items.isEmpty {
            return fallback
        }

        return items.map { "- \($0)" }.joined(separator: "\n")
    }
}

public struct PassThroughVerifier: HarnessVerifying {
    public init() {}

    public func verify(
        result: String,
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessVerification {
        _ = (result, plan, environment)
        return HarnessVerification(outcome: .passed)
    }
}

public struct DefaultHarnessEvaluator: HarnessEvaluating {
    public init() {}

    public func evaluate(
        result: String,
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessEvaluation {
        _ = (result, plan, environment)
        return HarnessEvaluation()
    }
}

public struct DefaultHarnessGovernor: HarnessGoverning {
    public init() {}

    public func decide(
        verification: HarnessVerification,
        evaluation: HarnessEvaluation
    ) async -> HarnessGovernanceDecision {
        switch verification.outcome {
        case .passed where evaluation.requiresHumanReview:
            .wait(reason: evaluation.summary ?? "Human review requested.")
        case .passed:
            .finish
        case .needsMoreContext:
            .wait(reason: verification.note)
        case .failed:
            .fail(reason: verification.note ?? "Verification failed.")
        }
    }
}

public struct NoOpHarnessObserver: HarnessObserving {
    public init() {}

    public func record(_ event: HarnessEvent) async {
        _ = event
    }
}

public actor HarnessTranscriptObserver: HarnessObserving {
    private var events: [HarnessEvent] = []

    public init() {}

    public func record(_ event: HarnessEvent) async {
        events.append(event)
    }

    public func allEvents() -> [HarnessEvent] {
        events
    }
}

public actor AIService {
    public struct Configuration: Sendable {
        public var backend: AIServiceBackend
        public var workspace: HarnessWorkspace
        public var intentResolver: any HarnessIntentResolving
        public var contextBuilder: any HarnessContextBuilding
        public var permissionChecker: any HarnessPermissionChecking
        public var workflow: any HarnessWorkflowBuilding
        public var verifier: any HarnessVerifying
        public var evaluator: any HarnessEvaluating
        public var observer: any HarnessObserving
        public var governor: any HarnessGoverning
        public var cache: (any HarnessCaching)?
        public var memoryStore: (any HarnessMemoryStoring)?
        public var subagentManager: (any HarnessSubagentManaging)?

        public init(
            backend: AIServiceBackend,
            workspace: HarnessWorkspace = .current(),
            intentResolver: any HarnessIntentResolving = PassthroughIntentResolver(),
            contextBuilder: any HarnessContextBuilding = DefaultContextBuilder(),
            permissionChecker: any HarnessPermissionChecking = AllowAllPermissionChecker(),
            workflow: any HarnessWorkflowBuilding = DefaultHarnessWorkflow(),
            verifier: any HarnessVerifying = PassThroughVerifier(),
            evaluator: any HarnessEvaluating = DefaultHarnessEvaluator(),
            observer: any HarnessObserving = NoOpHarnessObserver(),
            governor: any HarnessGoverning = DefaultHarnessGovernor(),
            cache: (any HarnessCaching)? = nil,
            memoryStore: (any HarnessMemoryStoring)? = nil,
            subagentManager: (any HarnessSubagentManaging)? = nil
        ) {
            self.backend = backend
            self.workspace = workspace
            self.intentResolver = intentResolver
            self.contextBuilder = contextBuilder
            self.permissionChecker = permissionChecker
            self.workflow = workflow
            self.verifier = verifier
            self.evaluator = evaluator
            self.observer = observer
            self.governor = governor
            self.cache = cache
            self.memoryStore = memoryStore
            self.subagentManager = subagentManager
        }
    }

    private struct PreparedExecution {
        let plan: HarnessPlan
        let request: AIModelRequest
        let cacheRecord: HarnessCacheRecord
        let environment: HarnessEnvironmentSnapshot
    }

    private struct AutomaticToolCall: Sendable {
        let name: String
        let input: String
    }

    private enum StreamPassOutcome: Sendable {
        case final(String)
        case toolCall(AutomaticToolCall)
    }

    private struct StreamLoopResult: Sendable {
        let output: String
        let shouldEmitCompletedOutput: Bool
    }

    private struct StructuredToolResponse: Sendable, Decodable {
        let response: String
    }

    private static let automaticToolCallStartTag = "<tool_call>"
    private static let automaticToolCallEndTag = "</tool_call>"
    private static let maximumAutomaticToolRoundTrips = 8
    private static let maximumStructuredToolResponseRepairAttempts = 2

    private let configuration: Configuration
    private let toolRegistry: HarnessToolRegistry
    private let skillRegistry: HarnessSkillRegistry
    private let cache: any HarnessCaching
    private let memoryStore: any HarnessMemoryStoring
    private let subagentManager: any HarnessSubagentManaging
    private var statusValue: HarnessStatus = .idle

    public init(configuration: Configuration) throws {
        try FileSystemUtilities.prepareWorkspace(configuration.workspace)
        self.configuration = configuration
        self.toolRegistry = HarnessToolRegistry()
        self.skillRegistry = HarnessSkillRegistry(workspace: configuration.workspace)
        self.cache = try configuration.cache ?? FileSystemHarnessCache(rootDirectoryURL: configuration.workspace.cacheDirectoryURL)
        self.memoryStore = try configuration.memoryStore ?? FileSystemMemoryStore(rootDirectoryURL: configuration.workspace.memoryDirectoryURL)
        self.subagentManager = try configuration.subagentManager ?? FileSystemSubagentManager(agentsDirectoryURL: configuration.workspace.agentsDirectoryURL)
    }

    public var status: HarnessStatus {
        statusValue
    }

    public func acknowledgeWaitState() {
        statusValue = .idle
    }

    public func registerTool(_ tool: HarnessTool) async {
        await toolRegistry.register(tool)
        await configuration.observer.record(.init(kind: .toolRegistered, message: "Registered tool '\(tool.name)'."))
    }

    @discardableResult
    public func registerSkill(at url: URL) async throws -> HarnessSkillHeader {
        let header = try await skillRegistry.registerSkill(at: url)
        await configuration.observer.record(.init(kind: .skillRegistered, message: "Registered skill '\(header.name)'."))
        return header
    }

    public func refreshSkillsFromAgentsFile() async throws -> [HarnessSkillHeader] {
        try await skillRegistry.refreshFromAgentsFile()
    }

    public func skillHeaders() async throws -> [HarnessSkillHeader] {
        _ = try await skillRegistry.refreshFromAgentsFile()
        return await skillRegistry.headers()
    }

    public func skillDocument(named name: String) async throws -> HarnessSkillDocument? {
        _ = try await skillRegistry.refreshFromAgentsFile()
        return try await skillRegistry.skillDocument(named: name)
    }

    public func registerMemoryFile(at url: URL) async {
        await memoryStore.registerMemoryFile(at: url)
        await configuration.observer.record(.init(kind: .memoryRegistered, message: "Registered memory file '\(url.path)'."))
    }

    public func memoryFileURLs() async throws -> [URL] {
        try await memoryStore.memoryFileURLs()
    }

    public func cacheRecords() async throws -> [HarnessCacheRecord] {
        try await cache.records()
    }

    public func invokeTool(named name: String, input: String) async throws -> String {
        try await toolRegistry.invoke(named: name, input: input)
    }

    public func spawnSubagent(taskSummary: String, input: String, context: String = "") async throws -> HarnessSubagentRecord {
        let subagent = try await subagentManager.createSubagent(taskSummary: taskSummary, input: input, context: context)
        await configuration.observer.record(.init(kind: .subagentUpdated, message: "Spawned subagent '\(subagent.id)'."))
        return subagent
    }

    public func subagents() async throws -> [HarnessSubagentRecord] {
        try await subagentManager.listSubagents()
    }

    public func markSubagentNeedsMoreContext(id: String, request: String) async throws {
        try await subagentManager.markNeedsMoreContext(for: id, request: request)
        statusValue = .waiting
        await configuration.observer.record(.init(kind: .waiting, message: "Subagent '\(id)' requested more context."))
    }

    public func updateSubagentOutput(id: String, summary: String, output: String) async throws -> HarnessSubagentRecord {
        let record = try await subagentManager.updateOutput(for: id, summary: summary, output: output)
        await configuration.observer.record(.init(kind: .subagentUpdated, message: "Updated output for subagent '\(id)'."))
        return record
    }

    public func satisfyPendingSubagentRequests() async throws -> [HarnessSubagentRecord] {
        statusValue = .working
        let snapshot = try await environmentSnapshot()
        let currentSubagents = try await subagentManager.listSubagents()
        var resolved: [HarnessSubagentRecord] = []

        for subagent in currentSubagents where subagent.input.needsMoreContext {
            let prompt = subagent.input.contextRequest.isEmpty ? subagent.input.task : subagent.input.contextRequest
            let intent = HarnessIntent(
                goal: prompt,
                acceptanceCriteria: ["Provide the requested subagent context."],
                constraints: ["Use only the current harness environment."]
            )

            do {
                let context = try await configuration.contextBuilder.buildContext(
                    for: prompt,
                    intent: intent,
                    environment: snapshot
                )
                let resolvedRecord = try await subagentManager.satisfyContextRequest(
                    for: subagent.id,
                    context: context.rendered.isEmpty ? "No matching context was available." : context.rendered
                )
                resolved.append(resolvedRecord)
            } catch {
                let rejectedRecord = try await subagentManager.rejectContextRequest(
                    for: subagent.id,
                    reason: error.localizedDescription
                )
                resolved.append(rejectedRecord)
            }
        }

        statusValue = resolved.isEmpty ? .idle : .waiting
        return resolved
    }

    public func callAsFunction(_ input: String) async throws -> String {
        try await generate(input)
    }

    public func generate(_ input: String) async throws -> String {
        do {
            let execution = try await prepareExecution(for: input)
            let output = try await runGenerateLoop(for: execution)
            return try await finalize(output: output, execution: execution)
        } catch {
            await handleExecutionFailure(error)
            throw error
        }
    }

    public func stream(_ input: String) async throws -> AsyncThrowingStream<Generation, Error> {
        let execution: PreparedExecution
        do {
            execution = try await prepareExecution(for: input)
        } catch {
            await handleExecutionFailure(error)
            throw error
        }
        let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()

        let worker = Task {
            do {
                let result = try await runStreamLoop(for: execution, continuation: continuation)
                let finalizedOutput = try await finalize(output: result.output, execution: execution)
                if result.shouldEmitCompletedOutput {
                    continuation.yield(Generation(kind: .completed, text: finalizedOutput))
                }
                continuation.finish()
            } catch {
                await handleExecutionFailure(error)
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            worker.cancel()
        }

        return stream
    }

    private func handleExecutionFailure(_ error: Error) async {
        if error is CancellationError {
            statusValue = .idle
            return
        }

        if let harnessError = error as? HarnessError {
            switch harnessError {
            case .permissionDenied, .governanceBlocked:
                return
            case .missingTool, .invalidToolResponse, .invalidSkillFile, .invalidSubagent, .missingSubagent:
                break
            }
        }

        statusValue = .idle
        await configuration.observer.record(.init(kind: .failed, message: error.localizedDescription))
    }

    private func prepareExecution(for input: String) async throws -> PreparedExecution {
        statusValue = .working
        await configuration.observer.record(.init(kind: .started, message: "Started harness execution."))

        let skills = try await skillRegistry.refreshFromAgentsFile()
        let environment = try await environmentSnapshot(skills: skills)
        let intent = try await configuration.intentResolver.resolveIntent(for: input)
        let context = try await configuration.contextBuilder.buildContext(
            for: input,
            intent: intent,
            environment: environment
        )
        let plan = try await configuration.workflow.makePlan(
            input: input,
            intent: intent,
            context: context,
            environment: environment
        )
        let permissionDecision = try await configuration.permissionChecker.authorize(
            plan: plan,
            environment: environment
        )

        guard permissionDecision.isAllowed else {
            statusValue = .waiting
            let reason = permissionDecision.reason ?? "No reason provided."
            await configuration.observer.record(.init(kind: .waiting, message: reason))
            throw HarnessError.permissionDenied(reason)
        }

        let metadata = HarnessCacheMetadata(
            providerKind: configuration.backend.kind,
            intentGoal: intent.goal,
            toolNames: plan.tools.map(\.name),
            skillNames: plan.skills.map(\.name),
            memoryFiles: plan.memoryFileURLs.map(\.path)
        )

        let cacheRecord = try await cache.createRecord(
            rawInput: input,
            processedContext: context.rendered,
            metadata: metadata
        )
        await configuration.observer.record(.init(kind: .cached, message: "Saved harness cache '\(metadata.id.uuidString)'."))

        let request = AIModelRequest(
            prompt: plan.prompt,
            input: input,
            intent: intent,
            context: context,
            tools: plan.tools,
            skills: plan.skills,
            providerKind: configuration.backend.kind
        )

        return PreparedExecution(
            plan: plan,
            request: request,
            cacheRecord: cacheRecord,
            environment: environment
        )
    }

    private func finalize(output: String, execution: PreparedExecution) async throws -> String {
        try await cache.updateOutput(for: execution.cacheRecord, rawOutput: output)

        let verification = try await configuration.verifier.verify(
            result: output,
            plan: execution.plan,
            environment: execution.environment
        )
        let evaluation = try await configuration.evaluator.evaluate(
            result: output,
            plan: execution.plan,
            environment: execution.environment
        )
        let governanceDecision = await configuration.governor.decide(
            verification: verification,
            evaluation: evaluation
        )

        switch governanceDecision {
        case .finish:
            statusValue = .idle
            await configuration.observer.record(.init(kind: .completed, message: "Harness execution completed."))
            return output
        case .wait(let reason):
            statusValue = .waiting
            await configuration.observer.record(.init(kind: .waiting, message: reason ?? "Waiting for caller action."))
            return output
        case .fail(let reason):
            statusValue = .waiting
            await configuration.observer.record(.init(kind: .failed, message: reason ?? "Harness governance blocked completion."))
            throw HarnessError.governanceBlocked(reason ?? "No reason provided.")
        }
    }

    private func environmentSnapshot(skills: [HarnessSkillHeader]? = nil) async throws -> HarnessEnvironmentSnapshot {
        let skillHeaders: [HarnessSkillHeader]
        if let skills {
            skillHeaders = skills
        } else {
            skillHeaders = try await skillRegistry.refreshFromAgentsFile()
        }
        let toolDescriptors = await toolRegistry.descriptors()
        let memoryFiles = try await memoryStore.readMemoryFiles()
        let subagents = try await subagentManager.listSubagents()
        let agentsFileText = try FileSystemUtilities.readTextIfPresent(at: configuration.workspace.agentsFileURL)

        return HarnessEnvironmentSnapshot(
            workspace: configuration.workspace,
            providerKind: configuration.backend.kind,
            toolDescriptors: toolDescriptors,
            skills: skillHeaders,
            memoryFiles: memoryFiles,
            subagents: subagents,
            agentsFileText: agentsFileText
        )
    }

    private func runGenerateLoop(for execution: PreparedExecution) async throws -> String {
        try await runGenerateLoop(
            startingWith: execution.request,
            initialToolResults: []
        )
    }

    private func runGenerateLoop(
        startingWith initialRequest: AIModelRequest,
        initialToolResults: [HarnessToolInvocationResult]
    ) async throws -> String {
        var request = initialRequest
        var toolResults = initialToolResults
        var toolRoundTripCount = initialToolResults.count

        while true {
            try Task.checkCancellation()

            let output = try await configuration.backend.provider.generate(request)
            guard let toolCall = automaticToolCall(in: output) else {
                guard !toolResults.isEmpty else {
                    return output
                }

                return try await finalizeStructuredToolResponse(
                    initialOutput: output,
                    request: request,
                    toolResults: toolResults
                )
            }

            toolRoundTripCount += 1
            let canRequestMoreTools = toolRoundTripCount < Self.maximumAutomaticToolRoundTrips
            let toolResult = await invokeAutomaticTool(toolCall)
            toolResults.append(toolResult)
            request = requestByAppendingToolResult(
                toolResult,
                to: request,
                roundTrip: toolRoundTripCount,
                canRequestMoreTools: canRequestMoreTools
            )

            if !canRequestMoreTools {
                let output = try await configuration.backend.provider.generate(request)
                return try await finalizeStructuredToolResponse(
                    initialOutput: output,
                    request: request,
                    toolResults: toolResults
                )
            }
        }
    }

    private func runStreamLoop(
        for execution: PreparedExecution,
        continuation: AsyncThrowingStream<Generation, Error>.Continuation
    ) async throws -> StreamLoopResult {
        try Task.checkCancellation()

        let outcome = try await collectProviderStream(for: execution.request, continuation: continuation)
        switch outcome {
        case .final(let output):
            return StreamLoopResult(
                output: output,
                shouldEmitCompletedOutput: output.isEmpty
            )
        case .toolCall(let toolCall):
            let toolResult = await invokeAutomaticTool(toolCall)
            let output = try await runGenerateLoop(
                startingWith: requestByAppendingToolResult(
                    toolResult,
                    to: execution.request,
                    roundTrip: 1,
                    canRequestMoreTools: 1 < Self.maximumAutomaticToolRoundTrips
                ),
                initialToolResults: [toolResult]
            )
            return StreamLoopResult(output: output, shouldEmitCompletedOutput: true)
        }
    }

    private func collectProviderStream(
        for request: AIModelRequest,
        continuation: AsyncThrowingStream<Generation, Error>.Continuation
    ) async throws -> StreamPassOutcome {
        let shouldBufferForToolCalls = !request.tools.isEmpty
        var output = ""
        var bufferedGenerations: [Generation] = []
        var isBuffering = shouldBufferForToolCalls

        for try await generation in configuration.backend.provider.stream(request) {
            switch generation.kind {
            case .delta:
                output += generation.text
            case .completed:
                if output.isEmpty {
                    output = generation.text
                }
            case .metadata:
                break
            }

            if isBuffering {
                bufferedGenerations.append(generation)
                if !outputMayStillBecomeAutomaticToolCall(output) {
                    for bufferedGeneration in bufferedGenerations {
                        continuation.yield(bufferedGeneration)
                    }
                    bufferedGenerations.removeAll(keepingCapacity: true)
                    isBuffering = false
                }
            } else {
                continuation.yield(generation)
            }
        }

        if isBuffering, let toolCall = automaticToolCall(in: output) {
            return .toolCall(toolCall)
        }

        for bufferedGeneration in bufferedGenerations {
            continuation.yield(bufferedGeneration)
        }
        return .final(output)
    }

    private func invokeAutomaticTool(_ toolCall: AutomaticToolCall) async -> HarnessToolInvocationResult {
        do {
            let output = try await toolRegistry.invoke(named: toolCall.name, input: toolCall.input)
            return HarnessToolInvocationResult(
                name: toolCall.name,
                input: toolCall.input,
                output: output,
                status: .success
            )
        } catch {
            return HarnessToolInvocationResult(
                name: toolCall.name,
                input: toolCall.input,
                output: error.localizedDescription,
                status: .failure
            )
        }
    }

    private func requestByAppendingToolResult(
        _ toolResult: HarnessToolInvocationResult,
        to request: AIModelRequest,
        roundTrip: Int,
        canRequestMoreTools: Bool
    ) -> AIModelRequest {
        var updatedRequest = request
        let nextStepInstructions = canRequestMoreTools
            ? """
            - If another registered tool is needed, respond with only a new `<tool_call>` block.
            - Otherwise respond with only valid JSON matching `{"response":"plain-text answer for the user"}`.
            """
            : """
            - The harness will not run more tools in this turn.
            - Respond with only valid JSON matching `{"response":"plain-text answer for the user"}`.
            """

        updatedRequest.prompt += """

        Harness Tool Round Trip \(roundTrip)
        Tool Result JSON
        \(jsonString(for: toolResult))

        Next Step
        \(nextStepInstructions)
        """
        return updatedRequest
    }

    private func finalizeStructuredToolResponse(
        initialOutput: String,
        request initialRequest: AIModelRequest,
        toolResults: [HarnessToolInvocationResult]
    ) async throws -> String {
        var output = initialOutput
        var request = initialRequest
        var repairAttempt = 0

        while true {
            try Task.checkCancellation()

            if let structuredResponse = structuredToolResponse(in: output) {
                return jsonString(for: HarnessToolResponseEnvelope(
                    response: structuredResponse.response,
                    toolResults: toolResults
                ))
            }

            guard repairAttempt < Self.maximumStructuredToolResponseRepairAttempts else {
                throw HarnessError.invalidToolResponse(output)
            }

            repairAttempt += 1
            request = requestByAppendingStructuredToolResponseRepair(
                invalidOutput: output,
                to: request,
                attempt: repairAttempt
            )
            output = try await configuration.backend.provider.generate(request)
        }
    }

    private func structuredToolResponse(in output: String) -> StructuredToolResponse? {
        let normalizedOutput = strippedEnclosingCodeFence(from: output)
        guard let data = normalizedOutput.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(StructuredToolResponse.self, from: data)
    }

    private func requestByAppendingStructuredToolResponseRepair(
        invalidOutput: String,
        to request: AIModelRequest,
        attempt: Int
    ) -> AIModelRequest {
        var updatedRequest = request
        updatedRequest.prompt += """

        Structured Tool Response Repair \(attempt)
        The previous reply was invalid. Respond again with only valid JSON matching:
        {"response":"plain-text answer for the user"}
        Do not request another tool and do not add extra commentary outside the JSON.

        Previous Invalid Reply
        \(invalidOutput)
        """
        return updatedRequest
    }

    private func jsonString<Value: Encodable>(for value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard
            let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return string
    }

    private func automaticToolCall(in output: String) -> AutomaticToolCall? {
        let normalizedOutput = strippedEnclosingCodeFence(from: output)
        guard
            let startRange = normalizedOutput.range(of: Self.automaticToolCallStartTag),
            let endRange = normalizedOutput.range(of: Self.automaticToolCallEndTag),
            startRange.lowerBound < endRange.lowerBound
        else {
            return nil
        }

        let prefix = normalizedOutput[..<startRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = normalizedOutput[endRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty, suffix.isEmpty else {
            return nil
        }

        let payload = normalizedOutput[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let payloadData = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: payloadData),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let rawName = dictionary["name"] as? String ?? dictionary["tool"] as? String
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return nil
        }

        return AutomaticToolCall(
            name: name,
            input: stringValue(forToolPayload: dictionary["input"] ?? dictionary["arguments"])
        )
    }

    private func outputMayStillBecomeAutomaticToolCall(_ output: String) -> Bool {
        let candidate = output.drop(while: \.isWhitespace)
        guard !candidate.isEmpty else {
            return true
        }

        let marker = Self.automaticToolCallStartTag[...]
        return marker.hasPrefix(candidate) || candidate.hasPrefix(marker)
    }

    private func strippedEnclosingCodeFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }

        let lines = trimmed.components(separatedBy: .newlines)
        guard
            lines.count >= 2,
            lines.first?.hasPrefix("```") == true,
            lines.last == "```"
        else {
            return trimmed
        }

        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stringValue(forToolPayload value: Any?) -> String {
        switch value {
        case nil:
            return ""
        case let string as String:
            return string
        default:
            guard
                let value,
                JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                let string = String(data: data, encoding: .utf8)
            else {
                return String(describing: value as Any)
            }
            return string
        }
    }
}
