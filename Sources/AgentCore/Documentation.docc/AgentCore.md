# ``AgentCore``

A generic, infrastructure-free agent loop runtime.

## Overview

AgentCore provides a single-actor event loop that orchestrates the
**drain → infer → tools → compact** cycle of an AI agent. All domain-specific
logic — persistence, tool implementations, LLM calls — lives on an
``AgentBehavior`` conformance that you provide. The loop handles only
**when** to call your code, and **safely** (serialization, observation,
repetition detection).

### Design Principles

- **Generic.** No database, no HTTP client, no file system. Depends only
  on PiAI types for the LLM protocol boundary.
- **Persist-first.** Every mutation goes through ``AgentLoop/serialized(_:)``:
  persist to storage, return actions, apply to memory. If the process
  crashes between persist and apply, `loadState()` rebuilds consistently.
- **Unified crash recovery.** There is no special "stale" or "resume"
  codepath. On startup the loop asks for
  ``AgentBehavior/unresolvedToolCalls(in:)`` and re-executes them through
  the same ``AgentBehavior/executeToolCall(_:sink:resolution:)`` path,
  with `.fromPreviousLifetime` resolution. The behavior decides per-tool
  whether to reconnect, error, or return cached output.
- **Observable.** ``AgentLoop/observe()`` returns a gap-free
  `(state, stream)` pair. No events are missed between the snapshot and
  the first stream event.
- **Testable.** The examples in this package prove the contract with
  in-memory behaviors and mock inference — no infrastructure required.

## Topics

### Essentials

- ``AgentLoop``
- ``AgentBehavior``

### Tool Execution

- ``ToolActionSink``
- ``ToolCallResolution``
- ``ToolCallStatus``
- ``ToolCallRepetitionTracker``

### Observation

- ``AgentLoopObservation``
- ``AgentLoopEvent``
- ``AgentStreamSink``

### Errors

- ``AgentLoopError``
