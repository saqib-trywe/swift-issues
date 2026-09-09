import Core
import Testing

@Suite("ProjectKey")
struct ProjectKeyTests {

    @Test("accepts 2 to 10 uppercase alphanumerics", arguments: ["PR", "PROJ", "A1", "PLATFORM26", "X9Y8Z7"])
    func acceptsValidKeys(raw: String) throws {
        let key = try #require(ProjectKey(raw))

        #expect(key.wireValue == raw)
    }

    /// The key is baked into every Issue Key and is immutable after creation, so
    /// the shape has to be enforced at the boundary rather than assumed.
    @Test(
        "rejects anything outside that shape",
        arguments: [
            "P",  // too short
            "PLATFORM123",  // 11 characters
            "proj",  // lowercase
            "PR-OJ",  // punctuation
            "PR OJ",  // whitespace
            "",
        ]
    )
    func rejectsInvalidKeys(raw: String) {
        #expect(ProjectKey(raw) == nil)
    }

    /// `[A-Z0-9]` means ASCII. Swift's `isUppercase`/`isNumber` are Unicode-wide,
    /// so a naive predicate accepts accented letters and non-Latin digits, which
    /// would then appear inside every Issue Key for that Project.
    @Test(
        "rejects non-ASCII letters and digits",
        arguments: ["\u{00C4}\u{00D6}", "PR\u{00C9}", "\u{0663}\u{0664}", "PROJ\u{0663}"]
    )
    func rejectsNonASCII(raw: String) {
        #expect(ProjectKey(raw) == nil)
    }
}
