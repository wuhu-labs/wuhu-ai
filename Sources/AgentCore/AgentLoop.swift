import Foundation
import PiAI

/// Generic agent loop runtime, parameterized by an ``AgentBehavior``.
///
/// Owns in-memory state, serializes mutations, orchestrates the
/// drain → infer → tools → compact cycle. All domain-specific logic
/// lives on the behavior — the loop handles only **when** and **safely**.
///
/// ## Lifecycle
///
/// Call ``start()`` exactly once. It blocks for the session's lifetime,
/// waiting for signals to drive the loop. Cancel the task running
/// `start()` to tear down.
///
/// ## Observation
///
/// Call ``observe()`` to get a gap-free `(state, stream)` pair.
/// External commands go through ``send(_:)``.
///
/// ## Serialization
///
/// Swift actors re-enter at every `await`. For mutations that span an
/// `await` (persist, then apply), actor isolation alone is not sufficient.
///
/// The loop uses task-chaining: each ``serialized(_:)`` block passes
/// the current state (by value) to a work closure. The closure does IO
/// and returns actions. The loop applies the actions and emits them.
/// Each block runs to completion before the next starts.
///
/// Long-running IO — inference and tool execution — runs **outside**
/// serialization so the loop stays responsive. External commands via
/// ``send(_:)`` go through the same serialized chain.
///
/// ## Persist First
///
/// One rule: **persist to storage, then return actions, then apply to
/// memory.** If the process crashes between the persist and the apply,
/// the storage is consistent and the state is rebuilt on next load via
/// ``AgentBehavior/loadState()``.
///
/// There is no special crash recovery codepath. The loop's normal
/// sequence — resolve unresolved tool calls, drain, infer — handles all
/// states identically.
public actor AgentLoop<B: AgentBehavior> {
  // MARK: Dependencies

  public nonisolated let behavior: B

  // MARK: State

  public private(set) var state: B.State
  private var inflight: [B.StreamAction]?

  // MARK: Serialization

  /// Task chain tail for ``serialized(_:)``. Do not touch directly.
  private var _tail: Task<Void, Never>?

  // MARK: Lifecycle

  private var started = false
  private var signal: AsyncStream<Void>.Continuation?

  // MARK: Observation

  private var observers: [UUID: AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>.Continuation] = [:]

  // MARK: Tool Call Repetition

  private var repetitionTracker = ToolCallRepetitionTracker()

  // MARK: Init

  public init(behavior: B) {
    self.behavior = behavior
    state = B.emptyState
  }

  // MARK: - Observation

  /// Observe the loop's state and events, gap-free.
  ///
  /// The snapshot and stream registration are atomic (no events are
  /// missed between the snapshot and the first stream event).
  public func observe() -> AgentLoopObservation<B> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { [weak self] in await self?.removeObserver(id) }
    }
    return AgentLoopObservation(state: state, inflight: inflight, events: stream)
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }

  // MARK: - External Actions

  /// Send a domain-specific command into the loop.
  ///
  /// The behavior persists the effect and returns actions, which are
  /// applied to state and emitted to observers. The loop is woken
  /// afterward in case new work was enqueued.
  public func send(_ action: B.ExternalAction) async throws {
    try await serialized { [behavior] state in
      try await behavior.handle(action, state: state)
    }
    signal?.yield(())
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started, "AgentLoop.start() called more than once")
    started = true
    defer { started = false }

    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    signal = continuation

    state = try await behavior.loadState()

    if behavior.hasWork(state: state) {
      signal?.yield(())
    }

    for await _ in stream {
      try await runUntilIdle()
    }
  }

  // MARK: - Serialization

  /// Serialize a mutation: pass current state (by value) to the work
  /// closure, which does IO and returns actions. Actions are applied
  /// to state and emitted, atomically with respect to other serialized
  /// blocks.
  ///
  /// - Important: Work closures must not call ``serialized(_:)``
  ///   (deadlock).
  @discardableResult
  private func serialized(
    _ work: @escaping @Sendable (B.State) async throws -> [B.CommittedAction]
  ) async throws -> [B.CommittedAction] {
    let previous = _tail
    return try await withCheckedThrowingContinuation { cont in
      _tail = Task {
        _ = await previous?.result
        do {
          let actions = try await work(self.state)
          for action in actions {
            self.behavior.apply(action, to: &self.state)
          }
          self.emitCommitted(actions)
          cont.resume(returning: actions)
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Agent Loop

  /// Run the loop until idle:
  /// resolve unresolved → (drain → infer → tools → compact)*
  private func runUntilIdle() async throws {
    var hasToolResults = try await resolveUnresolvedToolCalls()

    // Detect mid-turn state from a prior crash/restart: the transcript
    // ends with a tool result or user message that the model never
    // responded to.
    if !hasToolResults, behavior.needsInference(state: state) {
      hasToolResults = true
    }

    while !Task.isCancelled {
      // Interrupt checkpoint
      let interruptActions = try await serialized { [behavior] state in
        try await behavior.drainInterruptItems(state: state)
      }

      // Reset repetition tracker when user messages arrive.
      if !interruptActions.isEmpty {
        repetitionTracker.reset()
      }

      if interruptActions.isEmpty, !hasToolResults {
        // No interrupt work. Check turn boundary.
        let turnActions = try await serialized { [behavior] state in
          try await behavior.drainTurnItems(state: state)
        }
        if turnActions.isEmpty { break } // truly idle
      }

      hasToolResults = false

      // Inference (with retry for transient errors)
      let context = behavior.buildContext(state: state)
      let message = try await performInferenceWithRetry(context: context)

      // Persist assistant entry
      try await serialized { [behavior] state in
        try await behavior.persistAssistantEntry(message, state: state)
      }

      // Tool calls
      let toolCalls = message.content.compactMap { block -> ToolCall? in
        if case let .toolCall(call) = block { return call }
        return nil
      }

      if !toolCalls.isEmpty {
        try await executeToolCalls(toolCalls)
        hasToolResults = true
      }

      // Compaction
      if behavior.shouldCompact(state: state) {
        try await serialized { [behavior] state in
          try await behavior.performCompaction(state: state)
        }
      }
    }
  }

  // MARK: - Inference (with streaming + retry)

  /// Maximum number of retry attempts for transient inference errors.
  private static var maxInferenceRetries: Int { 10 }

  /// Retry inference with exponential backoff for transient errors.
  ///
  /// Retries up to ``maxInferenceRetries`` times. Each retry waits
  /// `base * 2^attempt` seconds (1, 2, 4, 8, …) capped at 60s,
  /// with ±25 % jitter. Cancellation breaks the retry loop
  /// immediately via `CancellationError`.
  private func performInferenceWithRetry(context: Context) async throws -> AssistantMessage {
    var lastError: (any Error)?
    for attempt in 0 ... Self.maxInferenceRetries {
      if attempt > 0 {
        let delay = min(pow(2, Double(attempt - 1)), 60)
        let jitter = delay * Double.random(in: -0.25 ... 0.25)
        let total = UInt64((delay + jitter) * 1_000_000_000)
        try await Task.sleep(nanoseconds: total)
      }

      do {
        return try await performInference(context: context)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        guard Self.isTransientError(error) else { throw error }
      }
    }
    throw lastError ?? AgentLoopError.inferenceProducedNoResult
  }

  /// Whether an error is transient and worth retrying.
  private nonisolated static func isTransientError(_ error: any Error) -> Bool {
    if let piError = error as? PiAIError,
       case let .httpStatus(code, _) = piError
    {
      return code == 429 || code == 500 || code == 502 || code == 503 || code == 529
    }

    let description = String(describing: error)
    if description.contains("remoteConnectionClosed")
      || description.contains("connectTimeout")
      || description.contains("readTimeout")
    {
      return true
    }

    return false
  }

  private func performInference(context: Context) async throws -> AssistantMessage {
    emit(.streamBegan)
    inflight = []

    defer {
      inflight = nil
      emit(.streamEnded)
    }

    let (deltaStream, deltaContinuation) = AsyncStream<B.StreamAction>.makeStream()
    let sink = AgentStreamSink<B.StreamAction> { deltaContinuation.yield($0) }

    return try await withThrowingTaskGroup(of: AssistantMessage?.self) { group in
      group.addTask { [behavior] in
        defer { deltaContinuation.finish() }
        return try await behavior.infer(context: context, stream: sink)
      }

      for await delta in deltaStream {
        inflight?.append(delta)
        emit(.streamDelta(delta))
      }

      guard let message = try await group.next() ?? nil else {
        throw AgentLoopError.inferenceProducedNoResult
      }
      return message
    }
  }

  // MARK: - Unresolved Tool Calls

  /// Resolve tool calls from a previous loop lifetime.
  ///
  /// Each unresolved call is passed to the behavior's
  /// ``AgentBehavior/executeToolCall(_:sink:resolution:)`` with
  /// `.fromPreviousLifetime`. The behavior decides per tool whether
  /// to reconnect, error, or return cached output.
  private func resolveUnresolvedToolCalls() async throws -> Bool {
    let unresolved = behavior.unresolvedToolCalls(in: state)
    guard !unresolved.isEmpty else { return false }

    // Run them through the same execution path as fresh tool calls.
    let calls = unresolved.map(\.call)

    // Mark started (they may already be, but idempotent).
    for call in calls {
      try await serialized { [behavior] state in
        try await behavior.toolWillExecute(call, state: state)
      }
    }

    // Execute with .fromPreviousLifetime resolution.
    let results = await executeToolCallsParallel(calls, resolution: .fromPreviousLifetime)

    // Record results.
    for (call, result) in results {
      try await recordToolResult(call: call, result: result)
    }

    return true
  }

  // MARK: - Tool Execution

  /// Execute tool calls: mark started → run in parallel → record results.
  ///
  /// Integrates ``ToolCallRepetitionTracker`` to detect and break
  /// degenerate loops where the model calls the same tool with the
  /// same arguments and gets the same result repeatedly.
  private func executeToolCalls(_ calls: [ToolCall]) async throws {
    // Partition into blocked vs. allowed based on repetition history.
    var blocked: [ToolCall] = []
    var allowed: [ToolCall] = []
    for call in calls {
      let argsHash = call.arguments.hashValue
      let count = repetitionTracker.preflightCount(toolName: call.name, argsHash: argsHash)
      if count >= ToolCallRepetitionTracker.blockThreshold {
        blocked.append(call)
      } else {
        allowed.append(call)
      }
    }

    // Mark all as started.
    for call in calls {
      try await serialized { [behavior] state in
        try await behavior.toolWillExecute(call, state: state)
      }
    }

    // Record blocked calls as errors immediately.
    for call in blocked {
      let error = ToolCallRepetitionError.blocked
      try await serialized { [behavior] state in
        try await behavior.toolDidFail(call, error: error, state: state)
      }
    }

    // Execute allowed calls in parallel.
    let results = await executeToolCallsParallel(allowed, resolution: .fresh)

    // Record results with repetition tracking.
    for (call, result) in results {
      try await recordToolResult(call: call, result: result)
    }
  }

  /// Run tool calls in parallel, each with its own action sink.
  private func executeToolCallsParallel(
    _ calls: [ToolCall],
    resolution: ToolCallResolution
  ) async -> [(ToolCall, Result<B.ToolResult, any Error>)] {
    // Build sinks on-actor so each closure captures a Sendable
    // reference (the actor itself) rather than a mutable `self`.
    let sinks: [String: ToolActionSink<B.CommittedAction>] = {
      var result: [String: ToolActionSink<B.CommittedAction>] = [:]
      for call in calls {
        let loopRef = self
        result[call.id] = ToolActionSink<B.CommittedAction> { action in
          _ = try? await loopRef.commitSingleAction(action)
        }
      }
      return result
    }()

    return await withTaskGroup(
      of: (ToolCall, Result<B.ToolResult, any Error>).self
    ) { [behavior] group in
      for call in calls {
        let sink = sinks[call.id] ?? .discard
        group.addTask {
          do {
            let result = try await behavior.executeToolCall(call, sink: sink, resolution: resolution)
            return (call, .success(result))
          } catch {
            return (call, .failure(error))
          }
        }
      }
      var outputs: [(ToolCall, Result<B.ToolResult, any Error>)] = []
      for await output in group {
        outputs.append(output)
      }
      return outputs
    }
  }

  /// Commit a single action through the serialized path.
  /// Used by tool action sinks to feed actions back into the loop.
  private func commitSingleAction(_ action: B.CommittedAction) async throws {
    try await serialized { _ in [action] }
  }

  /// Record a tool call result: update repetition tracking, inject
  /// warnings, persist via behavior.
  private func recordToolResult(
    call: ToolCall,
    result: Result<B.ToolResult, any Error>
  ) async throws {
    switch result {
    case let .success(toolResult):
      let argsHash = call.arguments.hashValue
      let resultHash = toolResult.hashValue
      let count = repetitionTracker.record(
        toolName: call.name,
        argsHash: argsHash,
        resultHash: resultHash
      )
      let finalResult: B.ToolResult = if count >= ToolCallRepetitionTracker.warningThreshold {
        behavior.appendText(ToolCallRepetitionTracker.warningText, to: toolResult)
      } else {
        toolResult
      }
      try await serialized { [behavior] state in
        try await behavior.toolDidExecute(call, result: finalResult, state: state)
      }

    case let .failure(error):
      let argsHash = call.arguments.hashValue
      let errorHash = String(describing: error).hashValue
      repetitionTracker.record(
        toolName: call.name,
        argsHash: argsHash,
        resultHash: errorHash
      )
      try await serialized { [behavior] state in
        try await behavior.toolDidFail(call, error: error, state: state)
      }
    }
  }

  // MARK: - Emit

  private func emit(_ event: AgentLoopEvent<B.CommittedAction, B.StreamAction>) {
    for (_, continuation) in observers {
      continuation.yield(event)
    }
  }

  private func emitCommitted(_ actions: [B.CommittedAction]) {
    for action in actions {
      emit(.committed(action))
    }
  }
}

// MARK: - Errors

public enum AgentLoopError: Error, Sendable {
  case inferenceProducedNoResult
}

/// Error returned when a tool call is blocked by
/// ``ToolCallRepetitionTracker``.
enum ToolCallRepetitionError: Error, CustomStringConvertible {
  case blocked

  var description: String {
    ToolCallRepetitionTracker.blockText
  }
}
