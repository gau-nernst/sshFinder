import AppKit
import SwiftUI

@main
struct SSHFinderApp: App {
    @State private var tabs = Tabs()

    init() {
        Smoke.runIfRequested()
        SSH.setUp()
    }

    var body: some Scene {
        // One window; tabs are drawn by the app in the title row.
        Window("sshFinder", id: "main") {
            MainView()
                .environment(tabs)
                .frame(minWidth: 760, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        // Always open the window at launch, even if window restoration recorded
        // none (e.g. after the app was killed with no windows open).
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { tabs.newTab() }
                    .keyboardShortcut("t")
            }
        }
    }
}

struct MainView: View {
    @Environment(Tabs.self) private var tabs

    var body: some View {
        let browser = tabs.selected
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TabStrip()
                if browser.host != nil { ActionBar() }
            }
            .background(.bar)
            Divider()
            Group {
                if browser.host == nil { StartPage() } else { BrowserPane() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(browser.id)
            TransfersPanel()
        }
        .environment(browser)
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(browser.host ?? "sshFinder")
        .onReceive(NotificationCenter.default.publisher(for: .remoteFolderChanged)) { note in
            for b in tabs.browsers
            where note.userInfo?["host"] as? String == b.host && note.userInfo?["dir"] as? String == b.cwd {
                b.refresh()
            }
        }
        .task {
            await Snapshot.runIfRequested(tabs)
            await UITest.runIfRequested(tabs)
        }
    }
}
