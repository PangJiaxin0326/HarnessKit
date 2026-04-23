import Foundation
import Testing
@testable import HarnessKit

@Test
func generateLoadsAgentsSkillsAndWritesCache() async throws {
    let workspace = try makeWorkspace(named: "generate")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let skillURL = workspace.skillsDirectoryURL.appendingPathComponent("summarize.md", isDirectory: false)
    try """
    ---
    name: summarize
    description: Summarizes large documents.
    tools:
      - grep
      - search
    ---

    # summarize

    The body should stay hidden until explicitly requested.
    """.write(to: skillURL, atomically: true, encoding: .utf8)

    try """
    # Repo Map
    The memory file is available to the harness.
    """.write(
        to: workspace.memoryDirectoryURL.appendingPathComponent("repo-map.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    try """
    # AGENTS
    - [summarize](Skills/summarize.md)
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let provider = ClosureAIModelProvider { request in
        request.prompt
    }

    let service = try AIService(configuration: .init(
        backend: .custom(provider),
        workspace: workspace
    ))
    await service.registerTool(HarnessTool(name: "search", description: "Search the codebase.") { input in
        "searched: \(input)"
    })

    let output = try await service.generate("Build a harness response.")
    #expect(output.contains("Registered Tools"))
    #expect(output.contains("search: Search the codebase."))
    #expect(output.contains("summarize: Summarizes large documents."))
    #expect(!output.contains("The body should stay hidden"))
    #expect(output.contains("The memory file is available to the harness."))

    let records = try await service.cacheRecords()
    #expect(records.count == 1)

    let rawInput = try String(contentsOf: records[0].rawInputURL, encoding: .utf8)
    let processedContext = try String(contentsOf: records[0].processedContextURL, encoding: .utf8)
    #expect(rawInput == "Build a harness response.")
    #expect(processedContext.contains("Skill Header: summarize"))
    #expect(processedContext.contains("repo-map.md"))
    #expect(
        FileManager.default.fileExists(
            atPath: records[0].directoryURL.appendingPathComponent("provider-prompt.md", isDirectory: false).path
        ) == false
    )

    #expect(await service.status == .idle)
}

@Test
func generateReturnsStructuredJSONAfterAutomaticToolRoundTrip() async throws {
    let workspace = try makeWorkspace(named: "generate-tool-loop")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let requestRecorder = RequestRecorder()
    let provider = ClosureAIModelProvider { request in
        let callCount = await requestRecorder.record(request)
        if callCount == 1 {
            return """
            <tool_call>
            {"name":"add-numbers","input":"3, 4, 5"}
            </tool_call>
            """
        }

        return #"{"response":"The sum is 12."}"#
    }

    let service = try AIService(configuration: .init(
        backend: .custom(provider),
        workspace: workspace
    ))
    await service.registerTool(HarnessTool(name: "add-numbers", description: "Adds comma-separated integers.") { input in
        let parts = input.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return String(parts.reduce(0, +))
    })

    let output = try await service.generate("What is 3 + 4 + 5?")
    let envelope = try decodeToolResponseEnvelope(output)
    #expect(envelope.response == "The sum is 12.")
    #expect(envelope.toolResults == [
        HarnessToolInvocationResult(
            name: "add-numbers",
            input: "3, 4, 5",
            output: "12",
            status: .success
        )
    ])
    #expect(await service.status == .idle)

    let requests = await requestRecorder.allRequests()
    #expect(requests.count == 2)
    #expect(requests[0].prompt.contains("Tool Calling Protocol"))
    #expect(requests[1].prompt.contains("Harness Tool Round Trip 1"))
    #expect(requests[1].prompt.contains(#""name":"add-numbers""#))
    #expect(requests[1].prompt.contains(#""output":"12""#))
    #expect(requests[1].prompt.contains(#""status":"success""#))

    let records = try await service.cacheRecords()
    #expect(records.count == 1)
    let rawOutput = try String(contentsOf: records[0].rawOutputURL, encoding: .utf8)
    #expect(rawOutput == output)
}

