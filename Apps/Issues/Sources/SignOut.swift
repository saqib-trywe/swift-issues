import AppCore
import SwiftUI

/// The sign-out confirmation.
///
/// Ticket 07: logging out clears the local replica, so with a non-empty queue this
/// is destruction and has to read like it — stating the count, offering to sync
/// first, and naming what the confirming button will do.
struct SignOutConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let plan: LogoutPlan
    let syncFirst: () async -> Void
    let signOut: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            plan.title, isPresented: $isPresented, titleVisibility: .visible
        ) {
            if let syncTitle = plan.syncFirstTitle {
                // Offered first, so the safe path is the easy one.
                Button(syncTitle) { Task { await syncFirst() } }
            }
            Button(plan.confirmTitle, role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan.message)
        }
    }
}

extension View {
    func signOutConfirmation(
        isPresented: Binding<Bool>,
        plan: LogoutPlan,
        syncFirst: @escaping () async -> Void,
        signOut: @escaping () -> Void
    ) -> some View {
        modifier(
            SignOutConfirmation(
                isPresented: isPresented, plan: plan, syncFirst: syncFirst, signOut: signOut))
    }
}
