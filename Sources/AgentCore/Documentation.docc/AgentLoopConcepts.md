# The Agent Loop

Understanding the drain → infer → tools → compact cycle.

## Overview

The agent loop is a state machine driven by two inputs:

1. **External actions** via ``AgentLoop/send(_:)`` — user messages,
   steers, cost approvals, etc.
2. **Internal wakeups** — after external actions are processed, the
   loop checks if there is work to do.

Each iteration of the loop performs:

```
while not idle:
  1. Drain interrupt items (steers, follow-ups)
  2. Drain turn items (new user messages)
  3. Infer (call LLM, stream response)
  4. Persist assistant entry
  5. Execute tool calls (if any)
  6. Compact (if threshold met)
```

### Serialization

Swift actors re-enter at every `await`. The loop uses **task-chaining**
to ensure mutations are applied atomically:

```swift
try await serialized { state in
  // 1. Read current state (passed by value)
  // 2. Do async IO (persist)
  // 3. Return actions
  // Actions are applied to memory and emitted to observers
}
```

Each `serialized` block runs to completion before the next begins.
This is how we achieve linearizable state transitions without locks.

### Tool Execution

Tool calls run **outside** serialization so the loop stays responsive
to ``AgentLoop/send(_:)`` during long-running tools. Each tool call
receives a ``ToolActionSink`` that feeds actions back through the
serialized path. This allows tools to checkpoint intermediate state
(e.g., bash output lines) without blocking other mutations.

### Crash Recovery

On startup, ``AgentLoop/start()`` calls ``AgentBehavior/loadState()``
to rebuild state from persistence. Then it checks
``AgentBehavior/unresolvedToolCalls(in:)`` — tool calls that were
started but never completed. Each unresolved call is passed through
the same ``AgentBehavior/executeToolCall(_:sink:resolution:)`` with
`.fromPreviousLifetime`. The behavior decides the strategy:

| Strategy | When | How |
|----------|------|-----|
| Error | Process died, tool is unrecoverable | Throw an error describing partial output |
| Resume | External process still running (e.g., bash server) | Reconnect to the running process |
| Cache | Tool was synchronous, result already persisted | Return the cached result |

### Repetition Detection

The ``ToolCallRepetitionTracker`` detects degenerate loops where the
model calls the same tool with the same arguments and gets the same
result repeatedly. After 3 identical results, a warning is appended.
After 5, the tool is blocked and an error message forces the model
to try something different.

### Observation

``AgentLoop/observe()`` returns a gap-free observation: a state
snapshot + live event stream. The registration is atomic with respect
to state mutations, so no events are missed.

Events include:
- `.committed(action)` — a persisted state change
- `.streamBegan` / `.streamDelta` / `.streamEnded` — inference streaming

### Interruptible Tools

The loop does not have a built-in interrupt mechanism for tools.
Instead, the behavior wires interrupts internally:

1. `handle(.steer)` fires an interrupt signal
2. The tool races between its work and the signal
3. The tool returns a normal result (early or not)
4. The loop sees a normal tool completion

This keeps the loop generic while allowing sophisticated patterns
like the `join_sessions` / `async_bash_status` tools in Wuhu.

### Cost Gating

Similarly, cost gating needs no loop changes. The behavior's
`infer()` method checks the budget, suspends on a gate if needed,
and resumes when an external `.approveCost` action fires through
``AgentLoop/send(_:)``. The loop's actor remains responsive during
the suspension because `send()` goes through the serialized path
which can execute while `infer()` awaits.

## See Also

- ``AgentLoop``
- ``AgentBehavior``
