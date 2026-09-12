import ArgumentParser
import Core
import Foundation

extension AuthCommand {

    /// Personal access tokens.
    ///
    /// There is no web UI, so this is the only place a token can be managed from
    /// (ticket 07) — and it is how an agent token for MCP gets minted.
    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "token",
            abstract: "Mint, list and revoke personal access tokens.",
            discussion: """
                A token carries the same permissions as its owner, with a kind so an \
                Admin can tell a person from a program. Minting one always asks for \
                your password, even though you are already logged in: otherwise a \
                leaked token could mint replacements and revoking the original would \
                leave them working.
                """,
            subcommands: [Create.self, List.self, Revoke.self]
        )

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Mint a token.",
                discussion: """
                    The token is shown once and cannot be recovered afterwards — only \
                    a hash is stored. With --quiet it is the only thing printed, so it \
                    can be captured straight into a variable.
                    """)

            @Option(
                help: "Kind: \(TokenKind.known.map(\.wireValue).joined(separator: ", ")).",
                completion: .list(TokenKind.known.map(\.wireValue)))
            var kind: String = "human"

            @Option(name: [.short, .long], help: "What this token is for, shown in listings.")
            var label: String?

            @OptionGroup var output: OutputOptions

            func run() async throws {
                let context = Runtime.require()
                let parsed = TokenKind(wireValue: kind)
                guard parsed.isHuman != nil else {
                    throw ValidationError(
                        "Unknown kind '\(kind)'. Known kinds: "
                            + TokenKind.known.map(\.wireValue).joined(separator: ", ") + ".")
                }
                // A label is what makes a revocation list mean anything, so its
                // absence is worth a nudge rather than silence.
                if label == nil, output.format == .table {
                    context.terminal.printError(
                        "Note: no --label, so this token will be hard to identify later.")
                }

                let password = try UserCommand.readSecret(context, prompt: "Password: ")
                let issued = try await context.client().send(
                    try AuthEndpoints.createToken(
                        TokenRequest(password: password, kind: parsed, label: label)),
                    expecting: TokenIssued.self)

                switch output.format {
                case .json, .keys:
                    // Just the token, so `TOKEN=$(issues auth token create -q)` works.
                    context.terminal.print(
                        output.format == .keys
                            ? issued.token
                            : try JSONOutput.render(JSONCoders.encoder.encode(issued)))
                case .table:
                    context.terminal.print("Minted a \(parsed.wireValue) token.")
                    context.terminal.print("")
                    context.terminal.print(issued.token)
                    context.terminal.print("")
                    context.terminal.print(
                        "This is the only time it will be shown; only a hash is stored.")
                    context.terminal.print(
                        "Revoke it with: issues auth token revoke \(issued.session.id.rawValue.uuidString)")
                }
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List tokens.",
                discussion: """
                    Revoked tokens are listed too, with the fact recorded: a listing is \
                    what you read to work out what happened, and hiding them would hide \
                    the evidence.
                    """)

            @Option(
                help: "Whose tokens. An email address, a display name, or a user id. Admin only for others.")
            var user: String?

            @OptionGroup var output: OutputOptions

            func run() async throws {
                let context = Runtime.require()
                let client = try context.client()

                let request: HTTPRequest
                if let user {
                    let id = try await UserLookup.resolve(user, client: client)
                    request = HTTPRequest(
                        method: "GET", path: "/api/v1/users/\(id.rawValue.uuidString)/tokens")
                } else {
                    request = AuthEndpoints.listTokens()
                }

                let data = try await client.data(for: request)
                let items = try JSONOutput.items(in: data)
                let summaries = try JSONCoders.decoder.decode(
                    [SessionSummary].self, from: try JSONSerialization.data(withJSONObject: items))

                switch output.format {
                case .json:
                    context.terminal.print(try JSONOutput.render(items))
                case .keys:
                    for summary in summaries {
                        context.terminal.print(summary.id.rawValue.uuidString)
                    }
                case .table:
                    guard !summaries.isEmpty else {
                        context.terminal.print("No tokens.")
                        return
                    }
                    var table = Table(headers: ["ID", "KIND", "LABEL", "LAST USED", "STATE"])
                    for summary in summaries {
                        table.append([
                            summary.id.rawValue.uuidString,
                            summary.kind.wireValue,
                            summary.label ?? "—",
                            summary.lastUsedAt.map(TokenCommandFormat.day) ?? "never",
                            summary.isRevoked ? "revoked" : "active",
                        ])
                    }
                    context.terminal.print(table.rendered())
                }
            }
        }

        struct Revoke: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Revoke a token.",
                discussion: """
                    Takes a token id, or a label if it matches exactly one of yours. \
                    Revocation is immediate. To end every session at once — after a \
                    laptop is lost, say — change your password instead, which revokes \
                    all of them.
                    """)

            @Argument(help: "A token id, or a label that matches exactly one token.")
            var token: String

            @Flag(name: [.customLong("yes"), .customShort("y")], help: "Skip the confirmation.")
            var assumeYes = false

            func run() async throws {
                let context = Runtime.require()
                let client = try context.client()

                let summaries = try await client.send(
                    AuthEndpoints.listTokens(), expecting: Paginated<SessionSummary>.self
                ).items
                let target = try Self.match(token, in: summaries)

                try context.confirm(
                    "Revoke the \(target.kind.wireValue) token "
                        + "'\(target.label ?? target.id.rawValue.uuidString)'? "
                        + "Anything using it will stop working immediately.",
                    assumeYes: assumeYes)

                try await client.send(AuthEndpoints.revokeToken(id: target.id))
                context.terminal.print("Revoked.")
            }

            /// Accepts an id, or a label when it is unambiguous.
            ///
            /// Typing a UUID to revoke something is miserable, but a label that
            /// matches two tokens must never pick one for you.
            static func match(_ input: String, in summaries: [SessionSummary]) throws
                -> SessionSummary
            {
                if let uuid = UUID(uuidString: input) {
                    guard let match = summaries.first(where: { $0.id == ID(uuid) }) else {
                        throw APIError.notFound(nil)
                    }
                    return match
                }

                let matches = summaries.filter { $0.label?.lowercased() == input.lowercased() }
                if matches.count == 1, let only = matches.first { return only }
                if matches.count > 1 {
                    throw CLIError.malformedConfiguration(
                        "'\(input)' matches \(matches.count) tokens. Use the token id from "
                            + "`issues auth token list`.")
                }
                throw CLIError.malformedConfiguration(
                    "No token with id or label '\(input)'. See `issues auth token list`.")
            }
        }
    }
}

/// Date formatting for the token table.
enum TokenCommandFormat {
    /// Just the day. A token's last-used time is recorded only to the hour, so a
    /// minute-precise timestamp would imply accuracy that is not there.
    static func day(_ date: Date) -> String {
        String(JSONCoders.instantString(date).prefix(10))
    }
}
