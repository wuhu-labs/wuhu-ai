import Synchronization

/// A simple Sendable store for test behaviors.
/// Wraps mutable state behind `Mutex` so it can be used from any
/// context (sync or async, any actor, any thread).
///
/// This is test infrastructure only — production behaviors should
/// use proper persistence.
final class TestStore<State: Sendable>: @unchecked Sendable {
  private let storage: Mutex<State>

  init(_ initial: State) {
    storage = Mutex(initial)
  }

  /// Read the current state (by copy).
  var value: State {
    storage.withLock { state in
      let copy = state
      return copy
    }
  }

  /// Mutate the state and return a derived value.
  @discardableResult
  func withLock<T: Sendable>(_ body: (inout State) -> T) -> T {
    storage.withLock { state in
      body(&state)
    }
  }
}