@Test
func generateRetriesWhenToolResponseJSONIsInvalid() async throws {
    let workspace = try makeWorkspace(named: "generate-tool-repair")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let requestRecorder = RequestRecorder()
    let provider = ClosureAIModelProvider { request in
        let callCount = await requestRecorder.record(request)
        switch callCount {
        case 1:
            return """
            <tool_call>
            {"name":"add-numbers","input":"1, 2, 3"}
            </tool_call>
            """
        case 2:
            return "The sum is 6."
        default:
            return #"{"response":"The sum is 6."}"#
        }
    }

    let service = try AIService(configuration: .init(
        backend: .custom(provider),
        workspace: workspace
    ))
    await service.registerTool(HarnessTool(name: "add-numbers", description: "Adds comma-separated integers.") { input in
        let parts = input.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return String(parts.reduce(0, +))
    })

    let output = try await service.generate("What is 1 + 2 + 3?")
    let envelope = try decodeToolResponseEnvelope(output)
    #expect(envelope.response == "The sum is 6.")
    #expect(envelope.toolResults.map(\.output) == ["6"])

    let requests = await requestRecorder.allRequests()
    #expect(requests.count == 3)
    #expect(requests[2].prompt.contains("Structured Tool Response Repair 1"))
    #expect(requests[2].prompt.contains("Previous Invalid Reply"))
    #expect(requests[2].prompt.contains("The sum is 6."))
}

@Test
func streamReturnsStructuredJSONAfterAutomaticToolRoundTrip() async throws {
    let workspace = try makeWorkspace(named: "stream-tool-loop")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let requestRecorder = RequestRecorder()
    let provider = ClosureAIModelProvider(
        generate: { request in
            let callCount = await requestRecorder.record(request)
            if callCount == 2 {
                return #"{"response":"The sum is 9."}"#
            }

            return "unused"
        },
        stream: { request in
            let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
            let worker = Task {
                let callCount = await requestRecorder.record(request)
                if callCount == 1 {
                    continuation.yield(Generation(kind: .delta, text: "<tool_call>"))
                    continuation.yield(Generation(kind: .delta, text: "{\"name\":\"add-numbers\",\"input\":\"2, 3, 4\"}"))
                    continuation.yield(Generation(kind: .delta, text: "</tool_call>"))
                } else {
                    continuation.yield(Generation(kind: .delta, text: "The sum "))
                    continuation.yield(Generation(kind: .delta, text: "is 9."))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                worker.cancel()
            }

            return stream
        }
    )

    let service = try AIService(configuration: .init(
        backend: .custom(provider),
        workspace: workspace
    ))
    await service.registerTool(HarnessTool(name: "add-numbers", description: "Adds comma-separated integers.") { input in
        let parts = input.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return String(parts.reduce(0, +))
    })

    let stream = try await service.stream("What is 2 + 3 + 4?")
    var collected: [Generation] = []
    for try await generation in stream {
        collected.append(generation)
    }

    let visibleText = collected
        .filter { $0.kind != .metadata }
        .map(\.text)
        .joined()
    let envelope = try decodeToolResponseEnvelope(visibleText)
    #expect(envelope.response == "The sum is 9.")
    #expect(envelope.toolResults == [
        HarnessToolInvocationResult(
            name: "add-numbers",
            input: "2, 3, 4",
            output: "9",
            status: .success
        )
    ])
    #expect(!visibleText.contains("<tool_call>"))
    #expect(await service.status == .idle)

    let requests = await requestRecorder.allRequests()
    #expect(requests.count == 2)
    #expect(requests[1].prompt.contains(#""output":"9""#))

    let records = try await service.cacheRecords()
    let rawOutput = try String(contentsOf: records[0].rawOutputURL, encoding: .utf8)
    #expect(rawOutput == visibleText)
}

@Test
func subagentLifecycleUsesOnDiskMarkdownFiles() async throws {
    let workspace = try makeWorkspace(named: "subagents")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    try """
    # Notes
    Context from memory.
    """.write(
        to: workspace.memoryDirectoryURL.appendingPathComponent("notes.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in request.input }),
        workspace: workspace
    ))

    let subagent = try await service.spawnSubagent(
        taskSummary: "Audit memory usage",
        input: "Inspect the memory files."
    )
    try await service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need repo memory context")
    let resolved = try await service.satisfyPendingSubagentRequests()
    #expect(resolved.count == 1)
    #expect(resolved[0].context.status == .provided)
    #expect(resolved[0].input.needsMoreContext == false)
    #expect(resolved[0].context.details.contains("Context from memory."))

    let updated = try await service.updateSubagentOutput(
        id: subagent.id,
        summary: "Audit memory usage",
        output: "Memory inspection complete."
    )
    #expect(updated.output.output == "Memory inspection complete.")

    let contextContents = try String(
        contentsOf: subagent.directoryURL.appendingPathComponent("CONTEXT.md", isDirectory: false),
        encoding: .utf8
    )
    let inputContents = try String(
        contentsOf: subagent.directoryURL.appendingPathComponent("INPUT.md", isDirectory: false),
        encoding: .utf8
    )
    let outputContents = try String(
        contentsOf: subagent.directoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false),
        encoding: .utf8
    )
    #expect(contextContents.contains("# Context"))
    #expect(contextContents.contains("## Resolution\nprovided"))
    #expect(inputContents.contains("## Need More Context\nfalse"))
    #expect(outputContents.contains("## Output\nMemory inspection complete."))
}

