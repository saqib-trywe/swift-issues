import AppCore
import ClientStore
import Core
import SwiftUI

/// All five sync surfaces, one implementation.
///
/// Ticket 10's central rule: **do not reimplement one of these per platform.** They
/// are what make the sync guarantees visible, and a divergence in wording between
/// platforms becomes a divergence in meaning. Each platform decides *where* this
/// goes — a Mac banner, an iPhone Inbox tab — never what it says.
public struct SyncStatusView: View {
    let status: SyncStatus
    /// Called when the user acts on a surface. The host decides what that means: a
    /// Mac might open an inspector, an iPhone push a screen.
    let act: ((SyncSurface) -> Void)?

    public init(status: SyncStatus, act: ((SyncSurface) -> Void)? = nil) {
        self.status = status
        self.act = act
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(status.surfaces, id: \.self) { surface in
                SyncSurfaceRow(surface: surface, act: act)
            }
        }
    }
}

/// One surface.
struct SyncSurfaceRow: View {
    let surface: SyncSurface
    let act: ((SyncSurface) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: surface.symbol)
                .foregroundStyle(Self.tint(surface))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(surface.title).font(.callout).fontWeight(.medium)
                Text(surface.detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let act {
                Button(surface.actionTitle) { act(surface) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Self.tint(surface).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    static func tint(_ surface: SyncSurface) -> Color {
        switch surface.severity {
        case .informational: .secondary
        case .warning: .orange
        case .blocking: .red
        }
    }
}
