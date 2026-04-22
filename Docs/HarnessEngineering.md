Harness Engineering is the practice of designing the execution environment around an AI model so that the model can act reliably as an agent. It covers the tools it can use, the context it sees, the memory it carries, the permissions it has, the tests it must pass, the logs humans can inspect, and the feedback loops that help it self-correct.

A useful formula is:

Agent = Model + Harness

The model is the reasoning engine. The harness is the “world” the model operates inside: files, tools, APIs, retrieval, memory, validators, evaluators, workflows, sandboxes, and human escalation paths. The term became prominent in early 2026: Mitchell Hashimoto described “engineering the harness” as fixing the agent’s environment whenever it repeats a mistake, and OpenAI, Anthropic, Thoughtworks/Martin Fowler, LangChain, and others have since used similar language around agent systems.  ￼

A compact way to see it:

User goal
  ↓
Spec / acceptance criteria / constraints
  ↓
Harness
  ├─ context + memory + retrieval
  ├─ tools + permissions + sandbox
  ├─ workflow / planner / task loop
  ├─ tests + linters + evals + QA agents
  ├─ logs + traces + observability
  └─ human review / escalation
  ↓
Model acts
  ↓
Environment returns evidence
  ↓
Harness decides: continue, repair, escalate, or stop

How it differs from prompt and context engineering

Prompt engineering asks: What should I say to the model?
Context engineering asks: What should the model see at this moment?
Harness engineering asks: What world should the model operate in, and how do we keep that world safe, testable, inspectable, and self-correcting?

Anthropic describes context engineering as curating the tokens available to the model during inference; harness engineering goes wider, because it includes the runtime loop, tools, state, environment, verification, and governance around the model.  ￼

In practice:

Layer	Main question	Typical artifacts
Prompt engineering	What do we tell the model?	system prompt, examples, role instructions
Context engineering	What information is available now?	retrieval, memory, summaries, compaction, document selection
Harness engineering	How does the agent act, verify, recover, and stop?	tools, permissions, tests, sandboxes, workflows, logs, evaluators, CI/CD, human gates
Model training / fine-tuning	How do we change the model itself?	weights, RL, supervised fine-tuning, distillation

Why harness engineering became important

The problem is that modern AI agents are no longer just answering a question. They are using tools, editing files, running code, browsing, querying databases, producing pull requests, and working across long sessions. A raw LLM does not naturally have durable memory, safe permissions, a reliable sense of completion, or a built-in way to prove that its work is correct.

Anthropic’s long-running-agent work frames the issue clearly: complex tasks can span many context windows, and each fresh agent session starts without the previous session’s memory unless the harness creates structured handoff artifacts. Their experiments used an initializer agent, progress files, git commits, feature lists, and browser automation to keep long-running development coherent.  ￼

OpenAI’s Codex write-up shows the same shift from “humans write code” to “humans design the environment.” Their team reported building an internal product beta with no manually written code; engineers instead focused on scaffolding, documentation, feedback loops, tools, and constraints so Codex could do useful work.  ￼

The core components of a harness

1. Intent and specification layer

This is where vague goals become actionable tasks. A good harness forces the system to define scope, acceptance criteria, relevant files, output artifacts, and “done” conditions before execution.

Red Hat’s write-up gives a practical pattern: first produce a repository impact map from the real codebase, then turn approved findings into structured tasks with concrete file paths, symbols, and implementation notes. The point is to stop the agent from guessing.  ￼

2. Context and memory layer

Agents need maps, not giant manuals. OpenAI found that a monolithic AGENTS.md failed because it consumed context, became stale, and was hard to verify. Their solution was a short AGENTS.md as a table of contents, with structured repository docs as the system of record and CI checks to keep them fresh.  ￼

This layer includes short-term memory, long-term memory, retrieval, progress logs, task state, design docs, previous decisions, and compaction or reset strategies. LangChain argues that memory is not just a plugin; it is tightly tied to the harness because the harness decides what survives, what gets summarized, how tools are represented, and how past interactions become queryable.  ￼

3. Tool and environment layer

The harness gives the model “hands and eyes”: shell commands, code search, browser automation, databases, APIs, design systems, logs, metrics, files, and sometimes external tools through protocols such as MCP.

Anthropic emphasizes that tools for agents are not ordinary APIs; they are contracts between deterministic software and a non-deterministic agent. Tool names, descriptions, namespaces, return values, and token efficiency all affect whether the agent can use them reliably.  ￼

4. Permission and sandbox layer

This decides what the agent may do. A serious harness defines read/write boundaries, network access, secrets access, filesystem scope, approval gates, rollback ability, and safe execution environments.

