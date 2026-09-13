import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// The macOS app.
///
/// Thin by design: ticket 10's variant C puts every behaviour in the shared layer
/// and leaves each platform only a composition. What is genuinely Mac-specific is
/// the layout container, the keyboard affordances, and the administration surfaces
/// that exist nowhere else because there is no web UI.
@main
struct IssuesApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .frame(minWidth: 900, minHeight: 560)
                .task { await session.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await session.sync() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            ConnectionSettings(session: session)
                .frame(width: 420)
        }
    }
}
