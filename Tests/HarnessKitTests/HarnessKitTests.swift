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

    let status = await service.status
    #expect(status == .waiting)
    await service.acknowledgeWaitState()
    let idleStatus = await service.status
    #expect(idleStatus == .idle)
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
