# HarnessKit

`HarnessKit` is a Swift package for AI harness engineering: the runtime, filesystem state, tool contracts, permissions, verification hooks, and observable evidence around a model.

The core idea comes from [Docs/HarnessEngineering.md](Docs/HarnessEngineering.md):

```text
Agent = Model + Harness
```

The model reasons. The harness gives that model a safe, inspectable world to operate in: context, memory, tools, skills, permissions, workflow, cache records, verification, evaluation, governance, and subagent handoff files.

`HarnessKit` keeps the outer interface intentionally small:

```swift
let output = try await service.generate("Summarize this workspace.")
let stream = try await service.stream("Explain this plan.")
let outputAgain = try await service("Use callAsFunction.")
```

Behind that interface, `AIService` builds an environment snapshot, prepares context, authorizes the run, executes the provider, handles tool round trips, writes cache artifacts, verifies and evaluates the output, then applies governance before reporting completion.

## Package Scope

`HarnessKit` provides the harness runtime and public extension points. It does not ship a concrete HTTP client, Apple Intelligence adapter, or local MLX backend.

Bring your own model by conforming to one of:

- `AIModelProviding`
- `APIModelProviding`
- `AppleIntelligenceProviding`

For tests, demos, and integration glue, the package includes:

- `ClosureAIModelProvider`
- `ClosureAPIModelProvider`
- `ClosureAppleIntelligenceProvider`

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

The package currently declares Swift 6 mode and these Apple platform minimums:

- macOS 15+
- iOS 18+
- tvOS 18+
- watchOS 11+
- visionOS 2+

## Quick Start

```swift
import Foundation
import HarnessKit

let provider = ClosureAIModelProvider { request in
    """
    Provider received this harness prompt:

    \(request.prompt)
    """
}

let service = try AIService(configuration: .init(
    backend: .custom(provider),
    workspace: .current()
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

The default run performs this sequence:

1. Refresh skill headers and reference documents from `AGENTS.md`.
2. Snapshot registered tools, skill headers, reference documents, memory files, subagents, and `AGENTS.md`.
3. Resolve intent from the user input.
4. Build processed context.
5. Build the provider prompt.
6. Authorize the plan.
7. Cache raw input and processed context.
8. Call the configured model provider.
9. Run automatic tool round trips when the provider emits a valid `<tool_call>` block.
10. Validate tool-assisted completions as structured JSON.
11. Cache raw output.
12. Verify, evaluate, and govern the result.

## Harness Layers

`Docs/HarnessEngineering.md` describes harness engineering as the world around the model. `HarnessKit` maps that idea into concrete Swift layers.

| Harness idea | HarnessKit types |
| --- | --- |
| Intent and specification | `HarnessIntent`, `HarnessIntentResolving`, `PassthroughIntentResolver` |
| Context and memory | `HarnessContext`, `HarnessReferenceDocument`, `HarnessMemoryFile`, `HarnessContextBuilding`, `DefaultContextBuilder` |
| Tools and environment | `HarnessTool`, `HarnessToolRegistry`, `HarnessToolDescriptor`, automatic tool loop |
| Permission and sandbox | `HarnessPermissionChecking`, `HarnessToolPermissionChecking`, `HarnessPermissionDecision` |
| Workflow and orchestration | `AIService`, `HarnessWorkflowBuilding`, `DefaultHarnessWorkflow`, `HarnessPlan` |
| Verification and feedback | `HarnessVerifying`, `HarnessEvaluating`, `HarnessGoverning` |
| Observability | `HarnessObserving`, `HarnessTranscriptObserver`, `HarnessEvent` |
| Persistence | `FileSystemHarnessCache`, `FileSystemMemoryStore`, `FileSystemSubagentManager` |

All major layers are replaceable through `AIService.Configuration`.

## Workspace Layout

`HarnessWorkspace` describes where the harness reads and writes local state. By default it uses:

```text
<root>/
  AGENTS.md
  Skills/
  Memory/
  .harness-cache/
  agents/
```

You can customize each directory name:

```swift
let workspace = HarnessWorkspace(
    rootURL: rootURL,
    skillsDirectoryName: "Skills",
    memoryDirectoryName: "Memory",
    cacheDirectoryName: ".harness-cache",
    agentsDirectoryName: "agents",
    agentsFileName: "AGENTS.md"
)
```

`AIService` prepares these directories during initialization.

## AGENTS, Skills, and Reference Documents

`AGENTS.md` is treated as the short map into the repository. The default runtime reads it in two ways.

First, Markdown files referenced under the workspace `Skills/` directory are loaded as skills. Only their headers are exposed in default context:

```md
# AGENTS

