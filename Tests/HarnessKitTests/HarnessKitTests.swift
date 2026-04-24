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
    #expect(contextContents.contains("HarnessKit:Resolution"))
    #expect(contextContents.contains("provided"))
    #expect(inputContents.contains("HarnessKit:NeedMoreContext"))
    #expect(inputContents.contains("false"))
    #expect(outputContents.contains("HarnessKit:Output"))
    #expect(outputContents.contains("Memory inspection complete."))
}

@Test
func subagentContextRoundTripPreservesNestedMarkdownAndClearsWaitingStatus() async throws {
    let workspace = try makeWorkspace(named: "subagent-context-roundtrip")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    try """
    # Repo Notes

    Context from memory.

    ## Nested Details

    Nested context should survive persistence.
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
        taskSummary: "Audit nested context",
        input: "Inspect nested markdown context."
    )
    try await service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need repo memory context")
    let resolved = try await service.satisfyPendingSubagentRequests()

    #expect(resolved.count == 1)
    #expect(await service.status == .idle)

    let reloaded = try #require(try await service.subagents().first)
    #expect(reloaded.context.status == .provided)
    #expect(reloaded.context.details.contains("Context from memory."))
    #expect(reloaded.context.details.contains("## Nested Details"))
    #expect(reloaded.context.details.contains("Nested context should survive persistence."))
}

@Test
func subagentFieldsRoundTripHarnessMarkerText() async throws {
    let workspace = try makeWorkspace(named: "subagent-marker-roundtrip")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in request.input }),
        workspace: workspace
    ))
    let context = "Context keeps <!-- /HarnessKit:Context --> as literal text."
    let input = "Input keeps <!-- /HarnessKit:Input --> as literal text."
    let summary = "Summary keeps <!-- /HarnessKit:TaskSummary --> as literal text."
    let output = "Output keeps <!-- /HarnessKit:Output --> as literal text."

    let subagent = try await service.spawnSubagent(
        taskSummary: "Initial summary",
        input: input,
        context: context
    )
    _ = try await service.updateSubagentOutput(
        id: subagent.id,
        summary: summary,
        output: output
    )

    let reloaded = try #require(try await service.subagents().first)
    #expect(reloaded.context.details == context)
    #expect(reloaded.input.task == input)
    #expect(reloaded.output.taskSummary == summary)
    #expect(reloaded.output.output == output)
}

@Test
func malformedSubagentDirectoryThrowsInvalidSubagent() async throws {
    let workspace = try makeWorkspace(named: "invalid-subagent")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let brokenDirectoryURL = workspace.agentsDirectoryURL.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: brokenDirectoryURL, withIntermediateDirectories: true)
    try """
    # Input

    <!-- HarnessKit:Input -->
    Investigate missing files.
    <!-- /HarnessKit:Input -->
    """.write(
        to: brokenDirectoryURL.appendingPathComponent("INPUT.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))

    do {
        _ = try await service.subagents()
        Issue.record("Expected invalidSubagent to be thrown.")
    } catch let error as HarnessError {
        guard case .invalidSubagent(let message) = error else {
            Issue.record("Expected invalidSubagent, got \(error).")
            return
        }
        #expect(message.contains("broken"))
        #expect(message.contains("CONTEXT.md"))
        #expect(message.contains("OUTPUT.md"))
    }
}

@Test
func subagentIDTraversalIsRejected() async throws {
    let workspace = try makeWorkspace(named: "subagent-id-traversal")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let outsideDirectoryURL = workspace.rootURL.appendingPathComponent("outside-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDirectoryURL, withIntermediateDirectories: true)
    try writeSubagentFiles(
        to: outsideDirectoryURL,
        contextStatus: "provided",
        context: "Outside context.",
        input: "Outside input.",
        taskSummary: "Outside summary.",
        output: "Original outside output."
    )

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))

    do {
        _ = try await service.updateSubagentOutput(
            id: "../outside-agent",
            summary: "Overwritten",
            output: "This should not be written."
        )
        Issue.record("Expected invalidSubagent to be thrown.")
    } catch let error as HarnessError {
        guard case .invalidSubagent(let message) = error else {
            Issue.record("Expected invalidSubagent, got \(error).")
            return
        }
        #expect(message.contains("../outside-agent"))
    }

    let outputContents = try String(
        contentsOf: outsideDirectoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false),
        encoding: .utf8
    )
    #expect(outputContents.contains("Original outside output."))
    #expect(!outputContents.contains("This should not be written."))
}

@Test
func satisfyPendingSubagentRequestsRestoresStatusAfterInvalidSubagent() async throws {
    let workspace = try makeWorkspace(named: "invalid-subagent-status")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let brokenDirectoryURL = workspace.agentsDirectoryURL.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: brokenDirectoryURL, withIntermediateDirectories: true)
    try """
    # Input

    <!-- HarnessKit:Input -->
    Investigate missing files.
    <!-- /HarnessKit:Input -->
    """.write(
        to: brokenDirectoryURL.appendingPathComponent("INPUT.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))

    do {
        _ = try await service.satisfyPendingSubagentRequests()
        Issue.record("Expected invalidSubagent to be thrown.")
    } catch is HarnessError {
        #expect(await service.status == HarnessStatus.idle)
    }
}

@Test
func satisfyPendingSubagentRequestsPropagatesCancellationWithoutRejectingRequest() async throws {
    let workspace = try makeWorkspace(named: "subagent-cancellation")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace,
        contextBuilder: CancellingContextBuilder()
    ))

    let subagent = try await service.spawnSubagent(
        taskSummary: "Needs cancellable context",
        input: "Wait for cancellable context."
    )
    try await service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need context")

    do {
        _ = try await service.satisfyPendingSubagentRequests()
        Issue.record("Expected CancellationError to be thrown.")
    } catch is CancellationError {
        #expect(await service.status == HarnessStatus.waiting)
    }

    let reloaded = try #require(try await service.subagents().first)
    #expect(reloaded.input.needsMoreContext)
    #expect(reloaded.context.status == .empty)
}

@Test
func cancelledSubagentSatisfactionReconcilesAlreadyResolvedWaits() async throws {
    let workspace = try makeWorkspace(named: "subagent-partial-cancellation")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace,
        contextBuilder: SucceedsThenCancelsContextBuilder(sequence: ContextBuildSequence())
    ))

    let first = try await service.spawnSubagent(taskSummary: "First", input: "First needs context.")
    let second = try await service.spawnSubagent(taskSummary: "Second", input: "Second needs context.")
    try await service.markSubagentNeedsMoreContext(id: first.id, request: "First request")
    try await service.markSubagentNeedsMoreContext(id: second.id, request: "Second request")

    do {
        _ = try await service.satisfyPendingSubagentRequests()
        Issue.record("Expected CancellationError to be thrown.")
    } catch is CancellationError {
        #expect(await service.status == HarnessStatus.waiting)
    }

    let subagents = try await service.subagents()
    #expect(subagents.filter(\.input.needsMoreContext).count == 1)

    await service.acknowledgeWaitState()
    #expect(await service.status == .idle)
}

@Test
func skillFrontMatterTrimsYamlQuotesAndInlineListQuotes() async throws {
    let workspace = try makeWorkspace(named: "skill-front-matter-quotes")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let skillURL = workspace.skillsDirectoryURL.appendingPathComponent("summarize-docs.md", isDirectory: false)
    try #"""
    ---
    name: "summarize docs"
    description: 'Summarizes docs: safely'
    tools: ["grep", 'search']
    ---

    # ignored fallback title
    """#.write(to: skillURL, atomically: true, encoding: .utf8)

    try """
    # AGENTS
    - [summarize docs](Skills/summarize-docs.md)
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))

    let header = try #require(try await service.skillHeaders().first)
    #expect(header.name == "summarize docs")
    #expect(header.description == "Summarizes docs: safely")
    #expect(header.tools == ["grep", "search"])
}

