import EffectLoops
import Testing

// MARK: - Effect Tests

@Suite("Effect")
struct EffectTests {
  @Test func sendEffect() async {
    enum Action: Sendable { case ping, pong }

    struct PingPong: LoopBehavior {
      func reduce(state: inout [Action], action: Action) {
        state.append(action)
      }

      func nextEffect(state: inout [Action]) -> Effect<Action>? {
        nil
      }
    }

    let loop = EffectLoop(behavior: PingPong(), initialState: [])
    let task = Task { await loop.start() }

    await loop.send(.ping)
    await loop.send(.pong)

    // Give the loop a moment to process.
    try? await Task.sleep(nanoseconds: 50_000_000)

    let state = await loop.state
    task.cancel()

    #expect(state == [.ping, .pong])
  }

  @Test func asyncEffectSendsBack() async {
    enum Action: Sendable, Equatable { case start, finished(Int) }

    struct State: Sendable {
      var started = false
      var result: Int?
    }

    struct Compute: LoopBehavior {
      func reduce(state: inout State, action: Action) {
        switch action {
        case .start:
          state.started = true
        case let .finished(n):
          state.result = n
          state.started = false
        }
      }

      func nextEffect(state: inout State) -> Effect<Action>? {
        guard state.started, state.result == nil else { return nil }
        state.started = false // guard token: don't re-issue
        return Effect { send in
          await send(.finished(42))
        }
      }
    }

    let loop = EffectLoop(behavior: Compute(), initialState: State())
    let task = Task { await loop.start() }

    await loop.send(.start)

    try? await Task.sleep(nanoseconds: 100_000_000)

    let state = await loop.state
    task.cancel()

    #expect(state.result == 42)
  }

  @Test func subscribeSeesActions() async {
    enum Action: Sendable, Equatable { case a, b }

    struct Pass: LoopBehavior {
      func reduce(state: inout Int, action: Action) {
        state += 1
      }

      func nextEffect(state: inout Int) -> Effect<Action>? { nil }
    }

    let loop = EffectLoop(behavior: Pass(), initialState: 0)
    let (initialState, actions) = await loop.subscribe()
    #expect(initialState == 0)

    let task = Task { await loop.start() }

    await loop.send(.a)
    await loop.send(.b)

    var collected: [Action] = []
    for await action in actions {
      collected.append(action)
      if collected.count == 2 { break }
    }

    task.cancel()
    #expect(collected == [.a, .b])
  }

  @Test func nextEffectDrainsUntilNil() async {
    enum Action: Sendable, Equatable { case kick, stepped(Int) }

    struct Stepper: LoopBehavior {
      func reduce(state: inout [Int], action: Action) {
        switch action {
        case .kick:
          break
        case let .stepped(n):
          state.append(n)
        }
      }

      func nextEffect(state: inout [Int]) -> Effect<Action>? {
        if state.count < 3 {
          let n = state.count
          return .send(.stepped(n))
        }
        return nil
      }
    }

    let loop = EffectLoop(behavior: Stepper(), initialState: [])
    let task = Task { await loop.start() }

    await loop.send(.kick)

    try? await Task.sleep(nanoseconds: 50_000_000)

    let state = await loop.state
    task.cancel()

    #expect(state == [0, 1, 2])
  }
}
