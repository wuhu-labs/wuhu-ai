// MARK: - Demo 3: Cost-Gated Task
//
// Simulates an expensive multi-step task with a budget. Each step
// costs tokens. When budget is exhausted, the loop goes idle —
// nextEffect returns nil. The user can approve more budget via an
// external action, which triggers a step and the loop resumes.
//
// Demonstrates: cost gating without special loop machinery, external
// actions unblocking an idle loop, the "gate" pattern where
// nextEffect checks a resource before proceeding.

#if canImport(SwiftUI) && canImport(AppKit)
import EffectLoops
import SwiftUI

// MARK: State & Actions

struct CostGateState: Sendable, Equatable {
  var steps: [Step] = []
  var currentStep: Int = 0
  var totalSteps: Int = 0
  var budget: Int = 0
  var totalSpent: Int = 0
  var isRunning: Bool = false
  var isPaused: Bool = false
  var log: [LogEntry] = []

  struct Step: Sendable, Equatable {
    let name: String
    let cost: Int
    var status: Status = .pending

    enum Status: Sendable, Equatable {
      case pending, running, completed, skipped
    }
  }

  struct LogEntry: Sendable, Equatable, Identifiable {
    let id: Int
    let text: String
    let kind: Kind
    enum Kind: Sendable, Equatable { case info, cost, gate, success, error }
  }
}

enum CostGateAction: Sendable, Equatable {
  case startTask(budget: Int)
  case stepCompleted(cost: Int)
  case stepFailed(String)
  case budgetExhausted
  case addBudget(Int)
  case taskFinished
  case reset
}

// MARK: Behavior

struct CostGateBehavior: LoopBehavior {
  func reduce(state: inout CostGateState, action: CostGateAction) {
    func log(_ text: String, kind: CostGateState.LogEntry.Kind) {
      state.log.append(.init(id: state.log.count, text: text, kind: kind))
    }

    switch action {
    case let .startTask(budget):
      state.budget = budget
      state.totalSpent = 0
      state.currentStep = 0
      state.isRunning = true
      state.isPaused = false
      state.steps = [
        .init(name: "Parse input", cost: 5),
        .init(name: "Query database", cost: 15),
        .init(name: "Transform results", cost: 10),
        .init(name: "Generate summary", cost: 25),
        .init(name: "Format output", cost: 8),
      ]
      state.totalSteps = state.steps.count
      log("▶ Task started with budget: \(budget) tokens", kind: .info)

    case let .stepCompleted(cost):
      state.steps[state.currentStep].status = .completed
      state.budget -= cost
      state.totalSpent += cost
      log("  ✓ \(state.steps[state.currentStep].name) completed (-\(cost) tokens, \(state.budget) remaining)", kind: .cost)
      state.currentStep += 1

    case let .stepFailed(error):
      log("  ✗ \(state.steps[state.currentStep].name) failed: \(error)", kind: .error)
      state.steps[state.currentStep].status = .skipped
      state.currentStep += 1

    case .budgetExhausted:
      state.isPaused = true
      let nextStep = state.steps[state.currentStep]
      log("⏸ Budget exhausted! Need \(nextStep.cost) tokens for \"\(nextStep.name)\", have \(state.budget). Approve more budget to continue.", kind: .gate)

    case let .addBudget(amount):
      state.budget += amount
      state.isPaused = false
      log("💰 Added \(amount) tokens (now \(state.budget))", kind: .info)

    case .taskFinished:
      state.isRunning = false
      state.isPaused = false
      log("✓ Task complete! Spent \(state.totalSpent) tokens total.", kind: .success)

    case .reset:
      state = CostGateState()
    }
  }

