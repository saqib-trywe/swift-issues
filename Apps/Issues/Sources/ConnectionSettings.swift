import AppCore
import Core
import SwiftUI

/// Where the server and its token are set.
///
/// The token goes to the Keychain, never to preferences — the same store the CLI
/// uses, keyed by server so pointing at a test instance cannot clobber a real
/// credential.
struct ConnectionSettings: View {
    @Bindable var session: AppSession
    @State private var url = ""
    @State private var token = ""
    @State private var saved = false

    var body: some View {
        Form {
            TextField("Server URL", text: $url, prompt: Text("https://issues.example.com"))
            SecureField("Personal access token", text: $token, prompt: Text("issues_pat_…"))

            Text(
                "Mint a token with `issues auth token create`, or from this app once "
                    + "token management lands.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save") {
                    session.serverURL = url
                    session.token = token
                    saved = true
                }
                .disabled(url.isEmpty)

                if saved {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .onAppear {
            url = session.serverURL
            // The stored token is not shown: displaying a secret that is already
            // safely stored only creates somewhere else for it to be read from.
            token = ""
        }
    }
}
