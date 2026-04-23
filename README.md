# HarnessKit

`HarnessKit` is a Swift package for AI harness engineering.

It is designed around a simple public interface:

- `String -> String` via `AIService.generate(_:)` or `callAsFunction(_:)`
- `String -> AsyncThrowingStream<Generation, Error>` via `AIService.stream(_:)`

The harness work happens behind that interface. Developers configure tools, skills, memory, workflow components, and model backends, while `HarnessKit` handles the environment around the model.

## What It Provides

- A configurable `AIService` that can run against:
  - API-backed providers
  - Apple Intelligence-backed providers
  - custom model providers
- Standalone interfaces for each harness layer:
  - intent resolution
  - context building
  - permission checks
  - workflow building
  - verification
  - evaluation
  - observability
  - governance
  - caching
  - memory storage
  - subagent management
- Tool registration for hardcoded Swift functions
- Skill registration for Markdown-based skills
- Automatic `AGENTS.md` discovery for referenced skills
- A filesystem-backed cache that stores:
  - raw input
  - processed context
  - raw model output
  - metadata
- A filesystem-backed subagent model under `agents/`

## Current Scope

`HarnessKit` provides the harness runtime and provider abstractions. It does not ship a concrete HTTP client for an external API or a built-in Apple Intelligence / MLX implementation yet.

To integrate a real model, conform to one of:

- `APIModelProviding`
- `AppleIntelligenceProviding`
- `AIModelProviding`

For local testing and glue code, `ClosureAIModelProvider`, `ClosureAPIModelProvider`, and `ClosureAppleIntelligenceProvider` are included.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/PangJiaxin0326/HarnessKit.git", branch: "main")
]
```

Then add the product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "HarnessKit", package: "HarnessKit")
    ]
)
```

## Quick Start

```swift
import Foundation
import HarnessKit

let provider = ClosureAIModelProvider { request in
    """
    Prompt prepared by the harness:

    \(request.prompt)
    """
}

let workspace = HarnessWorkspace.current()

let service = try AIService(configuration: .init(
    backend: .custom(provider),
    workspace: workspace
))

await service.registerTool(HarnessTool(
    name: "search",
    description: "Search the local codebase."
) { query in
    "searched for: \(query)"
})

let reply = try await service.generate("Summarize the current repository.")
print(reply)
```

The default harness will:

1. Resolve intent from the input
2. Read `AGENTS.md` if present
3. Load skill headers referenced by `AGENTS.md`
4. Load memory files from the configured memory directory
5. Build processed context
6. Store raw input and processed context in the on-disk cache
7. Call the configured provider
8. Automatically round-trip through registered tools when the model emits a `<tool_call>` request
9. Validate tool-assisted completions as structured JSON and retry if the provider returns invalid JSON
10. Store the raw output in the cache
11. Return to `idle` after successful completion, or move into `waiting` when the harness needs more caller action

If you want the compact `String -> String` mental model, you can also use:

```swift
let reply = try await service("Summarize the current repository.")
```

## Streaming

```swift
let stream = try await service.stream("Explain the current architecture.")

for try await generation in stream {
    switch generation.kind {
    case .metadata:
        break
    case .delta, .completed:
        print(generation.text, terminator: "")
    }
}
```

`Generation.Kind` currently supports:

- `metadata`
- `delta`
- `completed`

## Tools, Skills, and Memory

### Tools

Tools are Swift functions registered at runtime:

```swift
await service.registerTool(HarnessTool(
    name: "read-file",
    description: "Read a file from disk."
) { path in
    try String(contentsOfFile: path, encoding: .utf8)
})
```

You can also use `HarnessToolRegistry` directly if you want a standalone registry outside `AIService`.

When tools are registered, the default workflow also teaches the model a small text protocol for automatic tool use. A compliant model can respond with:

```text
<tool_call>
{"name":"read-file","input":"README.md"}
</tool_call>
```

