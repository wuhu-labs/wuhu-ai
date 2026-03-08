import Foundation

/// Events emitted by the agent loop for observation.
///
/// Committed actions advance the persisted state. Stream events are
/// ephemeral — they are not persisted and do not advance the stable
/// version.
public enum AgentLoopEvent<CommittedAction: Sendable, StreamAction: Sendable>: Sendable {
  /// A persisted mutation was applied to state.
  case committed(CommittedAction)

  /// Inference streaming has begun.
  case streamBegan

  /// An ephemeral streaming delta.
  case streamDelta(StreamAction)

  /// Inference streaming has ended.
  case streamEnded
}

/// Gap-free observation of the agent loop's state and events.
///
/// Returned by ``AgentLoop/observe()``. The state snapshot and event
/// stream are registered atomically — no events are missed between
/// the snapshot and the first event on the stream.
public struct AgentLoopObservation<B: AgentBehavior>: Sendable {
  /// Current committed state at the time of observation.
  public var state: B.State

  /// Accumulated stream deltas if inference is in progress, nil
  /// otherwise.
  public var inflight: [B.StreamAction]?

  /// Live event stream from the point of observation.
  public var events: AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>

  public init(
    state: B.State,
    inflight: [B.StreamAction]?,
    events: AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>
  ) {
    self.state = state
    self.inflight = inflight
    self.events = events
  }
}
