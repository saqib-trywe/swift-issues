import AppCore
import ClientStore
import Core
import SwiftUI

extension Emphasis {
    /// Maps an abstract emphasis onto a colour. The decision lives in `AppCore`
    /// where it is tested; this is only the paint.
    var tint: Color {
        switch self {
        case .normal: .blue
        case .muted: .secondary
        case .prominent: .orange
        case .unrecognised: .orange
        }
    }
}

extension LabelColor {
    public static func color(from hex: String) -> Color {
        let parts = components(from: hex)
        return Color(red: parts.red, green: parts.green, blue: parts.blue)
    }
}

/// An Issue Key, or the placeholder for one that has not been assigned.
public struct IssueKeyLabel: View {
    let key: IssueKey?
    let projectKey: ProjectKey?

    public init(key: IssueKey?, projectKey: ProjectKey? = nil) {
        self.key = key
        self.projectKey = projectKey
    }

    public var body: some View {
        Text(IssueKeyPresentation.text(key: key, projectKey: projectKey))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(key == nil ? .secondary : .primary)
            .accessibilityLabel(IssueKeyPresentation.accessibilityLabel(key: key))
    }
}

/// A Status, as a pill.
public struct StatusPill: View {
    let status: Status

    public init(_ status: Status) {
        self.status = status
    }

    public var body: some View {
        let tint = StatusPresentation.emphasis(status).tint
        Text(StatusPresentation.text(status))
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A Priority.
public struct PriorityLabel: View {
    let priority: Priority

    public init(_ priority: Priority) {
        self.priority = priority
    }

    public var body: some View {
        let emphasis = PriorityPresentation.emphasis(priority)
        Text(PriorityPresentation.text(priority))
            .font(.caption)
            .fontWeight(emphasis == .prominent ? .semibold : .regular)
            .foregroundStyle(emphasis == .muted ? Color.secondary : emphasis.tint)
    }
}

/// A Label on an Issue.
///
/// `Core.Label` throughout: SwiftUI has a `Label` of its own, and an unqualified
/// reference here is ambiguous.
public struct LabelChip: View {
    let label: Core.Label

    public init(_ label: Core.Label) {
        self.label = label
    }

    public var body: some View {
        Text(label.name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(LabelColor.color(from: label.color).opacity(0.18), in: Capsule())
    }
}

/// Whether a human or a program made this.
public struct ViaBadge: View {
    let via: Via

    public init(_ via: Via) {
        self.via = via
    }

    public var body: some View {
        if ViaPresentation.shouldShow(via) {
            Image(systemName: "cpu")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Filed by \(ViaPresentation.text(via))")
        }
    }
}

/// Marks a value that has not reached the server yet.
///
/// Derived from base-plus-pending (ADR 0008), never tracked separately — which is
/// why this takes the answer rather than working it out.
public struct DirtyIndicator: View {
    let isDirty: Bool

    public init(isDirty: Bool) {
        self.isDirty = isDirty
    }

    /// Always occupies its space, even when nothing is dirty.
    ///
    /// A hidden view would collapse the row and shift every title left, so a list
    /// would jitter as items sync. Found by looking at it.
    public var body: some View {
        Circle()
            .fill(isDirty ? Color.orange : .clear)
            .frame(width: 6, height: 6)
            .accessibilityLabel(isDirty ? "Not yet sent" : "")
            .accessibilityHidden(!isDirty)
    }
}
