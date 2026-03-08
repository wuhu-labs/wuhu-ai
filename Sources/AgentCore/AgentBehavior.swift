import Foundation
import PiAI

// MARK: - Agent Behavior

/// Domain-specific behavior that drives an ``AgentLoop``.
///
/// Owns persistence, inference, tool execution, and drain logic.
/// All IO methods persist their effects and return **actions** describing
/// what changed. The loop applies actions to in-memory state via
/// ``apply(_:to:)`` and emits them as observation events.
///
/// ## Invariant
///
/// For every IO method that returns actions:
///
///     var state = /* current state */
///     let actions = try await behavior.someMethod(state: state)
///     for action in actions { behavior.apply(action, to: &state) }
///     let reloaded = try await behavior.loadState()
///     assert(state == reloaded)
///
/// The in-memory state after applying actions must equal a fresh load
/// from the persistence layer. This **free test** verifies persistence,
/// action generation, and the reducer in one assertion.
///
/// ## Persist First
///
/// One rule: **persist to storage, then return actions.** If the process
/// crashes between the persist and the apply, the storage is consistent
/// and the state is rebuilt on next load via ``loadState()``.
///
/// ## Tool Execution Model
///
/// Tool calls receive a ``ToolActionSink`` through which they can emit
/// committed actions mid-execution. This enables:
///
/// - **Checkpointing**: long-running tools (e.g., bash) can persist
///   partial output periodically, surviving process crashes.
/// - **Side effects as actions**: tools that modify session state
///   (e.g., mount) can produce committed actions that flow through
///   the normal observation pipeline.
///
/// Tools that don't need intermediate actions simply ignore the sink.
///
/// The ``ToolCallResolution`` parameter tells the behavior whether a
/// tool call is fresh (just issued by the model) or unresolved from a
/// previous loop lifetime (e.g., after a process restart). The behavior
/// decides the strategy: start a new execution, reconnect to an
/// external executor, or inject an error result.
public protocol AgentBehavior: Sendable {
  // MARK: Associated Types

  /// Full state held by the loop.
  ///
  /// The loop treats state as an opaque value — it is owned and evolved
  /// by the behavior via ``apply(_:to:)``. The state must be equatable
  /// to support observation snapshots and invariant checks.
  associatedtype State: Sendable & Equatable

  /// Describes a persisted mutation. Applied to state by
  /// ``apply(_:to:)``, then emitted to observers.
  associatedtype CommittedAction: Sendable

  /// Describes an ephemeral streaming update (inference text delta,
  /// etc.). Not persisted, not applied to committed state.
  associatedtype StreamAction: Sendable

  /// Domain-specific commands from outside the loop (enqueue, cancel,
  /// change model, etc.).
  associatedtype ExternalAction: Sendable

  /// The result of executing a tool. Opaque to the loop — it just
  /// passes the value from ``executeToolCall(_:sink:resolution:)``
  /// to ``toolDidExecute(_:result:state:)``.
  ///
  /// `Hashable` is required so the loop can detect consecutive
  /// identical tool results (see ``ToolCallRepetitionTracker``).
  associatedtype ToolResult: Sendable & Hashable

  // MARK: State Management

  /// Placeholder state used before ``loadState()`` runs.
  ///
  /// The loop initializes synchronously, but real state is loaded
  /// async at startup. This value should be cheap and deterministic.
  static var emptyState: State { get }

  /// Load full state from the persistence layer. Called once on startup.
  func loadState() async throws -> State

  /// Pure reducer. Apply a committed action to in-memory state.
  ///
  /// - Important: Must be synchronous — no IO, no suspension.
  func apply(_ action: CommittedAction, to state: inout State)

  // MARK: External Actions

  /// Handle a command from outside the loop.
  ///
  /// Persists the effect and returns actions. For example, an enqueue
  /// command persists the queue item and returns actions that update
  /// in-memory queue state.
  func handle(_ action: ExternalAction, state: State) async throws -> [CommittedAction]

  // MARK: Drain

  /// Atomically drain interrupt-priority items and write them to the
  /// transcript. Returns actions describing what was drained.
  ///
  /// Called at the **interrupt checkpoint** — after tool results are
  /// collected, before next inference.
  func drainInterruptItems(state: State) async throws -> [CommittedAction]

  /// Atomically drain turn-boundary items and write them to the
  /// transcript. Returns actions describing what was drained.
  ///
  /// Called at the **turn boundary** — the agent would otherwise go idle.
  func drainTurnItems(state: State) async throws -> [CommittedAction]