  func nextEffect(state: inout CostGateState) -> Effect<CostGateAction>? {
    guard state.isRunning else { return nil }

    // All steps done?
    guard state.currentStep < state.steps.count else {
      return .send(.taskFinished)
    }

    let step = state.steps[state.currentStep]

    // Budget check — the gate
    if step.cost > state.budget {
      if !state.isPaused {
        return .send(.budgetExhausted)
      }
      // Already paused. Return nil → loop idles.
      // When .addBudget arrives, it triggers step() again.
      return nil
    }

    // Execute the step
    state.steps[state.currentStep].status = .running
    let stepIndex = state.currentStep
    let cost = step.cost

    return Effect { send in
      // Simulate work
      try? await Task.sleep(for: .milliseconds(Int.random(in: 300...800)))

      // Small chance of failure
      if Double.random(in: 0...1) < 0.1 {
        await send(.stepFailed("timeout"))
      } else {
        await send(.stepCompleted(cost: cost))
      }
    }
  }
}

// MARK: View Model

@Observable
@MainActor
final class CostGateViewModel {
  var state = CostGateState()
  private var loop: EffectLoop<CostGateBehavior>?
  private var observeTask: Task<Void, Never>?

  func start() {
    let loop = EffectLoop(behavior: CostGateBehavior(), initialState: CostGateState())
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

  func startTask(budget: Int) {
    guard let loop else { return }
    Task { await loop.send(.startTask(budget: budget)) }
  }

  func addBudget(_ amount: Int) {
    guard let loop else { return }
    Task { await loop.send(.addBudget(amount)) }
  }

  func reset() {
    guard let loop else { return }
    Task { await loop.send(.reset) }
  }
}

// MARK: View

struct CostGateDemoView: View {
  @State private var vm = CostGateViewModel()
  @State private var budgetText = "20"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Cost-Gated Task")
        .font(.title2.bold())

      Text("A multi-step task with a token budget. When budget runs out, the loop idles until you approve more. No special gating machinery — just a state check in nextEffect.")
        .foregroundStyle(.secondary)
        .font(.callout)

      HStack {
        TextField("Budget", text: $budgetText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 80)

        Button("Start Task") {
          if let n = Int(budgetText), n > 0 {
            vm.startTask(budget: n)
          }
        }
        .disabled(vm.state.isRunning)

        if vm.state.isPaused {
          Button("Add 20 Tokens") { vm.addBudget(20) }
            .tint(.orange)
          Button("Add 50 Tokens") { vm.addBudget(50) }
            .tint(.green)
        }

        Button("Reset") { vm.reset() }
          .disabled(!vm.state.isRunning && vm.state.steps.isEmpty)

        Spacer()

        if vm.state.isRunning {
          HStack(spacing: 4) {
            if vm.state.isPaused {
              Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
              Text("Paused")
                .foregroundStyle(.orange)
            } else {
              ProgressView().controlSize(.small)
              Text("Step \(vm.state.currentStep + 1)/\(vm.state.totalSteps)")
            }
            Text("•")
              .foregroundStyle(.secondary)
            Text("\(vm.state.budget) tokens left")
              .monospacedDigit()
          }
        }
      }

      // Steps progress
      if !vm.state.steps.isEmpty {
        HStack(spacing: 4) {
          ForEach(Array(vm.state.steps.enumerated()), id: \.offset) { _, step in
            stepIndicator(step)
          }
        }
      }

      Divider()

      // Log
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(vm.state.log) { entry in
              Text(entry.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(colorForKind(entry.kind))
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

  @ViewBuilder
  private func stepIndicator(_ step: CostGateState.Step) -> some View {
    let color: Color = switch step.status {
    case .pending: .secondary
    case .running: .blue
    case .completed: .green
    case .skipped: .red
    }
    VStack(spacing: 2) {
      RoundedRectangle(cornerRadius: 3)
        .fill(color)
        .frame(height: 6)
      Text(step.name)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func colorForKind(_ kind: CostGateState.LogEntry.Kind) -> Color {
    switch kind {
    case .info: .primary
    case .cost: .blue
    case .gate: .orange
    case .success: .green
    case .error: .red
    }
  }
}
#endif