@Test
func streamCachesChunkedOutput() async throws {
    let workspace = try makeWorkspace(named: "stream")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let provider = ClosureAIModelProvider(
        generate: { _ in "unused" },
        stream: { request in
            let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
            let worker = Task {
                continuation.yield(Generation(kind: .metadata, text: request.input))
                continuation.yield(Generation(kind: .delta, text: "Hello"))
                continuation.yield(Generation(kind: .delta, text: ", world"))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                worker.cancel()
            }

            return stream
        }
    )

    let service = try AIService(configuration: .init(
        backend: .custom(provider),
        workspace: workspace
    ))

    let stream = try await service.stream("Say hello")
    var collected: [Generation] = []
    for try await generation in stream {
        collected.append(generation)
    }

    #expect(collected.map(\.text).contains("Hello"))
    #expect(collected.map(\.text).contains(", world"))

    let records = try await service.cacheRecords()
    let rawOutput = try String(contentsOf: records[0].rawOutputURL, encoding: .utf8)
    #expect(rawOutput == "Hello, world")
}

@Test
func generateResetsStatusAndRecordsFailureWhenPreparationFails() async throws {
    let workspace = try makeWorkspace(named: "prepare-failure")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let observer = HarnessTranscriptObserver()
    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace,
        contextBuilder: FailingContextBuilder(),
        observer: observer
    ))

    var didThrowExpectedError = false
    do {
        _ = try await service.generate("Build a harness response.")
    } catch is IntentionalFailure {
        didThrowExpectedError = true
    }

    #expect(didThrowExpectedError)
    #expect(await service.status == .idle)

    let failedEvents = await observer.allEvents().filter { $0.kind == .failed }
    #expect(failedEvents.count == 1)
}

@Test
func generateKeepsWaitingStatusWhenGovernanceBlocksCompletion() async throws {
    let workspace = try makeWorkspace(named: "governance-failure")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let observer = HarnessTranscriptObserver()
    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "completed" }),
        workspace: workspace,
        observer: observer,
        governor: BlockingGovernor()
    ))

    var didThrowGovernanceError = false
    do {
        _ = try await service.generate("Build a harness response.")
    } catch let error as HarnessError {
        if case .governanceBlocked("Human review required.") = error {
            didThrowGovernanceError = true
        }
    }

    #expect(didThrowGovernanceError)
    #expect(await service.status == .waiting)

    let failedEvents = await observer.allEvents().filter { $0.kind == .failed }
    #expect(failedEvents.count == 1)
}

@Test
func skillHeadersRefreshDropsSkillsRemovedFromAgentsFile() async throws {
    let workspace = try makeWorkspace(named: "agents-refresh")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let skillURL = workspace.skillsDirectoryURL.appendingPathComponent("summarize.md", isDirectory: false)
    try """
    ---
    name: summarize
    description: Summarizes large documents.
    ---

    # summarize
    """.write(to: skillURL, atomically: true, encoding: .utf8)

    try """
    # AGENTS
    - [summarize](Skills/summarize.md)
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))

    let initialHeaders = try await service.skillHeaders()
    #expect(initialHeaders.map(\.name) == ["summarize"])

    try """
    # AGENTS
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let refreshedHeaders = try await service.skillHeaders()
    #expect(refreshedHeaders.isEmpty)
}

private func makeWorkspace(named name: String) throws -> HarnessWorkspace {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HarnessKitTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    let workspace = HarnessWorkspace(rootURL: rootURL)
    try FileManager.default.createDirectory(at: workspace.skillsDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace.memoryDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace.cacheDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace.agentsDirectoryURL, withIntermediateDirectories: true)
    return workspace
}

private func decodeToolResponseEnvelope(_ output: String) throws -> HarnessToolResponseEnvelope {
    try JSONDecoder().decode(HarnessToolResponseEnvelope.self, from: Data(output.utf8))
}

private struct FailingContextBuilder: HarnessContextBuilding {
    func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext {
        _ = (input, intent, environment)
        throw IntentionalFailure()
    }
}

private struct BlockingGovernor: HarnessGoverning {
    func decide(
        verification: HarnessVerification,
        evaluation: HarnessEvaluation
    ) async -> HarnessGovernanceDecision {
        _ = (verification, evaluation)
        return .fail(reason: "Human review required.")
    }
}

private actor RequestRecorder {
    private var requests: [AIModelRequest] = []

    func record(_ request: AIModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }

    func allRequests() -> [AIModelRequest] {
        requests
    }
}

private struct IntentionalFailure: Error {}