This is where harness engineering overlaps with security engineering. The question is not “Can the model do X?” but “Can it do X only under conditions where X is safe, observable, reversible, and auditable?”

5. Workflow and orchestration layer

A harness may run a simple loop, a planner-executor flow, a state machine, a multi-agent team, or a CI-like pipeline.

Anthropic’s three-agent long-running harness separated Planner, Generator, and Evaluator. The planner expanded a short prompt into a structured spec; the generator built against sprint contracts; the evaluator tested behavior through Playwright and filed actionable issues. Their full harness cost more than a solo run but produced a much more functional result.  ￼

Stripe’s “Minions” are another production-style example: tasks can start from Slack threads, bug reports, or feature requests; “blueprints” combine deterministic code with flexible agent loops; output becomes a pull request for human review. InfoQ reports that Stripe’s system produces over 1,300 human-reviewed, AI-written pull requests per week.  ￼

6. Verification and feedback layer

This is the heart of harness engineering.

Martin Fowler’s article frames the harness as a combination of feedforward guides and feedback sensors. Guides steer the agent before it acts: specs, rules, architecture docs, skills, examples. Sensors inspect after it acts: tests, linters, type checkers, static analysis, logs, browser checks, code review agents, LLM judges, and human review.  ￼

He also distinguishes computational checks from inferential checks. Computational checks are deterministic and cheap: tests, linters, type checkers, structural rules. Inferential checks involve semantic judgment: AI review, LLM-as-judge, design critique, product-quality evaluation. The best harnesses use deterministic checks wherever possible and reserve LLM judgment for places where deterministic checks cannot capture the quality signal.  ￼

7. Observability and evaluation layer

A harness must record what happened: prompts, tool calls, files touched, test output, traces, intermediate decisions, final state, and whether the agent actually achieved the goal.

Anthropic’s agent-evaluation guide defines an agent harness as the system that lets a model act as an agent, and an evaluation harness as the infrastructure that runs tasks, records trajectories, grades outputs, and aggregates results. It also warns that agent evals should focus on final environment outcomes, not just what the agent says happened.  ￼

This matters because agents can confidently claim success while the environment says otherwise.

8. Governance and human-in-the-loop layer

A harness should know when to stop, escalate, or ask for human judgment. OpenAI’s Codex system, for example, evolved toward agents validating, fixing, opening PRs, responding to feedback, and escalating only when judgment is required; OpenAI also cautioned that such autonomy depended heavily on repository-specific structure and tooling.  ￼

Good harnesses do not remove humans. They move humans to higher-leverage work: defining intent, deciding tradeoffs, reviewing important outputs, encoding taste, and improving the environment when the agent fails.

The control-theory view

A harness is basically a governor for a stochastic worker.

It reduces the solution space before the model acts, then increases the evidence available after the model acts. In Fowler’s terms, it regulates maintainability, architecture fitness, and functional behavior through guides and sensors. Maintainability is easiest because we already have deterministic tools; functional behavior is harder because green tests, especially AI-generated tests, may not prove that the product actually does what the user wanted.  ￼

So the central harness-engineering loop is:

Observe failure
  → classify failure mode
  → add guide, tool, test, evaluator, permission, or workflow change
  → rerun agent
  → measure whether failure rate decreases
  → keep, tune, or delete the harness component

Hashimoto’s version is blunt and practical: when an agent makes a mistake, engineer the environment so it does not make that mistake again.  ￼

Common harness patterns

The “short map, deep docs” pattern. Use a tiny agent entrypoint that points to maintained, structured docs instead of stuffing everything into the prompt. OpenAI’s short AGENTS.md plus structured docs/ system is the clean example.  ￼

The “agent must prove it” pattern. Give the agent tools to run tests, reproduce bugs, inspect logs, capture screenshots, and verify behavior before it claims completion. Anthropic saw better web-app performance when Claude was explicitly given browser automation and asked to test as a human user would.  ￼

The “separate generator and evaluator” pattern. Do not rely on the same agent to produce work and grade it. Anthropic observed that agents tend to praise their own work; separating the evaluator from the generator gives the generator concrete external feedback to iterate against.  ￼

The “shift feedback left” pattern. Run cheap checks early: formatters, linters, type checks, unit tests, architectural constraints, pre-push hooks, and focused test selection. Fowler argues feedback sensors should be placed as early as possible in the change lifecycle.  ￼

The “garbage collector” pattern. Let agents periodically scan for drift, stale docs, inconsistent patterns, dead code, missing tests, or architecture violations, then open small cleanup PRs. OpenAI describes recurring background Codex tasks that scan for deviations, update quality grades, and open targeted refactoring PRs.  ￼

