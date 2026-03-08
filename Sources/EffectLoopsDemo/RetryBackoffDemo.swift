// MARK: - Demo 2: Retry with Backoff
//
// Simulates a flaky API that fails ~60% of the time. The behavior
// tracks error count and retry timing as state fields. nextEffect
// sees the error → returns a sleep effect → retries. No special
// retry infrastructure — it's just state + effects.
//
// Demonstrates: error recovery as state, exponential backoff via
// sleep effects, the "priority ladder" pattern in nextEffect.

#if canImport(SwiftUI) && canImport(AppKit)
import EffectLoops
import SwiftUI

// MARK: State & Actions

struct RetryState: Sendable, Equatable {
  var status: Status = .idle
  var attempts: Int = 0
  var maxAttempts: Int = 10
  var log: [LogEntry] = []
  var failRate: Double = 0.6

  enum Status: Sendable, Equatable {
    case idle
    case fetching
    case waitingToRetry(until: ContinuousClock.Instant, delay: Duration)
    case succeeded(String)
    case failed
  }

  struct LogEntry: Sendable, Equatable, Identifiable {
    let id: Int
    let text: String
    let isError: Bool
  }
}

enum RetryAction: Sendable, Equatable {
  case startFetch
  case fetchSucceeded(String)
  case fetchFailed(String)
  case retryReady
  case reset
}

// MARK: Behavior

struct RetryBehavior: LoopBehavior {
  func reduce(state: inout RetryState, action: RetryAction) {
    switch action {
    case .startFetch:
      state.status = .fetching
      state.attempts = 0
      state.log = []
      state.log.append(.init(id: 0, text: "▶ Starting fetch...", isError: false))

    case let .fetchSucceeded(value):
      state.status = .succeeded(value)
      state.log.append(.init(
        id: state.log.count,
        text: "✓ Success on attempt \(state.attempts): \(value)",
        isError: false
      ))

    case let .fetchFailed(error):
      state.attempts += 1
      if state.attempts >= state.maxAttempts {
        state.status = .failed
        state.log.append(.init(
          id: state.log.count,
          text: "✗ Failed after \(state.attempts) attempts: \(error)",
          isError: true
        ))
      } else {
        let delay = Duration.milliseconds(min(200 * (1 << (state.attempts - 1)), 5000))
        state.status = .waitingToRetry(
          until: .now + delay,
          delay: delay
        )
        state.log.append(.init(
          id: state.log.count,
          text: "✗ Attempt \(state.attempts) failed: \(error). Retrying in \(delay)...",
          isError: true
        ))
      }

    case .retryReady:
      state.status = .fetching
      state.log.append(.init(
        id: state.log.count,
        text: "  Retrying (attempt \(state.attempts + 1))...",
        isError: false
      ))

    case .reset:
      state.status = .idle
      state.attempts = 0
    }
  }

  func nextEffect(state: inout RetryState) -> Effect<RetryAction>? {
    switch state.status {
    case .idle, .succeeded, .failed:
      return nil

    case let .waitingToRetry(until, _):
      // Sleep then signal ready. The next step will see .fetching.
      return Effect { send in
        try? await Task.sleep(until: until, clock: .continuous)
        await send(.retryReady)
      }

    case .fetching:
      // Guard: mark as in-flight by leaving status as .fetching.
      // The effect will send either .fetchSucceeded or .fetchFailed.
      let failRate = state.failRate
      return Effect { send in
        // Simulate network delay
        try? await Task.sleep(for: .milliseconds(Int.random(in: 100...400)))

        // Simulate flaky API
        if Double.random(in: 0...1) < failRate {
          await send(.fetchFailed("HTTP 503"))
        } else {
          let value = "data-\(Int.random(in: 1000...9999))"
          await send(.fetchSucceeded(value))
        }
      }
    }
  }
}

// MARK: View Model

@Observable
@MainActor
final class RetryViewModel {
  var state = RetryState()
  private var loop: EffectLoop<RetryBehavior>?
  private var observeTask: Task<Void, Never>?

  func start() {
    let loop = EffectLoop(behavior: RetryBehavior(), initialState: RetryState())
    self.loop = loop
    observeTask = Task {
      let (initialState, actions) = await loop.subscribe()
      self.state = initialState
      Task { await loop.start() }
      for await _ in actions {
        self.state = await loop.state
      }
    }
  }

  func stop() {
    observeTask?.cancel()
    loop = nil
  }

  func fetch() {
    guard let loop else { return }
    Task { await loop.send(.startFetch) }
  }

  func reset() {
    guard let loop else { return }
    Task { await loop.send(.reset) }
  }
}

// MARK: View

struct RetryBackoffDemoView: View {
  @State private var vm = RetryViewModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Retry with Backoff")
        .font(.title2.bold())

      Text("Simulates a flaky API (~60% fail rate). Errors become state fields; nextEffect returns sleep effects for exponential backoff. No retry infrastructure needed.")
        .foregroundStyle(.secondary)
        .font(.callout)

      HStack {
        Button("Fetch") { vm.fetch() }
          .disabled(isActive)

        Button("Reset") { vm.reset() }
          .disabled(!isActive && vm.state.status == .idle)

        Spacer()

        statusBadge
      }

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(vm.state.log) { entry in
              Text(entry.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(entry.isError ? .red : .primary)
                .id(entry.id)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: vm.state.log.count) { _, _ in
          if let last = vm.state.log.last {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
    .padding()
    .onAppear { vm.start() }
    .onDisappear { vm.stop() }
  }

  private var isActive: Bool {
    switch vm.state.status {
    case .fetching, .waitingToRetry: true
    default: false
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    switch vm.state.status {
    case .idle:
      Text("Idle").foregroundStyle(.secondary)
    case .fetching:
      HStack(spacing: 4) {
        ProgressView().controlSize(.small)
        Text("Fetching...")
      }
    case let .waitingToRetry(_, delay):
      Text("Waiting \(delay)...")
        .foregroundStyle(.orange)
    case let .succeeded(value):
      Text("✓ \(value)")
        .foregroundStyle(.green)
    case .failed:
      Text("✗ Failed")
        .foregroundStyle(.red)
    }
  }
}
#endif