@Test
func malformedSkillFrontMatterThrowsInvalidSkillFile() async throws {
    let workspace = try makeWorkspace(named: "invalid-skill-front-matter")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let skillURL = workspace.skillsDirectoryURL.appendingPathComponent("broken.md", isDirectory: false)
    try """
    ---
    name: broken
    description: Missing the closing front matter marker.

    # broken
    """.write(to: skillURL, atomically: true, encoding: .utf8)

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))

    do {
        _ = try await service.registerSkill(at: skillURL)
        Issue.record("Expected invalidSkillFile to be thrown.")
    } catch let error as HarnessError {
        guard case .invalidSkillFile(skillURL) = error else {
            Issue.record("Expected invalidSkillFile, got \(error).")
            return
        }
    }
}

@Test
func agentsReferencesLoadSkillsOnlyFromSkillsDirectoryAndDocumentsAsContext() async throws {
    let workspace = try makeWorkspace(named: "agents-reference-documents")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let docsURL = workspace.rootURL.appendingPathComponent("Docs", isDirectory: true)
    try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)

    let skillURL = workspace.skillsDirectoryURL.appendingPathComponent("summarize.md", isDirectory: false)
    try """
    ---
    name: summarize
    description: Summarizes large documents.
    ---

    # summarize

    Skill body stays out of default context.
    """.write(to: skillURL, atomically: true, encoding: .utf8)

    try """
    # Harness Engineering

    Harness engineering deep reference.
    """.write(
        to: docsURL.appendingPathComponent("HarnessEngineering.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    try """
    # Current Plan

    Plan markdown is context, not a skill.
    """.write(
        to: workspace.rootURL.appendingPathComponent("PLAN.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    try """
    # AGENTS
    - [summarize](Skills/summarize.md)
    - Read HarnessEngineering.md before planning.
    - Keep PLAN.md updated.
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in request.prompt }),
        workspace: workspace
    ))

    let headers = try await service.skillHeaders()
    #expect(headers.map(\.name) == ["summarize"])

    let output = try await service.generate("Use the repo guidance.")
    #expect(output.contains("Skill Header: summarize"))
    #expect(!output.contains("Skill body stays out of default context."))
    #expect(!output.contains("Skill Header: Current Plan"))
    #expect(output.contains("Reference: Harness Engineering"))
    #expect(output.contains("Harness engineering deep reference."))
    #expect(output.contains("Reference: Current Plan"))
    #expect(output.contains("Plan markdown is context, not a skill."))
}

