import Foundation

// MARK: - Tool Call Resolution

/// Whether a tool call is being executed fresh or resolved from a
/// previous loop lifetime.
///
/// The loop passes this to ``AgentBehavior/executeToolCall(_:sink:resolution:)``
/// so the behavior can decide the strategy:
///
/// - `.fresh`: Normal execution. Start the tool, run it, return result.
/// - `.fromPreviousLifetime`: The loop restarted and found this tool
///   call in-progress. The behavior may reconnect to an external
///   executor, inject an error, or return cached partial output.
public enum ToolCallResolution: Sendable, Hashable {
  /// A new tool call from the current inference turn.
  case fresh

  /// A tool call that was in-progress when the previous loop lifetime
  /// ended (process crash, restart, etc.).
  case fromPreviousLifetime
}

// MARK: - Tool Call Status

/// Status of a tool call in the execution lifecycle.
///
/// The loop does not interpret these values — they exist for the
/// behavior's persistence and crash recovery logic.
public enum ToolCallStatus: String, Sendable, Hashable, Codable {
  case pending
  case started
  case completed
  case errored
}

// MARK: - Tool Action Sink

/// Push-based channel for tool calls to emit committed actions
/// mid-execution.
///
/// When a tool call needs to persist intermediate state (e.g., bash
/// checkpointing partial output, mount recording state changes), it
/// emits actions through the sink. Each action is serialized and
/// applied to loop state before the `emit` call returns.
///
/// Most tools ignore the sink entirely — they just return a result.
///
/// ## Example: Checkpointing a long bash execution
///
///     func executeToolCall(_ call: ToolCall, sink: ToolActionSink<Action>, ...) async throws -> Result {
///         let process = try await startBash(call)
///         var output = ""
///         for await chunk in process.output {
///             output += chunk
///             if shouldCheckpoint(output) {
///                 await sink.emit(.toolCallCheckpointed(id: call.id, output: output))
///             }
///         }
///         return formatResult(output, exitCode: process.exitCode)
///     }
///
/// ## Example: Mount producing state changes
///
///     func executeToolCall(_ call: ToolCall, sink: ToolActionSink<Action>, ...) async throws -> Result {
///         let mount = try await createMount(call)
///         await sink.emit(.mountAdded(mount))
///         if mount.isPrimary {
///             await sink.emit(.primaryMountChanged(mount.id))
///         }
///         return AgentToolResult(content: [.text("Mounted at \(mount.path)")])
///     }
public struct ToolActionSink<Action: Sendable>: Sendable {
  private let _emit: @Sendable (Action) async -> Void

  public init(emit: @escaping @Sendable (Action) async -> Void) {
    _emit = emit
  }

  /// Emit a committed action. Blocks until the action has been
  /// serialized and applied to loop state.
  public func emit(_ action: Action) async {
    await _emit(action)
  }

  /// A sink that discards all actions. Useful for tests and for
  /// tool calls that don't need intermediate actions.
  public static var discard: ToolActionSink<Action> {
    ToolActionSink { _ in }
  }
}

// MARK: - Stream Sink

/// Push-based sink for streaming inference deltas into the loop's
/// event stream.
///
/// The behavior yields stream actions during inference. The loop
/// forwards them as ``AgentLoopEvent/streamDelta(_:)`` events to
/// observers.
public struct AgentStreamSink<Action: Sendable>: Sendable {
  public let yield: @Sendable (Action) -> Void

  public init(yield: @escaping @Sendable (Action) -> Void) {
    self.yield = yield
  }
}
