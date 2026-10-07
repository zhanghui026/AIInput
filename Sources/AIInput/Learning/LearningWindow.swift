import Cocoa
import SwiftUI

/// 学习窗口（复习 / 本子 / 统计），从菜单栏打开。
@MainActor
final class LearningWindowController: NSWindowController {
    private let stores: LearningStores
    private let session: ReviewSession
    private let state = TabState()

    private final class TabState: ObservableObject {
        @Published var tab: LearningView.Tab = .review
    }

    private struct Root: View {
        let stores: LearningStores
        let session: ReviewSession
        @ObservedObject var state: TabState

        var body: some View {
            LearningView(
                notebook: stores.notebook,
                lookups: stores.lookups,
                session: session,
                tab: $state.tab
            )
        }
    }

    init(stores: LearningStores? = nil) {
        let stores = stores ?? LearningStores.shared
        self.stores = stores
        session = ReviewSession(notebook: stores.notebook)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AIInput 学习"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: Root(stores: stores, session: session, state: state))
        if !window.setFrameUsingName("AIInputLearningWindow") { window.center() }
        window.setFrameAutosaveName("AIInputLearningWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: LearningView.Tab? = nil) {
        if let tab { state.tab = tab }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
