import Core
import Hummingbird

/// Hummingbird's `ResponseEncodable` conformances for the domain types.
///
/// Declared here rather than in Core so the shared package stays free of any web
/// framework — the CLI, the MCP executable and the apps all depend on Core and
/// none of them should pull in Hummingbird.
extension Project: ResponseEncodable {}
extension Issue: ResponseEncodable {}
extension Comment: ResponseEncodable {}
extension Label: ResponseEncodable {}
extension IssueLabel: ResponseEncodable {}
extension User: ResponseEncodable {}
extension ServerMeta: ResponseEncodable {}
extension Paginated: ResponseEncodable where Item: Codable & Sendable {}

extension ExpandedIssue: ResponseEncodable {}
