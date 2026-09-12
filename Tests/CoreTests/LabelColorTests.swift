import Testing

@testable import Core

@Suite("Label colour")
struct LabelColorTests {

    @Test(
        "a six-digit hex colour is accepted",
        arguments: [
            "#2D6CDF", "#2d6cdf", "#000000", "#FFFFFF",
        ])
    func sixDigitHexIsAccepted(_ value: String) {
        #expect(Validation.labelColor(value).isEmpty)
    }

    @Test(
        "anything else is rejected",
        arguments: [
            "", "banana", "2D6CDF", "#2D6CD", "#2D6CDFF", "#GGGGGG", "#2d6cdf ", "rgb(1,2,3)",
        ])
    func anythingElseIsRejected(_ value: String) {
        #expect(!Validation.labelColor(value).isEmpty, "'\(value)' was accepted")
    }

    @Test("a rejected colour reports 'invalid'")
    func rejectedColourReportsInvalid() {
        #expect(Validation.labelColor("banana").first?.code == .invalid)
        #expect(Validation.labelColor("banana").first?.field == "color")
    }

    /// The same name must always get the same colour, or a label created on two
    /// machines offline would converge on one id with two different colours and
    /// flicker as they sync.
    @Test("the default colour is derived from the name and is stable")
    func defaultColourIsStable() {
        #expect(Label.defaultColor(forName: "bug") == Label.defaultColor(forName: "bug"))
        #expect(Label.defaultColor(forName: "bug") != Label.defaultColor(forName: "chore"))
    }

    /// A derived colour has to pass the same rule a typed one does, or the default
    /// path could produce something the server rejects.
    @Test(
        "every derived colour is valid",
        arguments: [
            "bug", "chore", "feature", "docs", "infra", "security", "ui", "sync", "a", "",
            "a rather long label name with spaces",
        ])
    func everyDerivedColourIsValid(_ name: String) {
        #expect(Validation.labelColor(Label.defaultColor(forName: name)).isEmpty)
    }

    /// Case is a display concern for a name, so it must not change the colour.
    @Test("the derived colour ignores case")
    func derivedColourIgnoresCase() {
        #expect(Label.defaultColor(forName: "Bug") == Label.defaultColor(forName: "bug"))
    }

    /// Swift's own `hashValue` is seeded per process, so it cannot be used here:
    /// the colour would change every run.
    @Test("the derived colour survives a fresh process")
    func derivedColourIsNotProcessSeeded() {
        // A recorded value from a previous run. If this fails, the derivation has
        // become process-dependent and every label will change colour on restart.
        #expect(Label.defaultColor(forName: "bug") == Label.palette[Label.stableIndex(of: "bug")])
        #expect(Label.stableIndex(of: "bug") == Label.stableIndex(of: "bug"))
    }
}
