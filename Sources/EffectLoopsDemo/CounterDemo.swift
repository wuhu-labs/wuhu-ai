// MARK: - Demo 1: Streaming Counter
//
// The simplest possible EffectLoop demo. A counter that increments
// with a delay, showing the basic cycle:
//
//   nextEffect sees count < target → returns sleep + .tick effect
//   .tick reduces → count += 1 → nextEffect fires again
//   until count == target → nextEffect returns nil → idle
//
// Demonstrates: guard tokens, async effects, subscribe(), external actions.

#if canImport(SwiftUI) && canImport(AppKit)
import EffectLoops
import SwiftUI

// MARK: State & Actions

struct CounterState: Sendable, Equatable {
  var count: Int = 0
  var target: Int = 0
  var isRunning: Bool = false
  var log: [String] = []
}

enum CounterAction: Sendable, Equatable {
  case setTarget(Int)
  case tick
  case finished
}

// MARK: Behavior

struct CounterBehavior: LoopBehavior {
  func reduce(state: inout CounterState, action: CounterAction) {
    switch action {
    case let .setTarget(n):
      state.target = n
      state.count = 0
      state.isRunning = true
      state.log.append("▶ Started counting to \(n)")
    case .tick:
      state.count += 1
      state.log.append("  tick → \(state.count)")
    case .finished:
      state.isRunning = false
      state.log.append("✓ Finished at \(state.count)")
    }
  }

  func nextEffect(state: inout CounterState) -> Effect<CounterAction>? {
    guard state.isRunning else { return nil }

    if state.count >= state.target {
      return .send(.finished)
    }

    // Guard token: don't re-issue while sleeping
    // We use the isRunning + count check above — each .tick
    // advances count, so we won't re-enter for the same tick.
    return Effect { send in
      try? await Task.sleep(for: .milliseconds(300))
      await send(.tick)
    }
  }
}

// MARK: View Model

@Observable
@MainActor
final class CounterViewModel {
  var state = CounterState()
  private var loop: EffectLoop<CounterBehavior>?
  private var observeTask: Task<Void, Never>?

  func start() {
    let behavior = CounterBehavior()
    let loop = EffectLoop(behavior: behavior, initialState: CounterState())
    self.loop = loop

    observeTask = Task {
      let (initialState, actions) = await loop.subscribe()
      self.state = initialState
      Task { await loop.start() }
      for await action in actions {
        _ = action
        self.state = await loop.state
      }
    }
  }

  func stop() {
    observeTask?.cancel()
    observeTask = nil
    loop = nil
  }

  func countTo(_ n: Int) {
    guard let loop else { return }
    Task { await loop.send(.setTarget(n)) }
  }
}

// MARK: View

struct CounterDemoView: View {
  @State private var vm = CounterViewModel()
  @State private var targetText = "10"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Streaming Counter")
        .font(.title2.bold())

      Text("Counts up with a 300ms delay per tick. Shows the basic nextEffect → Effect → Action cycle.")
        .foregroundStyle(.secondary)
        .font(.callout)

      HStack {
        TextField("Target", text: $targetText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 80)

        Button("Go") {
          if let n = Int(targetText), n > 0 {
            vm.countTo(n)
          }
        }
        .disabled(vm.state.isRunning)

        if vm.state.isRunning {
          ProgressView()
            .controlSize(.small)
          Text("\(vm.state.count) / \(vm.state.target)")
            .monospacedDigit()
        }
      }

      Divider()

      // Log
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(vm.state.log.enumerated()), id: \.offset) { i, line in
              Text(line)
                .font(.system(.body, design: .monospaced))
                .id(i)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: vm.state.log.count) { _, _ in
          if let last = vm.state.log.indices.last {
            proxy.scrollTo(last, anchor: .bottom)
          }
        }
      }
    }
    .padding()
    .onAppear { vm.start() }
    .onDisappear { vm.stop() }
  }
}
#endif