@Test
func agentsReferencesCannotEscapeWorkspace() async throws {
    let workspace = try makeWorkspace(named: "agents-reference-escape")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let secretFileName = "HarnessKitSecret-\(UUID().uuidString).md"
    let secretURL = workspace.rootURL
        .deletingLastPathComponent()
        .appendingPathComponent(secretFileName, isDirectory: false)
    defer { try? FileManager.default.removeItem(at: secretURL) }

    try """
    # Outside Secret

    This must not enter harness context.
    """.write(to: secretURL, atomically: true, encoding: .utf8)

    try """
    # AGENTS
    - Read ../\(secretFileName)
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in request.prompt }),
        workspace: workspace
    ))

    let output = try await service.generate("Use safe repo context.")
    #expect(!output.contains("Outside Secret"))
    #expect(!output.contains("This must not enter harness context."))
}

@Test
func agentsReferencesCannotEscapeWorkspaceThroughSymlink() async throws {
    let workspace = try makeWorkspace(named: "agents-reference-symlink-escape")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let outsideDirectoryURL = workspace.rootURL
        .deletingLastPathComponent()
        .appendingPathComponent("HarnessKitOutsideRefs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outsideDirectoryURL) }
    try FileManager.default.createDirectory(at: outsideDirectoryURL, withIntermediateDirectories: true)

    try """
    # Outside Secret

    This symlinked document must not enter harness context.
    """.write(
        to: outsideDirectoryURL.appendingPathComponent("Secret.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
    try """
    ---
    name: outside-skill
    description: This symlinked skill must not load.
    ---

    # outside-skill
    """.write(
        to: outsideDirectoryURL.appendingPathComponent("outside-skill.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    try FileManager.default.createSymbolicLink(
        at: workspace.rootURL.appendingPathComponent("Docs", isDirectory: true),
        withDestinationURL: outsideDirectoryURL
    )
    try FileManager.default.createSymbolicLink(
        at: workspace.skillsDirectoryURL.appendingPathComponent("outside-skill.md", isDirectory: false),
        withDestinationURL: outsideDirectoryURL.appendingPathComponent("outside-skill.md", isDirectory: false)
    )
    try """
    # AGENTS
    - [outside skill](Skills/outside-skill.md)
    - Read Docs/Secret.md
    """.write(to: workspace.agentsFileURL, atomically: true, encoding: .utf8)

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in request.prompt }),
        workspace: workspace
    ))

    let headers = try await service.skillHeaders()
    #expect(headers.isEmpty)

    let output = try await service.generate("Use safe symlink context.")
    #expect(!output.contains("Outside Secret"))
    #expect(!output.contains("This symlinked document must not enter harness context."))
    #expect(!output.contains("This symlinked skill must not load."))
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
func automaticToolInvocationCanBeDeniedByPermissionChecker() async throws {
    let workspace = try makeWorkspace(named: "tool-permission")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let requestRecorder = RequestRecorder()
    let invocationRecorder = InvocationRecorder()
    let observer = HarnessTranscriptObserver()
    let provider = ClosureAIModelProvider { request in
        let callCount = await requestRecorder.record(request)
        if callCount == 1 {
            return """
            <tool_call>
            {"name":"secret","input":"token"}
            </tool_call>
            """
        }

        return #"{"response":"Permission result received."}"#
    }

    let service = try AIService(configuration: .init(
        backend: .custom(provider),
        workspace: workspace,
        permissionChecker: DenyingToolPermissionChecker(
            deniedToolName: "secret",
            reason: "No secret tools in this harness."
        ),
        observer: observer
    ))
    await service.registerTool(HarnessTool(name: "secret", description: "Reads a secret.") { _ in
        await invocationRecorder.record()
        return "secret"
    })

    let output = try await service.generate("Read the secret.")
    let envelope = try decodeToolResponseEnvelope(output)

    #expect(envelope.response == "Permission result received.")
    #expect(envelope.toolResults.count == 1)
    #expect(envelope.toolResults[0].name == "secret")
    #expect(envelope.toolResults[0].status == HarnessToolInvocationResult.Status.failure)
    #expect(envelope.toolResults[0].output.contains("No secret tools in this harness."))
    #expect(await invocationRecorder.count() == 0)
    #expect(await service.status == HarnessStatus.idle)

    let waitingEvents = await observer.allEvents().filter { $0.kind == .waiting }
    #expect(waitingEvents.isEmpty)
}

@Test
func streamInterceptsCodeFencedAutomaticToolCall() async throws {
    let workspace = try makeWorkspace(named: "stream-fenced-tool-call")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let requestRecorder = RequestRecorder()
    let provider = ClosureAIModelProvider(
        generate: { request in
            _ = await requestRecorder.record(request)
            return #"{"response":"The sum is 10."}"#
        },
        stream: { request in
            let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
            let worker = Task {
                _ = await requestRecorder.record(request)
                continuation.yield(Generation(kind: .delta, text: "```json\n"))
                continuation.yield(Generation(kind: .delta, text: "<tool_call>"))
                continuation.yield(Generation(kind: .delta, text: #"{"name":"add-numbers","input":"4, 6"}"#))
                continuation.yield(Generation(kind: .delta, text: "</tool_call>\n"))
                continuation.yield(Generation(kind: .delta, text: "```"))
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

    let stream = try await service.stream("What is 4 + 6?")
    var visibleText = ""
    for try await generation in stream where generation.kind != .metadata {
        visibleText += generation.text
    }

    let envelope = try decodeToolResponseEnvelope(visibleText)
    #expect(envelope.response == "The sum is 10.")
    #expect(envelope.toolResults.map(\.output) == ["10"])
    #expect(!visibleText.contains("```"))
    #expect(!visibleText.contains("<tool_call>"))
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
func concurrentGenerationsKeepServiceWorkingUntilAllComplete() async throws {
    let workspace = try makeWorkspace(named: "concurrent-status")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let gate = ConcurrentRequestGate()
    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in
            await gate.markStarted(request.input)
            await gate.waitUntilReleased(request.input)
            return request.input
        }),
        workspace: workspace
    ))

    let first = Task {
        try await service.generate("first")
    }
    await gate.waitForStartedCount(1)

    let second = Task {
        try await service.generate("second")
    }
    await gate.waitForStartedCount(2)
    #expect(await service.status == .working)

    await gate.release("first")
    #expect(try await first.value == "first")
    #expect(await service.status == .working)

    await gate.release("second")
    #expect(try await second.value == "second")
    #expect(await service.status == .idle)
}

@Test
func concurrentWaitingGenerationsRequireOneAcknowledgementPerWait() async throws {
    let workspace = try makeWorkspace(named: "concurrent-waits")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let gate = ConcurrentRequestGate()
    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { request in
            await gate.markStarted(request.input)
            await gate.waitUntilReleased(request.input)
            return request.input
        }),
        workspace: workspace,
        governor: WaitingGovernor()
    ))

    let first = Task {
        try await service.generate("first")
    }
    await gate.waitForStartedCount(1)

    let second = Task {
        try await service.generate("second")
    }
    await gate.waitForStartedCount(2)

    await gate.release("first")
    #expect(try await first.value == "first")
    #expect(await service.status == .working)

    await gate.release("second")
    #expect(try await second.value == "second")
    #expect(await service.status == .waiting)

    await service.acknowledgeWaitState()
    #expect(await service.status == .waiting)

    await service.acknowledgeWaitState()
    #expect(await service.status == .idle)
}

@Test
func duplicateConcurrentSubagentContextRequestsCreateOneWait() async throws {
    let workspace = try makeWorkspace(named: "duplicate-subagent-waits")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace
    ))
    let subagent = try await service.spawnSubagent(
        taskSummary: "Audit duplicate waits",
        input: "Wait for context."
    )

    async let first: Void = service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need context")
    async let second: Void = service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need context")
    _ = try await (first, second)

    #expect(await service.status == .waiting)
    await service.acknowledgeWaitState()
    #expect(await service.status == .idle)
}

@Test
func concurrentSatisfyPendingSubagentRequestsStayWorkingUntilAllComplete() async throws {
    let workspace = try makeWorkspace(named: "concurrent-satisfy")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let gate = ContextBuildGate()
    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace,
        contextBuilder: GatedContextBuilder(gate: gate)
    ))
    let subagent = try await service.spawnSubagent(
        taskSummary: "Needs gated context",
        input: "Wait for gated context."
    )
    try await service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need context")

    let first = Task {
        try await service.satisfyPendingSubagentRequests()
    }
    await gate.waitForStartedCount(1)

    let second = Task {
        try await service.satisfyPendingSubagentRequests()
    }
    await gate.waitForStartedCount(2)
    #expect(await service.status == .working)

    await gate.releaseOne()
    _ = try await first.value
    #expect(await service.status == .working)

    await gate.releaseOne()
    _ = try await second.value
    #expect(await service.status == .idle)
}

@Test
func staleSubagentWaitRefreshDoesNotReopenSatisfiedWait() async throws {
    let workspace = try makeWorkspace(named: "stale-subagent-wait-refresh")
    defer { try? FileManager.default.removeItem(at: workspace.rootURL) }

    let subagentManager = StaleSubagentReadManager(rootURL: workspace.agentsDirectoryURL)
    let service = try AIService(configuration: .init(
        backend: .custom(ClosureAIModelProvider { _ in "unused" }),
        workspace: workspace,
        contextBuilder: SucceedingContextBuilder(),
        subagentManager: subagentManager
    ))
    let subagent = try await service.spawnSubagent(
        taskSummary: "Needs context",
        input: "Wait for context."
    )

    await subagentManager.holdNextSubagentRead()
    let markTask = Task {
        try await service.markSubagentNeedsMoreContext(id: subagent.id, request: "Need context")
    }
    await subagentManager.waitForHeldRead()

    let resolved = try await service.satisfyPendingSubagentRequests()
    #expect(resolved.count == 1)
    #expect(await service.status == .idle)

    await subagentManager.releaseHeldRead()
    try await markTask.value
    #expect(await service.status == .idle)
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

@Test
func environmentSnapshotDecodesWithoutReferenceDocumentsForCompatibility() throws {
    let workspace = HarnessWorkspace(rootURL: URL(fileURLWithPath: "/tmp/HarnessKitCompatibility", isDirectory: true))
    let legacySnapshot = LegacyEnvironmentSnapshot(
        workspace: workspace,
        providerKind: .custom,
        toolDescriptors: [],
        skills: [],
        memoryFiles: [],
        subagents: [],
        agentsFileText: nil
    )

    let data = try JSONEncoder().encode(legacySnapshot)
    let decoded = try JSONDecoder().decode(HarnessEnvironmentSnapshot.self, from: data)

    #expect(decoded.workspace == workspace)
    #expect(decoded.referenceDocuments.isEmpty)
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

private func writeSubagentFiles(
    to directoryURL: URL,
    contextStatus: String,
    context: String,
    input: String,
    taskSummary: String,
    output: String
) throws {
    try """
    # Context

    <!-- HarnessKit:Resolution -->
    \(contextStatus)
    <!-- /HarnessKit:Resolution -->

    <!-- HarnessKit:Context -->
    \(context)
    <!-- /HarnessKit:Context -->
    """.write(
        to: directoryURL.appendingPathComponent("CONTEXT.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    try """
    # Input

    <!-- HarnessKit:NeedMoreContext -->
    false
    <!-- /HarnessKit:NeedMoreContext -->

    <!-- HarnessKit:ContextRequest -->

    <!-- /HarnessKit:ContextRequest -->

    <!-- HarnessKit:Input -->
    \(input)
    <!-- /HarnessKit:Input -->
    """.write(
        to: directoryURL.appendingPathComponent("INPUT.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    try """
    # Output

    <!-- HarnessKit:TaskSummary -->
    \(taskSummary)
    <!-- /HarnessKit:TaskSummary -->

    <!-- HarnessKit:Output -->
    \(output)
    <!-- /HarnessKit:Output -->
    """.write(
        to: directoryURL.appendingPathComponent("OUTPUT.md", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
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

private struct CancellingContextBuilder: HarnessContextBuilding {
    func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext {
        _ = (input, intent, environment)
        throw CancellationError()
    }
}

private struct GatedContextBuilder: HarnessContextBuilding {
    var gate: ContextBuildGate

    func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext {
        _ = (input, intent, environment)
        await gate.waitForRelease()
        return HarnessContext(fragments: [
            .init(kind: .custom, title: "Gated Context", body: "Released context.")
        ])
    }
}

private struct SucceedingContextBuilder: HarnessContextBuilding {
    func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext {
        _ = (input, intent, environment)
        return HarnessContext(fragments: [
            .init(kind: .custom, title: "Context", body: "Resolved context.")
        ])
    }
}

private struct SucceedsThenCancelsContextBuilder: HarnessContextBuilding {
    var sequence: ContextBuildSequence

    func buildContext(
        for input: String,
        intent: HarnessIntent,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessContext {
        _ = (input, intent, environment)
        if await sequence.nextCallNumber() == 1 {
            return HarnessContext(fragments: [
                .init(kind: .custom, title: "Partial Context", body: "Resolved before cancellation.")
            ])
        }
        throw CancellationError()
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

private struct WaitingGovernor: HarnessGoverning {
    func decide(
        verification: HarnessVerification,
        evaluation: HarnessEvaluation
    ) async -> HarnessGovernanceDecision {
        _ = (verification, evaluation)
        return .wait(reason: "Human review required.")
    }
}

private struct DenyingToolPermissionChecker: HarnessToolPermissionChecking {
    var deniedToolName: String
    var reason: String

    func authorize(
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision {
        _ = (plan, environment)
        return HarnessPermissionDecision(isAllowed: true)
    }

    func authorizeToolInvocation(
        _ invocation: HarnessToolInvocationRequest,
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision {
        _ = (plan, environment)
        return HarnessPermissionDecision(
            isAllowed: invocation.name != deniedToolName,
            reason: invocation.name == deniedToolName ? reason : nil
        )
    }
}

private struct LegacyEnvironmentSnapshot: Encodable {
    var workspace: HarnessWorkspace
    var providerKind: AIProviderKind
    var toolDescriptors: [HarnessToolDescriptor]
    var skills: [HarnessSkillHeader]
    var memoryFiles: [HarnessMemoryFile]
    var subagents: [HarnessSubagentRecord]
    var agentsFileText: String?
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

private actor InvocationRecorder {
    private var invocationCount = 0

    func record() {
        invocationCount += 1
    }

    func count() -> Int {
        invocationCount
    }
}

private actor ConcurrentRequestGate {
    private var startedInputs: [String] = []
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releasedInputs: Set<String> = []
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func markStarted(_ input: String) {
        startedInputs.append(input)
        resumeStartedWaiters()
    }

    func waitForStartedCount(_ count: Int) async {
        if startedInputs.count >= count {
            return
        }

        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func waitUntilReleased(_ input: String) async {
        if releasedInputs.contains(input) {
            return
        }

        await withCheckedContinuation { continuation in
            releaseWaiters[input, default: []].append(continuation)
        }
    }

    func release(_ input: String) {
        releasedInputs.insert(input)
        let waiters = releaseWaiters.removeValue(forKey: input) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeStartedWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startedWaiters {
            if startedInputs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        startedWaiters = pending
    }
}

private actor ContextBuildGate {
    private var startedCount = 0
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseCount = 0

    func waitForRelease() async {
        startedCount += 1
        resumeStartedWaiters()

        if releaseCount > 0 {
            releaseCount -= 1
            return
        }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForStartedCount(_ count: Int) async {
        if startedCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func releaseOne() {
        if releaseWaiters.isEmpty {
            releaseCount += 1
            return
        }

        let waiter = releaseWaiters.removeFirst()
        waiter.resume()
    }

    private func resumeStartedWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startedWaiters {
            if startedCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        startedWaiters = pending
    }
}

private actor ContextBuildSequence {
    private var callCount = 0

    func nextCallNumber() -> Int {
        callCount += 1
        return callCount
    }
}

private actor StaleSubagentReadManager: HarnessSubagentManaging {
    private let rootURL: URL
    private var recordsByID: [String: HarnessSubagentRecord] = [:]
    private var shouldHoldNextSubagentRead = false
    private var heldReadStarted = false
    private var heldReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldReadRelease: CheckedContinuation<Void, Never>?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func holdNextSubagentRead() {
        shouldHoldNextSubagentRead = true
        heldReadStarted = false
    }

    func waitForHeldRead() async {
        if heldReadStarted {
            return
        }

        await withCheckedContinuation { continuation in
            heldReadWaiters.append(continuation)
        }
    }

    func releaseHeldRead() {
        heldReadRelease?.resume()
        heldReadRelease = nil
    }

    func createSubagent(
        taskSummary: String,
        input: String,
        context: String
    ) async throws -> HarnessSubagentRecord {
        let id = UUID().uuidString
        let record = HarnessSubagentRecord(
            id: id,
            directoryURL: rootURL.appendingPathComponent(id, isDirectory: true),
            context: HarnessContextResolution(status: context.isEmpty ? .empty : .provided, details: context),
            input: HarnessSubagentInput(task: input),
            output: HarnessSubagentOutput(taskSummary: taskSummary, output: "")
        )
        recordsByID[id] = record
        return record
    }

    func listSubagents() async throws -> [HarnessSubagentRecord] {
        recordsByID.values.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    func subagent(id: String) async throws -> HarnessSubagentRecord? {
        guard let snapshot = recordsByID[id] else {
            return nil
        }

        if shouldHoldNextSubagentRead {
            shouldHoldNextSubagentRead = false
            heldReadStarted = true
            for waiter in heldReadWaiters {
                waiter.resume()
            }
            heldReadWaiters.removeAll()

            await withCheckedContinuation { continuation in
                heldReadRelease = continuation
            }
            return snapshot
        }

        return snapshot
    }

    func markNeedsMoreContext(for id: String, request: String) async throws {
        guard var record = recordsByID[id] else {
            throw HarnessError.missingSubagent(id)
        }
        record.input.needsMoreContext = true
        record.input.contextRequest = request
        recordsByID[id] = record
    }

    func satisfyContextRequest(for id: String, context: String) async throws -> HarnessSubagentRecord {
        guard var record = recordsByID[id] else {
            throw HarnessError.missingSubagent(id)
        }
        record.context = HarnessContextResolution(status: .provided, details: context)
        record.input.needsMoreContext = false
        record.input.contextRequest = ""
        recordsByID[id] = record
        return record
    }

    func rejectContextRequest(for id: String, reason: String) async throws -> HarnessSubagentRecord {
        guard var record = recordsByID[id] else {
            throw HarnessError.missingSubagent(id)
        }
        record.context = HarnessContextResolution(status: .rejected, details: reason)
        record.input.needsMoreContext = false
        record.input.contextRequest = ""
        recordsByID[id] = record
        return record
    }

    func updateOutput(for id: String, summary: String, output: String) async throws -> HarnessSubagentRecord {
        guard var record = recordsByID[id] else {
            throw HarnessError.missingSubagent(id)
        }
        record.output = HarnessSubagentOutput(taskSummary: summary, output: output)
        recordsByID[id] = record
        return record
    }
}

private struct IntentionalFailure: Error {}
