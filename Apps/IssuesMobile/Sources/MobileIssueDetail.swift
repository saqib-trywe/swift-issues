import AppCore
import AppViews
import ClientStore
import Core
import SwiftUI

/// One issue, full screen on the phone and in the detail column on the iPad.
struct MobileIssueDetail: View {
    @Bindable var session: MobileSession
    let id: Issue.ID
    @State private var editing = false

    var body: some View {
        Group {
            if let issue = session.issue(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        IssueDetailContent(
                            issue: issue,
                            comments: session.comments(for: id),
                            projectKey: session.projects
                                .first { $0.id == issue.record.projectId }?.key)

                        if let writer = session.writer {
                            CommentField(
                                issueId: id, writer: writer, onFinish: session.afterLocalWrite)
                        }
                    }
                    .padding(16)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editing = true }
                    }
                }
                .sheet(isPresented: $editing) {
                    if let writer = session.writer {
                        NavigationStack {
                            MobileIssueEditor(
                                projectId: issue.record.projectId, existing: issue,
                                writer: writer, onFinish: session.afterLocalWrite)
                        }
                    }
                }
            } else {
                // Pull order is change order, so a record can simply not have
                // arrived yet. Normal, not an error.
                ContentUnavailableView(
                    "Not here yet", systemImage: "arrow.down.circle",
                    description: Text("This issue has not synced to this device."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The phone's comment box.
struct CommentField: View {
    let issueId: Issue.ID
    let writer: IssueWriter
    let onFinish: () -> Void

    @State private var text = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Add a comment", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Post") {
                    do {
                        _ = try writer.comment(on: issueId, body: text)
                        text = ""
                        failure = nil
                        onFinish()
                    } catch {
                        failure = String(describing: error)
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Creating or editing, on a touch screen.
struct MobileIssueEditor: View {
    let projectId: Project.ID
    let existing: Overlaid<Issue>?
    let writer: IssueWriter
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = IssueDraft()
    @State private var original = IssueDraft()
    @State private var failure: String?

    private var isCreating: Bool { existing == nil }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title, axis: .vertical)
                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(4...12)
            } footer: {
                Text("Markdown. Headings, lists and fenced code all render.")
            }

            Section {
                Picker("Status", selection: $draft.status) {
                    ForEach(Status.known, id: \.wireValue) {
                        Text(StatusPresentation.text($0)).tag($0)
                    }
                }
                .disabled(draft.isReadOnly(.status))

                Picker("Priority", selection: $draft.priority) {
                    ForEach(Priority.known, id: \.wireValue) {
                        Text(PriorityPresentation.text($0)).tag($0)
                    }
                }
                .disabled(draft.isReadOnly(.priority))
            } footer: {
                if draft.isReadOnly(.status) || draft.isReadOnly(.priority) {
                    // A control here would let the user overwrite a value this
                    // version cannot represent (ticket 10).
                    Text("A value is set to something this version does not recognise.")
                }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
        }
        .navigationTitle(isCreating ? "New Issue" : "Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isCreating ? "Create" : "Save", action: save)
                    .disabled(!draft.isValid)
            }
        }
        .onAppear {
            guard let existing else { return }
            draft = IssueDraft(from: existing.record)
            original = draft
        }
    }

    private func save() {
        do {
            if let existing {
                _ = try writer.edit(existing.record.id, from: original, to: draft)
            } else {
                _ = try writer.create(draft, in: projectId)
            }
            onFinish()
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }
}
