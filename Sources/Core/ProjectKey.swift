/// The short uppercase identifier for a Project, e.g. `PROJ`.
///
/// Immutable after creation and unique per Instance, because it is baked into
/// every Issue Key. See CONTEXT.md and ticket 01.
public struct ProjectKey: Hashable, Sendable {
    public let wireValue: String

    /// `nil` unless the value is 2–10 characters of `[A-Z0-9]`.
    ///
    /// ASCII specifically: Swift's `isUppercase` and `isNumber` are Unicode-wide
    /// and would admit accented letters and non-Latin digits, which would then
    /// appear inside every Issue Key for the Project.
    public init?(_ wireValue: String) {
        guard (2...10).contains(wireValue.count),
            wireValue.utf8.allSatisfy({
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
            })
        else { return nil }
        self.wireValue = wireValue
    }
}
