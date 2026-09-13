import ClientStore
import Core
import Foundation
import TestSupport
import Testing

@testable import AppCore

/// The atoms are views, which are ungated by ticket 13 — but the decisions inside
/// them are not. Everything with a right answer is a function, and these are those.
@Suite("Atoms")
struct AtomTests {

    // MARK: Label colour

    @Test(
        "a valid colour parses",
        arguments: [
            ("#FFFFFF", 1.0), ("#000000", 0.0),
        ])
    func validColourParses(hex: String, expected: Double) {
        let parts = LabelColor.components(from: hex)
        #expect(parts.red == expected)
        #expect(parts.green == expected)
        #expect(parts.blue == expected)
    }

    @Test("channels are not transposed")
    func channelsAreNotTransposed() {
        let parts = LabelColor.components(from: "#FF8000")
        #expect(parts.red == 1.0)
        #expect(abs(parts.green - 128.0 / 255) < 0.001)
        #expect(parts.blue == 0.0)
    }

    @Test("lower case parses the same as upper case")
    func lowerCaseParsesTheSame() {
        #expect(LabelColor.components(from: "#2d6cdf") == LabelColor.components(from: "#2D6CDF"))
    }

    /// The server validates the format, but an older record or a newer server could
    /// still carry something unexpected — and a list must not crash over a swatch.
    @Test(
        "an unparseable colour falls back rather than crashing",
        arguments: [
            "", "banana", "2D6CDF", "#2D6CD", "#GGGGGG", "#2D6CDFF",
        ])
    func unparseableColourFallsBack(_ hex: String) {
        let parts = LabelColor.components(from: hex)
        #expect(parts == LabelColor.fallback)
    }

    // MARK: Issue key

    /// An issue created offline has no key until first sync, and showing nothing
    /// would read as a rendering fault rather than a pending state.
    @Test("an unassigned key shows a placeholder, not a blank")
    func unassignedKeyShowsAPlaceholder() {
        let text = IssueKeyPresentation.text(key: nil, projectKey: ProjectKey("PROJ"))
        #expect(text == "PROJ-•")
        #expect(!text.isEmpty)
    }

    @Test("an assigned key shows itself")
    func assignedKeyShowsItself() {
        #expect(
            IssueKeyPresentation.text(key: IssueKey("PROJ-142"), projectKey: ProjectKey("PROJ"))
                == "PROJ-142")
    }

    /// Pull order is change order, so an issue can arrive before its project. The
    /// row still has to render something.
    @Test("an unknown project still renders a placeholder")
    func unknownProjectStillRendersAPlaceholder() {
        #expect(!IssueKeyPresentation.text(key: nil, projectKey: nil).isEmpty)
    }

    // MARK: Status and priority

    @Test("known statuses read as words, not wire values")
    func knownStatusesReadAsWords() {
        #expect(StatusPresentation.text(.inProgress) == "In progress")
        #expect(StatusPresentation.text(.todo) == "To do")
    }

    /// An unrecognised value came from the server and the user may well know what
    /// it means, so it is shown verbatim rather than relabelled or hidden.
    @Test("an unknown status is shown verbatim")
    func unknownStatusIsShownVerbatim() {
        #expect(StatusPresentation.text(.unknown("triaged")) == "triaged")
    }

    @Test("an unknown status gets no colour implying a category")
    func unknownStatusGetsNoCategoryColour() {
        #expect(StatusPresentation.emphasis(.unknown("triaged")) != StatusPresentation.emphasis(.todo))
        #expect(StatusPresentation.emphasis(.unknown("triaged")) != StatusPresentation.emphasis(.done))
    }

    @Test("open and closed statuses are told apart")
    func openAndClosedAreToldApart() {
        #expect(StatusPresentation.emphasis(.todo) == StatusPresentation.emphasis(.inProgress))
        #expect(StatusPresentation.emphasis(.done) == StatusPresentation.emphasis(.cancelled))
        #expect(StatusPresentation.emphasis(.todo) != StatusPresentation.emphasis(.done))
    }

    /// A tracker where everything arrives with a badge teaches people that priority
    /// is noise, so only the two that mean something are prominent.
    @Test("only high and urgent are prominent")
    func onlyHighAndUrgentAreProminent() {
        #expect(PriorityPresentation.isProminent(.urgent))
        #expect(PriorityPresentation.isProminent(.high))
        #expect(!PriorityPresentation.isProminent(.none))
        #expect(!PriorityPresentation.isProminent(.medium))
        #expect(!PriorityPresentation.isProminent(.low))
    }

    @Test("an unknown priority is shown verbatim and not made prominent")
    func unknownPriorityIsShownVerbatim() {
        #expect(PriorityPresentation.text(.unknown("blocker")) == "blocker")
        #expect(!PriorityPresentation.isProminent(.unknown("blocker")))
    }

    // MARK: Attribution

    /// The whole point of `via` is answering "which of these did the bot file?" at a
    /// glance (ticket 12), so marking the common case would bury the uncommon one.
    @Test("a human record carries no badge")
    func humanRecordCarriesNoBadge() {
        #expect(!ViaPresentation.shouldShow(.human))
    }

    @Test("an agent record is badged")
    func agentRecordIsBadged() {
        #expect(ViaPresentation.shouldShow(.agent))
        #expect(ViaPresentation.text(.agent) == "Agent")
    }

    /// An unrecognised `via` is badged too: it is certainly not a person, and
    /// failing to mark it would be the one direction that misleads.
    @Test("an unknown via is badged rather than assumed human")
    func unknownViaIsBadged() {
        #expect(ViaPresentation.shouldShow(.unknown("workflow")))
        #expect(ViaPresentation.text(.unknown("workflow")) == "workflow")
    }

}

