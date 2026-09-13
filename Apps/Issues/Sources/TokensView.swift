import AppCore
import AppViews
import Core
import SwiftUI

/// Token and session administration.
///
/// Mac-only by ticket 10, and not for aesthetic reasons: there is no web UI, so
/// this is the only interface a token can be minted, labelled or revoked from.
struct TokensView: View {
    @Bindable var session: AppSession
    @State private var model: TokenListModel?
    @State private var isMinting = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "key.slash",
                    description: Text("Add a server and a token in Settings."))
            }
        }
        .task {
            model = session.makeTokenModel()
            await model?.reload()
        }
    }

    private func content(_ model: TokenListModel) -> some View {
        VStack(spacing: 0) {
            if let failure = model.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.08))
            }

            Table(model.tokens) {
                TableColumn("Label") { token in
                    Text(token.label ?? "—")
                        .foregroundStyle(token.label == nil ? .secondary : .primary)
                }
                TableColumn("Kind") { token in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(token.kind.wireValue)
                        // Ticket 12: make plain that an agent holds less authority
                        // than its owner. An Admin's agent is not an admin.
                        Text(TokenListModel.authorityDescription(token.kind))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                TableColumn("Last used") { token in
                    Text(token.lastUsedAt.map(Self.day) ?? "Never")
                        .foregroundStyle(.secondary)
                }
                TableColumn("State") { token in
                    Text(token.isRevoked ? "Revoked" : "Active")
                        .foregroundStyle(token.isRevoked ? .secondary : .primary)
                }
                TableColumn("") { token in
                    if !token.isRevoked {
                        Button("Revoke") { Task { await model.revoke(token.id) } }
                            .buttonStyle(.borderless)
                    }
                }
                .width(70)
            }

            HStack {
                Button("New Token…") { isMinting = true }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(.bar)
        }
        .sheet(isPresented: $isMinting) {
            MintTokenSheet(model: model)
        }
        .navigationTitle("Tokens")
    }

    /// The day only: last-used is recorded to the hour, so a minute-precise
    /// timestamp would imply an accuracy that is not there.
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Minting a token.
struct MintTokenSheet: View {
    @Bindable var model: TokenListModel
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var kind = TokenKind.human
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let minted = model.justMinted {
                issued(minted)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var form: some View {
        Group {
            Text("New token").font(.headline)

            TextField("Label", text: $label, prompt: Text("What is it for?"))
            Text("A token without a label is hard to identify later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Kind", selection: $kind) {
                ForEach(TokenKind.known, id: \.wireValue) { Text($0.wireValue).tag($0) }
            }
            Text(TokenListModel.authorityDescription(kind))
                .font(.caption)
                .foregroundStyle(.secondary)

            // The server requires this even though the app is already signed in:
            // without it a leaked token could mint replacements, and revoking the
            // original would leave them working.
            SecureField("Your password", text: $password)
            Text("Confirms it is you, not just this device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") {
                    Task {
                        await model.mint(
                            password: password, kind: kind,
                            label: label.isEmpty ? nil : label)
                        password = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || model.isWorking)
            }
        }
    }

    private func issued(_ token: String) -> some View {
        Group {
            Text("Token created").font(.headline)
            Text("This is the only time it will be shown — the server keeps only a hash.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(token)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                }
                Spacer()
                Button("Done") {
                    // Forgotten here rather than left in memory for the life of the
                    // window.
                    model.clearMinted()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
