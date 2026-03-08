/// A simple Sendable store for test behaviors.
/// Wraps mutable state behind actor isolation so it can be used
/// from any async context.
///
/// This is test infrastructure only — production behaviors should
/// use proper persistence.
actor TestStore<State: Sendable> {
  private var storage: State

  init(_ initial: State) {
    storage = initial
  }

  /// Read the current state (by copy).
  var value: State { storage }

  /// Mutate the state and return a derived value.
  @discardableResult
  func withLock<T: Sendable>(_ body: (inout State) -> T) -> T {
    body(&storage)
  }
}
