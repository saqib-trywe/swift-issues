import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// Creating or editing an issue.
///
/// One form for both: the fields are identical, and the only difference is whether
/// there is an original to diff against. That diff is why an edit queues a patch of
/// just what changed rather than a whole-record snapshot — under per-field
/// last-write-wins, stale values for untouched fields would beat somebody else's
/// newer edit.
struct IssueEditorSheet: View {
    let projectId: Project.ID
    /// `nil` when creating.
    let existing: Overlaid<Issue>?
    let writer: IssueWriter
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = IssueDraft()
    @State private var original = IssueDraft()
    @State private var failure: String?

    private var isCreating: Bool { existing == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCreating ? "New issue" : "Edit issue").font(.headline)

            TextField("Title", text: $draft.title, prompt: Text("What needs doing?"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.description)
                    .font(.body)
                    .frame(minHeight: 110)
                    .border(.quaternary)
                Text("Markdown. Headings, lists and fenced code all render.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 20) {
                picker("Status", field: .status, selection: $draft.status, options: Status.known) {
                    StatusPresentation.text($0)
                }
                picker(
                    "Priority", field: .priority, selection: $draft.priority,
                    options: Priority.known
                ) {
                    PriorityPresentation.text($0)
                }
            }

            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isCreating ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard let existing else { return }
            // Seeded from the overlaid value, so an edit builds on the user's own
            // unsent changes rather than on the server's older record.
            draft = IssueDraft(from: existing.record)
            original = draft
        }
    }

    /// A picker that disables itself for a value this build cannot represent.
    private func picker<Value: Hashable>(
        _ name: String,
        field: IssueField,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        let isLocked = draft.isReadOnly(field)
        return VStack(alignment: .leading, spacing: 2) {
            Picker(name, selection: selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .disabled(isLocked)

            if isLocked {
                // Offering a control here would let the user overwrite a value this
                // version does not understand — the thing lenient decoding exists to
                // prevent (ticket 10).
                Text("Set to something this version does not recognise.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        do {
            if let existing {
                _ = try writer.edit(existing.record.id, from: original, to: draft)
            } else {
                _ = try writer.create(draft, in: projectId)
            }
            failure = nil
            onFinish()
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }
}

/// Adding a comment.
struct CommentComposer: View {
    let issueId: Issue.ID
    let writer: IssueWriter
    let onFinish: () -> Void

    @State private var text = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 56)
                .border(.quaternary)

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text("Markdown").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Comment", action: post)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func post() {
        do {
            _ = try writer.comment(on: issueId, body: text)
            text = ""
            failure = nil
            onFinish()
        } catch {
            failure = String(describing: error)
        }
    }
}
