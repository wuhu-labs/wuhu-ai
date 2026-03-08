// MARK: - EffectLoops Demo App
//
// A macOS SwiftUI app demonstrating EffectLoops patterns.
// On Linux this target just prints a message.

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

@main
struct EffectLoopsDemoApp: App {
  init() {
    // When launched from terminal via `swift run`, the process starts
    // as a background app. Promote it to a regular GUI app so it gets
    // keyboard focus and appears in the Dock.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  var body: some Scene {
    WindowGroup {
      DemoRootView()
        .frame(minWidth: 700, minHeight: 500)
    }
  }
}

struct DemoRootView: View {
  @State private var selected: DemoTab = .counter

  var body: some View {
    NavigationSplitView {
      List(DemoTab.allCases, selection: $selected) { tab in
        Label(tab.title, systemImage: tab.icon)
      }
      .navigationTitle("Examples")
    } detail: {
      selected.view
    }
  }
}

enum DemoTab: String, CaseIterable, Identifiable, Hashable {
  case counter
  case retryBackoff
  case costGate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .counter: "Streaming Counter"
    case .retryBackoff: "Retry with Backoff"
    case .costGate: "Cost-Gated Task"
    }
  }

  var icon: String {
    switch self {
    case .counter: "number.circle"
    case .retryBackoff: "arrow.clockwise"
    case .costGate: "dollarsign.circle"
    }
  }

  @ViewBuilder
  var view: some View {
    switch self {
    case .counter: CounterDemoView()
    case .retryBackoff: RetryBackoffDemoView()
    case .costGate: CostGateDemoView()
    }
  }
}

#else

@main
struct EffectLoopsDemoFallback {
  static func main() {
    print("EffectLoopsDemo requires macOS with SwiftUI.")
    print("Run on a Mac: swift run EffectLoopsDemo")
  }
}

#endif