`AIService` will invoke the tool, continue the round trip automatically, and if a tool was used it will return a JSON string decodable as `HarnessToolResponseEnvelope`:

```json
{
  "response": "Summary for the user.",
  "toolResults": [
    {
      "name": "read-file",
      "input": "README.md",
      "output": "# HarnessKit",
      "status": "success"
    }
  ]
}
```

If the model returns invalid JSON after a tool round trip, the harness automatically retries with a repair prompt before failing the request.

### Skills

Skills are Markdown files. The default model is:

- the harness exposes a skill's `name`, `description`, and tool list first
- the full Markdown body stays in the file system until explicitly requested

You can register skills directly:

```swift
let header = try await service.registerSkill(at: skillURL)
print(header.name)
```

Or let `AGENTS.md` drive discovery automatically:

```md
# AGENTS

- [summarize](Skills/summarize.md)
- [reviewer](Skills/reviewer.md)
```

If you need the full skill contents later:

```swift
let document = try await service.skillDocument(named: "summarize")
print(document?.body ?? "")
```

### Memory

Memory files are also Markdown files. They are stored on disk and remain accessible to both the harness and the caller:

```swift
await service.registerMemoryFile(at: memoryURL)
let urls = try await service.memoryFileURLs()
```

## Workspace Layout

By default, `HarnessWorkspace` uses this layout relative to `rootURL`:

```text
<root>/
  AGENTS.md
  Skills/
  Memory/
  .harness-cache/
  agents/
```

You can customize all of these directory names through `HarnessWorkspace`.

### Cache Layout

Each harness run creates a cache directory under `.harness-cache/<uuid>/` containing:

```text
raw-input.txt
processed-context.md
raw-output.txt
metadata.json
```

This is intended to preserve the raw text, the processed context, and the final returned payload.

## Subagents

Subagents are stored as simple folders under `agents/`. Each subagent keeps only three files:

```text
agents/<id>/
  CONTEXT.md
  INPUT.md
  OUTPUT.md
```

The current flow is:

- `CONTEXT.md` stores the context resolution and whether it was provided or rejected
- `INPUT.md` stores the task plus the `needsMoreContext` flag and request text
- `OUTPUT.md` stores a task summary and the output

Example:

```swift
let subagent = try await service.spawnSubagent(
    taskSummary: "Audit memory usage",
    input: "Inspect the memory files."
)

try await service.markSubagentNeedsMoreContext(
    id: subagent.id,
    request: "Need repo memory context"
)

let resolved = try await service.satisfyPendingSubagentRequests()
let updated = try await service.updateSubagentOutput(
    id: subagent.id,
    summary: "Audit memory usage",
    output: "Memory inspection complete."
)
```

## Status Model

`AIService` currently exposes three states:

- `idle`
- `working`
- `waiting`

`waiting` is used when the harness is waiting for the caller to provide more context or when governance blocks automatic completion. Successful runs return to `idle`.

## Customizing the Harness

Every major harness layer is replaceable through `AIService.Configuration`.

Available extension points include:

- `HarnessIntentResolving`
- `HarnessContextBuilding`
- `HarnessPermissionChecking`
- `HarnessWorkflowBuilding`
- `HarnessVerifying`
- `HarnessEvaluating`
- `HarnessObserving`
- `HarnessGoverning`
- `HarnessCaching`
- `HarnessMemoryStoring`
- `HarnessSubagentManaging`

This makes it possible to keep the outer API simple while evolving the harness internals independently.

## Platform Support

The package currently declares:

- macOS 15+
- iOS 18+
- tvOS 18+
- watchOS 11+
- visionOS 2+

Swift language mode is Swift 6.

## Repository Notes

- The package design is informed by [Docs/HarnessEngineering.md](Docs/HarnessEngineering.md).
- The current implementation focuses on harness structure, filesystem persistence, and extension points.
- Apple Intelligence and MLX integration are intended to plug into the existing provider protocols as concrete backends mature.