The “contract before code” pattern. Before writing, the agent and evaluator agree on what “done” means. Anthropic’s sprint contracts are a concrete example.  ￼

What can go wrong

The biggest failure is false confidence. A harness can make an agent look reliable while merely hiding fragility. Green tests may be shallow. LLM judges may be lenient. Generated documentation may drift. Tool outputs may be misleading. The agent may exploit an evaluation instead of solving the task.

Anthropic warns that agent evals are tricky because mistakes compound over many turns, agents modify environment state, and graders can be too rigid or unfair. They recommend clean isolated environments, thoughtful graders, transcript reading, and checking final outcomes rather than only trajectories.  ￼

Other common anti-patterns:

* A giant, stale instruction file.
* Vague tickets with no acceptance criteria.
* Letting the agent self-certify completion.
* Adding many agents before adding deterministic checks.
* No sandbox or permission design.
* No logs or reproducible traces.
* Treating AI-generated tests as enough.
* Optimizing for PR count instead of user-visible correctness.
* Building a harness that no one maintains.

Research frontier

Academically, harness engineering fits a broader move from “capability inside model weights” to externalized cognition: memory externalizes state, skills externalize procedures, protocols externalize interaction structure, and the harness coordinates these into governed execution. A 2026 arXiv survey frames harness engineering as part of this externalization trend.  ￼

Several recent preprints suggest that harness quality can materially change agent performance, though these results should be treated as early evidence rather than settled science. AutoHarness reports automatically synthesized code harnesses that prevented illegal moves across many TextArena games and let a smaller model outperform larger models in that setup. GTA-2 reports that advanced execution harnesses improve workflow completion, while frontier models still struggle on open-ended tasks. ClawEnvKit reports that harness engineering improved performance by up to 15.7 percentage points over a bare ReAct baseline across generated agent environments.  ￼

The frontier questions are:

* Can harnesses be automatically generated and verified?
* How do we measure “harness coverage” like we measure test coverage?
* Which parts should be deterministic code versus model calls?
* When do multiple agents help, and when do they just add noise?
* How do we prevent reward hacking and eval gaming?
* How do harnesses evolve as models improve?
* How much human judgment can be safely encoded into rules, tests, and evaluators?

How to build a basic harness

A practical starting recipe:

1. Pick a narrow task family. Do not start with “build anything.” Start with “fix this class of bug,” “write tests for this module,” “triage issues,” or “update docs after code changes.”
2. Write a structured task template. Include goal, scope, files, constraints, acceptance criteria, non-goals, and required proof.
3. Create a short agent entrypoint. Use AGENTS.md, CLAUDE.md, or equivalent as a map, not a textbook.
4. Move knowledge into maintained artifacts. Architecture docs, conventions, runbooks, design decisions, API references, test instructions, and examples should live where the agent can retrieve them.
5. Give the agent ergonomic tools. Prefer tools with clear names, narrow permissions, concise outputs, and actionable error messages.
6. Add deterministic checks first. Formatters, linters, type checks, unit tests, integration tests, architectural rules, static analysis, and reproducible scripts are usually cheaper and more reliable than AI review.
7. Add inferential checks where needed. Use LLM judges or evaluator agents for design quality, semantic duplication, product fit, readability, or requirement interpretation, but calibrate them against human judgment.
8. Require evidence before completion. The agent should show test output, screenshots, logs, diffs, reproduced bug/fix evidence, or final environment state.
9. Log trajectories. Store enough traces to debug failures: prompts, tool calls, test results, files changed, final outputs, and evaluator notes.
10. Convert repeated failures into harness changes. Every recurring failure should become a better doc, better test, better tool, better permission rule, or better workflow.

What skills “harness engineers” need

Harness engineering sits at the intersection of:

* software engineering and system design
* DevOps, CI/CD, and observability
* security and permissions
* test engineering and evaluation design
* product specification and acceptance criteria
* prompt and context engineering
* tool/API design for agents
* retrieval and memory systems
* human factors: knowing where human judgment is still essential

The strongest harness engineers are not merely “good prompt writers.” They are people who can turn tacit engineering judgment into durable infrastructure.

Bottom line

Harness Engineering is the shift from asking AI to do work to building the world in which AI can do work reliably.

For simple tasks, a prompt may be enough. For multi-step, tool-using, production-grade agents, the harness becomes the product: it encodes context, tools, tests, permissions, memory, feedback, evaluation, and human judgment. Better models matter, but in real systems the difference between a demo and a dependable agent is often the quality of the harness around the model.