  // MARK: Inference

  /// Project current state into LLM input context.
  ///
  /// Pure function of state — no IO.
  func buildContext(state: State) -> Context

  /// Run inference. Yields streaming deltas to `stream` during
  /// execution.
  ///
  /// This is the only IO operation that is **not** persisted before
  /// returning. If the process crashes during inference, the loop
  /// retries on restart.
  ///
  /// The behavior may suspend here for domain-specific reasons
  /// (e.g., cost budget approval) before calling the LLM. From the
  /// loop's perspective, `infer` is an opaque async call — the loop
  /// does not distinguish between "waiting for approval" and "waiting
  /// for the LLM."
  func infer(
    context: Context,
    stream: AgentStreamSink<StreamAction>
  ) async throws -> AssistantMessage

  // MARK: Persist Inference Results

  /// Persist the assistant's response and return actions.
  func persistAssistantEntry(
    _ message: AssistantMessage,
    state: State
  ) async throws -> [CommittedAction]

  // MARK: Tool Lifecycle

  /// Record that a tool call is about to execute.
  ///
  /// Persists the status change for crash recovery: on restart,
  /// tool calls marked as started but not completed appear in
  /// ``unresolvedToolCallIDs(in:)``.
  func toolWillExecute(
    _ call: ToolCall,
    state: State
  ) async throws -> [CommittedAction]

  /// Execute a tool call.
  ///
  /// Runs outside the serialized path (parallel with other tool calls).
  ///
  /// - Parameters:
  ///   - call: The tool call from the assistant message.
  ///   - sink: A channel for emitting committed actions mid-execution.
  ///     Each emitted action is serialized and applied to loop state
  ///     before the next emission. Most tools ignore this.
  ///   - resolution: Whether this is a fresh call or one being resolved
  ///     from a previous loop lifetime. See ``ToolCallResolution``.
  func executeToolCall(
    _ call: ToolCall,
    sink: ToolActionSink<CommittedAction>,
    resolution: ToolCallResolution
  ) async throws -> ToolResult

  /// Append supplementary text to a tool result.
  ///
  /// Used by the loop to inject repetition warnings into results
  /// without knowing the concrete result type.
  func appendText(_ text: String, to result: ToolResult) -> ToolResult

  /// Persist a tool result and return actions.
  func toolDidExecute(
    _ call: ToolCall,
    result: ToolResult,
    state: State
  ) async throws -> [CommittedAction]

  /// Persist an error for a tool call that threw during execution.
  func toolDidFail(
    _ call: ToolCall,
    error: any Error,
    state: State
  ) async throws -> [CommittedAction]

  // MARK: Compaction

  /// Whether compaction should run after this inference.
  func shouldCompact(state: State) -> Bool

  /// Perform compaction and return actions.
  func performCompaction(state: State) async throws -> [CommittedAction]

  // MARK: Unresolved Tool Calls

  /// Tool call IDs that are in-progress from a previous loop lifetime.
  ///
  /// Called once on startup after ``loadState()``. The loop passes
  /// each ID to ``executeToolCall(_:sink:resolution:)`` with
  /// resolution `.fromPreviousLifetime`. The behavior decides the
  /// strategy per tool:
  ///
  /// - Reconnect to an external executor that outlived the loop
  /// - Inject an error result ("tool result was lost")
  /// - Return cached partial output
  ///
  /// Returns `(id, call)` pairs. The call is needed so the loop can
  /// pass it to ``toolWillExecute(_:state:)`` and
  /// ``toolDidExecute(_:result:state:)`` / ``toolDidFail(_:error:state:)``.
  func unresolvedToolCalls(in state: State) -> [(id: String, call: ToolCall)]

  // MARK: Cold Start

  /// Whether the loaded state has pending work.
  func hasWork(state: State) -> Bool

  /// Whether the transcript is mid-turn and needs an inference call.
  ///
  /// Called at the top of the run loop to detect a state where the
  /// transcript ends with a tool result or user message that the
  /// model has not yet responded to. This happens when a prior
  /// inference attempt failed and the loop restarted.
  ///
  /// Default implementation returns `false`.
  func needsInference(state: State) -> Bool
}

// MARK: - Default Implementations

public extension AgentBehavior {
  func needsInference(state _: State) -> Bool {
    false
  }
}