- [summarize](Skills/summarize.md)
```

```md
---
name: summarize
description: Summarizes large documents.
tools: ["search", "read-file"]
---

# summarize

The full skill body remains on disk until the caller asks for it.
```

Second, other Markdown references from `AGENTS.md` are loaded as reference documents and included in processed context. This supports the "short map, deep docs" pattern from `Docs/HarnessEngineering.md`.

```md
# AGENTS

- Read Docs/HarnessEngineering.md before changing harness behavior.
- Keep PLAN.md updated during multi-step changes.
```

Bare document names can resolve through `Docs/` when the file is not present at the workspace root, so `HarnessEngineering.md` can resolve to `Docs/HarnessEngineering.md`.

All `AGENTS.md` Markdown references are resolved as regular files inside the workspace root after symlinks are resolved. Absolute paths, parent-directory references, and symlinked paths that would escape the workspace are ignored.

This split matters:

- Skills are compact capability headers: name, description, tool list, file URL.
- Reference documents are full context: title, file URL, contents.
- A working plan like `PLAN.md` no longer becomes an accidental skill.

You can inspect skills explicitly:

```swift
let headers = try await service.skillHeaders()
let document = try await service.skillDocument(named: "summarize")
```

## Memory

Memory files are Markdown files under the workspace memory directory, plus any URLs registered at runtime.

```swift
await service.registerMemoryFile(at: memoryURL)
let urls = try await service.memoryFileURLs()
```

The default context builder includes the full contents of memory files in processed context.

Use memory for durable, task-family knowledge the harness should carry across runs. Use reference documents for repository docs discovered through `AGENTS.md`.

## Tools

Tools are Swift functions registered at runtime:

```swift
await service.registerTool(HarnessTool(
    name: "read-file",
    description: "Read a UTF-8 file from disk."
) { path in
    try String(contentsOfFile: path, encoding: .utf8)
})
```

Registered tools are visible to the provider through `HarnessToolDescriptor` values and default prompt instructions.

When a tool is needed, a compatible provider can return only:

```text
<tool_call>
{"name":"read-file","input":"README.md"}
</tool_call>
```

`AIService` parses the request, checks optional per-tool permissions, invokes the tool, appends the result to the prompt, and asks the provider to continue.

After at least one tool was used, the final provider response must be JSON:

```json
{"response":"Summary for the user."}
```

`AIService.generate(_:)` returns the JSON envelope as its string result. `AIService.stream(_:)` emits the same envelope as streamed `Generation` text after a tool-assisted run:

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

Decode it as `HarnessToolResponseEnvelope` when you need tool evidence.

If the provider returns invalid JSON after a tool round trip, the harness asks for a repaired structured response before failing with `HarnessError.invalidToolResponse`.

## Tool Permissions

Plan-level authorization happens through `HarnessPermissionChecking`:

```swift
public protocol HarnessPermissionChecking: Sendable {
    func authorize(
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision
}
```

Automatic tool calls can also be gated per invocation by conforming to `HarnessToolPermissionChecking`:

```swift
struct Policy: HarnessToolPermissionChecking {
    func authorize(
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision {
        HarnessPermissionDecision(isAllowed: true)
    }

    func authorizeToolInvocation(
        _ invocation: HarnessToolInvocationRequest,
        plan: HarnessPlan,
        environment: HarnessEnvironmentSnapshot
    ) async throws -> HarnessPermissionDecision {
        HarnessPermissionDecision(
            isAllowed: invocation.name != "delete-file",
            reason: "This harness does not allow file deletion."
        )
    }
}
```

Denied automatic tool calls are not executed. The model receives a failed tool result and can continue with that evidence.

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

`Generation.Kind` supports:

- `metadata`
- `delta`
- `completed`

When tools are registered, streamed output is buffered just long enough to detect whether it is an automatic tool call. Plain user-visible deltas are forwarded. Tool call blocks are intercepted, including tool calls enclosed in a complete Markdown code fence.

## Cache Records

Each run creates one cache directory:

```text
.harness-cache/<uuid>/
  raw-input.txt
  processed-context.md
  raw-output.txt
  metadata.json
```

The cache preserves:

- the original caller input
- the processed context sent into the workflow
- the final returned payload
- metadata such as provider kind, intent goal, tool names, skill names, and memory file paths

Read cache records through:

```swift
let records = try await service.cacheRecords()
```

## Subagents

Subagents are filesystem-backed handoff records under `agents/`.

```text
agents/<id>/
  CONTEXT.md
  INPUT.md
  OUTPUT.md
```

Create and update them through `AIService`:

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

Subagent files are Markdown, but field boundaries are stored with internal HTML comments so nested Markdown headings in context or output survive a full write/read round trip. Literal HarnessKit marker comments inside field values are escaped on write and restored on read.

Directories under `agents/` that contain none of the required handoff files are ignored. A partially-written subagent directory with only some of `CONTEXT.md`, `INPUT.md`, and `OUTPUT.md` is rejected with `HarnessError.invalidSubagent`.

Caller-supplied subagent IDs must name a direct child of `agents/`. Empty IDs, path separators, `.` and `..` are rejected with `HarnessError.invalidSubagent`.

## Status Model

`AIService.status` returns:

- `idle`
- `working`
- `waiting`

`working` wins while any execution is active. This keeps status accurate when concurrent callers use the same service actor. When all active work finishes, the service returns to `idle` unless a permission, governance, or subagent flow is waiting for caller action.

Use `acknowledgeWaitState()` after external action has handled a waiting condition. If multiple runs or subagents enter `waiting`, call it once for each handled condition.

## Extension Points

Configure `AIService` with custom components:

```swift
let service = try AIService(configuration: .init(
    backend: .custom(provider),
    workspace: workspace,
    intentResolver: MyIntentResolver(),
    contextBuilder: MyContextBuilder(),
    permissionChecker: MyPolicy(),
    workflow: MyWorkflow(),
    verifier: MyVerifier(),
    evaluator: MyEvaluator(),
    observer: MyObserver(),
    governor: MyGovernor()
))
```

Available protocols:

- `HarnessIntentResolving`
- `HarnessContextBuilding`
- `HarnessPermissionChecking`
- `HarnessToolPermissionChecking`
- `HarnessWorkflowBuilding`
- `HarnessVerifying`
- `HarnessEvaluating`
- `HarnessObserving`
- `HarnessGoverning`
- `HarnessCaching`
- `HarnessMemoryStoring`
- `HarnessSubagentManaging`

The default implementations are deliberately small and replaceable. They are useful scaffolding, not a complete production policy.

## Public Runtime Types

Common data types:

- `AIModelRequest`: prompt, original input, intent, context, tools, skills, provider kind
- `Generation`: streamed metadata, delta, or completed text
- `HarnessPlan`: prepared input, intent, context, tool and skill headers, memory file URLs, prompt
- `HarnessEnvironmentSnapshot`: workspace, provider kind, tools, skills, reference documents, memory files, subagents, AGENTS text
- `HarnessToolInvocationResult`: name, input, output, success/failure status
- `HarnessToolResponseEnvelope`: final user response plus tool evidence
- `HarnessEvent`: observer event with kind, message, and timestamp

Errors are reported through `HarnessError`.

## Testing

Run the package tests:

```sh
swift test
```

The suite uses Swift Testing and covers:

- generation and prompt construction
- streaming
- automatic tool round trips
- structured tool response repair
- per-tool permission denial
- AGENTS-linked skills and reference documents
- skill front matter parsing
- malformed skill and subagent files
- subagent persistence
- nested Markdown round trips
- concurrent service status
- cache persistence
- failure and governance status behavior

## Design Notes

`HarnessKit` is intentionally filesystem-first. That makes the harness inspectable: humans can read cache records, memory files, reference documents, and subagent handoffs without a database or special viewer.

The default harness favors deterministic checks and simple extension points. For production use, replace the permissive defaults with project-specific policies:

- a real model provider
- least-privilege tool permission checks
- context selection tuned to your repository
- verifiers that run deterministic tests or linters
- evaluators for semantic quality signals
- observers that write logs or traces
- governors that decide when to finish, wait, fail, or escalate

That is the practical harness-engineering loop: observe what fails, encode a better guide or sensor, rerun, and keep the environment honest.
