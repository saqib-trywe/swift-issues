import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// The iPhone and iPad app.
///
/// One target for both, because ticket 10's divergence is a matter of layout
/// container rather than behaviour: the iPad gets the Mac's two-column composition
/// at touch sizes, the iPhone a stack with a tab bar. Everything they show comes
/// from the shared layer.
@main
struct IssuesMobileApp: App {
    @State private var session = MobileSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task { await session.start() }
        }
    }
}

struct RootView: View {
    @Bindable var session: MobileSession
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // The size class decides, not the device: an iPad in a narrow split window
        // is a compact layout, and an iPhone in landscape is not a desktop.
        if sizeClass == .compact {
            PhoneLayout(session: session)
        } else {
            PadLayout(session: session)
        }
    }
}