/// The symbols and action words on each surface.
@Suite("Sync surface presentation")
struct SyncSurfacePresentationTests {

    /// A rebuild is the system recovering, so it must not borrow a warning symbol.
    @Test("rebuilding does not use a warning symbol")
    func rebuildingDoesNotUseAWarningSymbol() {
        let symbol = SyncSurface.rebuilding.symbol
        #expect(!symbol.contains("exclamationmark"))
        #expect(SyncSurface.rebuilding.severity != SyncSurface.needsAttention(count: 1).severity)
    }

    /// Buttons are named for what they do, so the user knows before pressing.
    @Test("every surface offers a named action, not 'View'")
    func everySurfaceOffersANamedAction() {
        let surfaces: [SyncSurface] = [
            .needsAttention(count: 1), .lostToDeletion(count: 1), .needsReauthentication,
            .rebuilding, .willOverwrite(count: 1), .failed("x"),
        ]

        for surface in surfaces {
            let title = surface.actionTitle
            #expect(!title.isEmpty)
            #expect(title != "View")
        }
    }

    @Test("each severity gets its own tint")
    func eachSeverityGetsItsOwnTint() {
        #expect(
            SyncSurface.needsReauthentication.severity != SyncSurface.willOverwrite(count: 1).severity)
        #expect(SyncSurface.willOverwrite(count: 1).severity != SyncSurface.rebuilding.severity)
    }

    @Test("every surface has a distinct symbol")
    func everySurfaceHasADistinctSymbol() {
        let symbols = [
            SyncSurface.needsAttention(count: 1).symbol,
            SyncSurface.lostToDeletion(count: 1).symbol,
            SyncSurface.needsReauthentication.symbol,
            SyncSurface.rebuilding.symbol,
            SyncSurface.willOverwrite(count: 1).symbol,
            SyncSurface.failed("x").symbol,
        ]
        #expect(Set(symbols).count == symbols.count)
    }
}

@Suite("Comment presentation")
struct CommentPresentationTests {

    /// A removed comment keeps its place in the thread. A conversation that closes
    /// its gaps reads as if the exchange never happened, and the reply below it
    /// stops making sense.
    @Test("a deleted comment shows a placeholder rather than nothing")
    func deletedCommentShowsAPlaceholder() {
        let deleted = Comment.fixture(body: nil)

        #expect(CommentPresentation.isPlaceholder(deleted))
        #expect(!CommentPresentation.body(deleted).isEmpty)
        #expect(CommentPresentation.body(deleted).lowercased().contains("deleted"))
    }

    @Test("an ordinary comment shows its own text")
    func ordinaryCommentShowsItsOwnText() {
        let comment = Comment.fixture(body: "Looks right to me.")

        #expect(!CommentPresentation.isPlaceholder(comment))
        #expect(CommentPresentation.body(comment) == "Looks right to me.")
    }

    /// An empty string is something somebody wrote; nil is a deletion. Collapsing
    /// them would put the deletion notice under a comment nobody deleted.
    @Test("an empty body is not a deletion")
    func emptyBodyIsNotADeletion() {
        #expect(!CommentPresentation.isPlaceholder(Comment.fixture(body: "")))
    }
}
